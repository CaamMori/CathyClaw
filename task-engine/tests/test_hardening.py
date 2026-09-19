import os,sys,subprocess,time,json
from pathlib import Path
from test_engine import EngineTests,CLI

class HardeningTests(EngineTests):
    def test_private_logs(self):
        t=self.create();self.cli('run',t,'--',sys.executable,'-c','print("safe")');self.wait(t)
        self.cli('verify',t,'--',sys.executable,'-c','pass')
        p=Path(self.tmp.name)/'tasks'/t
        for f in ['run.log','verify.log','task.json']:self.assertEqual((p/f).stat().st_mode&0o777,0o600)
        self.assertEqual(p.stat().st_mode&0o777,0o700)
    def test_duplicate_create(self):
        t=self.create();r=self.cli('create','replacement','wrong','--id',t)
        self.assertNotEqual(r.returncode,0);self.assertEqual(self.state(t)['goal'],'安全目标')
    def test_nonfinite(self):
        t=self.create()
        for v in ['nan','inf','-inf','0']:
            self.assertNotEqual(self.cli('run',t,'--timeout',v,'--',sys.executable,'-c','pass').returncode,0)
        self.assertEqual(self.state(t)['status'],'created')
    def test_symlink(self):
        t=self.create();p=Path(self.tmp.name)/'tasks';(p/'alias').symlink_to(p/t,target_is_directory=True)
        self.assertNotEqual(self.cli('status','alias').returncode,0)
    def test_concurrent_verify(self):
        t=self.create();self.cli('run',t,'--',sys.executable,'-c','pass');self.wait(t)
        flag=Path(self.tmp.name)/'verifying'
        code=f'import pathlib,time;pathlib.Path({str(flag)!r}).touch();time.sleep(0.7)'
        p=subprocess.Popen([sys.executable,str(CLI),'verify',t,'--',sys.executable,'-c',code],env=self.env,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
        try:
            end=time.monotonic()+3
            while not flag.exists() and time.monotonic()<end:time.sleep(.02)
            self.assertTrue(flag.exists());self.assertNotEqual(self.cli('verify',t,'--',sys.executable,'-c','pass').returncode,0)
        finally:p.communicate(timeout=4)
        self.assertEqual(self.state(t)['status'],'completed')
    def test_timeout_descendant(self):
        t=self.create();flag=Path(self.tmp.name)/'childpid'
        child=f'import signal,time,os,pathlib;signal.signal(signal.SIGTERM,signal.SIG_IGN);pathlib.Path({str(flag)!r}).write_text(str(os.getpid()));time.sleep(8)'
        parent=f'import subprocess,sys,time;subprocess.Popen([sys.executable,"-c",{child!r}]);time.sleep(8)'
        self.cli('run',t,'--timeout','0.5','--',sys.executable,'-c',parent)
        self.assertEqual(self.wait(t)['status'],'timeout');self.assertTrue(flag.exists())
        pid=int(flag.read_text());end=time.monotonic()+2
        while time.monotonic()<end:
            try:state=Path(f'/proc/{pid}/stat').read_text().split(') ',1)[1].split()[0]
            except FileNotFoundError:return
            if state=='Z':return
            time.sleep(.02)
        self.fail('descendant still executing')

    def test_final_state_is_published_outside_the_lock(self):
        """结构性不变量：worker 必须在释放 run.lock 之后才公布终态。

        缺陷背景：worker 原本在持有 run.lock 时写 awaiting_verification，
        于是存在一个窗口——状态已对外可见，锁却还没释放。
        此时立刻 verify（正常操作）会因 flock(LOCK_EX|LOCK_NB) 失败而返回 1，
        报 "error: task busy"。高负载机器上才偶发，CI 上复现过一次。

        为什么断言结构而不是行为：本机负载撑不开那个窗口，
        "跑一遍看是否 busy" 在修复前后都会通过（实测 30/30 与 5/5），
        是个没有辨别力的假防线。实测有效的复现方式是给旧代码在
        "写终态→释放锁" 之间插 0.5s 延迟，此时旧版 5/5 报 task busy、
        新版 5/5 通过——所以真正的判据是"终态写入发生在 with 之外"。

        这里直接检查源码：抓取 worker 函数体，要求
        awaiting_verification 的写入位置在 open_lock 的 with 块结束后。
        """
        import re, inspect, sys as _sys
        _sys.path.insert(0, str(Path(__file__).parents[1]))
        import taskctl
        src = inspect.getsource(taskctl.worker)
        m = re.search(r'^(\s*)with open_lock\(lock_path\)', src, re.M)
        self.assertIsNotNone(m, "worker 里找不到 open_lock 的 with 块")
        with_indent = len(m.group(1))
        lines = src.split("\n")
        start = next(i for i, l in enumerate(lines) if "with open_lock(lock_path)" in l)
        # with 块的结束：之后第一条缩进 <= with_indent 且非空的语句。
        # 若 with 一直延伸到函数末尾（旧版即如此），则 end 落在末尾——
        # 这本身就是"终态在锁内写入"的形态，由下方断言给出可读的诊断。
        end = len(lines)
        for i in range(start + 1, len(lines)):
            l = lines[i]
            if not l.strip():
                continue
            if len(l) - len(l.lstrip()) <= with_indent:
                end = i
                break
        body = "\n".join(lines[start:end])
        tail = "\n".join(lines[end:])
        self.assertNotIn("awaiting_verification", body,
                         "awaiting_verification 在 with 块内写入——锁未释放时状态就已可见，"
                         "verify 会偶发 'task busy'（CI 上复现过）。"
                         "请把终态写入移到 with 之外。")
        self.assertIn("awaiting_verification", tail,
                      "awaiting_verification 应在 with 块结束后写入")

def load_tests(loader, tests, pattern):
    import unittest
    return unittest.TestSuite(HardeningTests(n) for n in HardeningTests.__dict__ if n.startswith('test_'))
