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

def load_tests(loader, tests, pattern):
    import unittest
    return unittest.TestSuite(HardeningTests(n) for n in HardeningTests.__dict__ if n.startswith('test_'))
