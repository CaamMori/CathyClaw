import json, os, subprocess, sys, tempfile, time, unittest
from pathlib import Path
CLI = Path(__file__).parents[1] / "taskctl.py"
# 子进程超时可调：CI/负载高的机器上默认 15s，避免与并发的 te-daemon
# reconcile 争抢资源时偶发 TimeoutExpired（那是环境抖动，不是功能缺陷）。
TIMEOUT = float(os.environ.get("TE_TEST_TIMEOUT", "15"))

class EngineTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        # TASK_ENGINE_HOME 把全部状态指向独立临时根，与生产目录完全隔离，
        # 因此测试之间互不影响、也不触碰真实任务库。
        # 注：常驻 te-daemon 读的是它自己的 TE_DIR（默认生产路径），
        # 与这里无关；且 daemon 只观察/告警、从不写任务状态，
        # 故不会污染测试数据。若机器负载高到子进程启动变慢，
        # 用 TE_TEST_TIMEOUT 放宽超时即可（见上方常量）。
        self.env = {**os.environ, "TASK_ENGINE_HOME": self.tmp.name}
        self.n = 0
    def cli(self, *args):
        return subprocess.run([sys.executable, str(CLI), *args], env=self.env,
                              text=True, capture_output=True, timeout=TIMEOUT)
    def create(self):
        self.n += 1; tid = "task_" + str(self.n)
        r = self.cli("create", "安全目标", "验收应返回零", "--id", tid)
        self.assertEqual(r.returncode, 0, r.stderr); return tid
    def state(self, tid):
        r=self.cli("status",tid); self.assertEqual(r.returncode,0,r.stderr); return json.loads(r.stdout)
    def wait(self, tid, seconds=4):
        end=time.time()+seconds
        while time.time()<end:
            data=self.state(tid)
            if data["status"] != "running": return data
            time.sleep(.04)
        self.fail("worker did not reach terminal/intermediate state")
    def test_success_awaits_verification_then_completes(self):
        tid=self.create(); r=self.cli("run",tid,"--timeout","2","--",sys.executable,"-c","print('ok')")
        self.assertEqual(r.returncode,0,r.stderr); self.assertEqual(self.wait(tid)["status"],"awaiting_verification")
        r=self.cli("verify",tid,"--",sys.executable,"-c","raise SystemExit(0)")
        self.assertEqual(r.stdout.strip(),"completed"); self.assertTrue(self.state(tid)["verified"])
    def test_failure(self):
        tid=self.create(); self.cli("run",tid,"--",sys.executable,"-c","raise SystemExit(3)")
        data=self.wait(tid); self.assertEqual(data["status"],"failed"); self.assertEqual(data["exit_code"],3)
    def test_timeout(self):
        tid=self.create(); self.cli("run",tid,"--timeout","0.1","--",sys.executable,"-c","import time; time.sleep(2)")
        data=self.wait(tid); self.assertEqual(data["status"],"timeout"); self.assertEqual(data["exit_code"],124)
    def test_verification_failure(self):
        tid=self.create(); self.cli("run",tid,"--",sys.executable,"-c","pass"); self.wait(tid)
        r=self.cli("verify",tid,"--",sys.executable,"-c","raise SystemExit(2)")
        self.assertEqual(r.stdout.strip(),"verification_failed"); self.assertFalse(self.state(tid)["verified"])
    def test_concurrent_same_task_rejected(self):
        tid=self.create(); self.assertEqual(self.cli("run",tid,"--",sys.executable,"-c","import time; time.sleep(1)").returncode,0)
        second=self.cli("run",tid,"--",sys.executable,"-c","pass")
        self.assertNotEqual(second.returncode,0); self.assertIn("already running",second.stderr); self.wait(tid)
    def test_fresh_process_status(self):
        tid=self.create(); first=self.state(tid); second=self.state(tid)
        self.assertEqual(first["id"],second["id"]); self.assertEqual(second["status"],"created")
        mode=(Path(self.tmp.name)/"tasks"/tid/"task.json").stat().st_mode & 0o777
        self.assertEqual(mode,0o600)
    def test_traversal_rejected(self):
        for bad in ("../x","a/b","..","a\\b"):
            self.assertNotEqual(self.cli("status",bad).returncode,0)


    def test_private_directory_and_log_permissions(self):
        tid=self.create(); taskdir=Path(self.tmp.name)/"tasks"/tid
        self.assertEqual(taskdir.stat().st_mode & 0o777, 0o700)
        self.assertEqual((taskdir/"task.json").stat().st_mode & 0o777, 0o600)
        self.assertEqual(self.cli("run",tid,"--",sys.executable,"-c","print('run')").returncode,0)
        self.assertEqual(self.wait(tid)["status"],"awaiting_verification")
        self.assertEqual((taskdir/"run.log").stat().st_mode & 0o777, 0o600)
        self.assertEqual(self.cli("verify",tid,"--",sys.executable,"-c","print('verify')").returncode,0)
        self.assertEqual((taskdir/"verify.log").stat().st_mode & 0o777, 0o600)
        self.assertEqual((taskdir/"run.lock").stat().st_mode & 0o777, 0o600)

    def test_duplicate_and_concurrent_create_never_overwrite(self):
        tid="same_id"; argv=[sys.executable,str(CLI),"create"]
        a=subprocess.Popen(argv+["goal_a","accept_a","--id",tid],env=self.env,text=True,stdout=subprocess.PIPE,stderr=subprocess.PIPE)
        b=subprocess.Popen(argv+["goal_b","accept_b","--id",tid],env=self.env,text=True,stdout=subprocess.PIPE,stderr=subprocess.PIPE)
        ra=a.communicate(timeout=TIMEOUT); rb=b.communicate(timeout=TIMEOUT)
        self.assertEqual(sorted((a.returncode,b.returncode)),[0,1],(ra,rb))
        data=json.loads((Path(self.tmp.name)/"tasks"/tid/"task.json").read_text())
        self.assertIn((data["goal"],data["acceptance"]),(("goal_a","accept_a"),("goal_b","accept_b")))
        before=(Path(self.tmp.name)/"tasks"/tid/"task.json").read_bytes()
        self.assertNotEqual(self.cli("create","new","new","--id",tid).returncode,0)
        self.assertEqual((Path(self.tmp.name)/"tasks"/tid/"task.json").read_bytes(),before)

    def test_symlink_task_directory_rejected(self):
        base=Path(self.tmp.name)/"tasks"; base.mkdir()
        outside=Path(self.tmp.name)/"outside"; outside.mkdir()
        (outside/"task.json").write_text(json.dumps({"id":"linked","status":"created"}))
        (base/"linked").symlink_to(outside,target_is_directory=True)
        self.assertNotEqual(self.cli("status","linked").returncode,0)
        self.assertNotEqual(self.cli("create","g","a","--id","linked").returncode,0)
        self.assertNotIn("linked",self.cli("list").stdout)

    def test_nonfinite_timeouts_rejected(self):
        for value in ("nan","inf","-inf","0","-1"):
            tid=self.create()
            r=self.cli("run",tid,"--timeout",value,"--",sys.executable,"-c","pass")
            self.assertNotEqual(r.returncode,0,value)
            self.assertEqual(self.state(tid)["status"],"created")
        tid=self.create(); self.cli("run",tid,"--",sys.executable,"-c","pass"); self.wait(tid)
        r=self.cli("verify",tid,"--timeout","nan","--",sys.executable,"-c","pass")
        self.assertNotEqual(r.returncode,0)
        self.assertEqual(self.state(tid)["status"],"awaiting_verification")

    def test_concurrent_verify_is_blocked_by_same_lock(self):
        tid=self.create(); self.cli("run",tid,"--",sys.executable,"-c","pass"); self.wait(tid)
        first=subprocess.Popen([sys.executable,str(CLI),"verify",tid,"--",sys.executable,"-c","import time; time.sleep(.5)"],env=self.env,text=True,stdout=subprocess.PIPE,stderr=subprocess.PIPE)
        log=Path(self.tmp.name)/"tasks"/tid/"verify.log"
        end=time.time()+2
        while time.time()<end and not log.exists(): time.sleep(.01)
        self.assertTrue(log.exists(),"first verification did not acquire lock")
        second=self.cli("verify",tid,"--",sys.executable,"-c","pass")
        self.assertNotEqual(second.returncode,0); self.assertIn("busy",second.stderr)
        out,err=first.communicate(timeout=TIMEOUT)
        self.assertEqual(first.returncode,0,err); self.assertEqual(out.strip(),"completed")

    def test_status_does_not_orphan_worker_during_launch(self):
        tid=self.create(); self.assertEqual(self.cli("run",tid,"--",sys.executable,"-c","import time; time.sleep(.3)").returncode,0)
        self.assertIn(self.state(tid)["status"],("running","awaiting_verification"))
        self.assertEqual(self.wait(tid)["status"],"awaiting_verification")

    def test_timeout_kills_ignoring_descendant_after_leader_exits(self):
        tid=self.create(); pidfile=Path(self.tmp.name)/"descendant.pid"
        descendant="import os,signal,time; signal.signal(signal.SIGTERM,signal.SIG_IGN); open(%r,'w').write(str(os.getpid())); time.sleep(30)" % str(pidfile)
        leader="import subprocess,sys; subprocess.Popen([sys.executable,'-c',%r])" % descendant
        r=self.cli("run",tid,"--timeout","0.2","--",sys.executable,"-c",leader)
        self.assertEqual(r.returncode,0,r.stderr)
        data=self.wait(tid); self.assertEqual(data["status"],"timeout")
        end=time.time()+2
        while time.time()<end and not pidfile.exists(): time.sleep(.01)
        self.assertTrue(pidfile.exists(),"descendant did not start")
        pid=int(pidfile.read_text()); proc=Path("/proc")/str(pid)/"stat"
        end=time.time()+2
        while time.time()<end and proc.exists():
            try:
                if proc.read_text().split(") ",1)[1].startswith("Z "): break
            except FileNotFoundError: break
            time.sleep(.02)
        if proc.exists(): self.assertTrue(proc.read_text().split(") ",1)[1].startswith("Z "),"descendant still alive")

if __name__ == "__main__": unittest.main()
