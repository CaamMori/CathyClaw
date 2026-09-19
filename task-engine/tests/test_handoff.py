import hashlib,json,sys,time,unittest
from pathlib import Path
import test_engine

class HandoffTests(test_engine.EngineTests):
    def artifact_task(self):
        tid=self.create(); p=Path(self.tmp.name)/'report.json'
        payload={'task':tid,'total':sum([12,18,30]),'rows':3}
        body=json.dumps(payload,sort_keys=True)
        writer=f'import time,pathlib;time.sleep(.15);pathlib.Path({str(p)!r}).write_text({body!r})'
        expected=hashlib.sha256(body.encode()).hexdigest()
        verifier=f'import pathlib,hashlib,json;p=pathlib.Path({str(p)!r});b=p.read_bytes();assert hashlib.sha256(b).hexdigest()=={expected!r};d=json.loads(b);assert d["total"]==60 and d["rows"]==3'
        self.assertEqual(self.cli('run',tid,'--',sys.executable,'-c',writer).returncode,0)
        self.assertEqual(self.wait(tid)['status'],'awaiting_verification')
        return tid,p,writer,verifier
    def test_fresh_process_verifies_real_artifact_without_rerun(self):
        tid,p,writer,verifier=self.artifact_task(); before=p.stat().st_mtime_ns
        self.assertNotEqual(self.cli('run',tid,'--',sys.executable,'-c',writer).returncode,0)
        self.assertEqual(self.cli('verify',tid,'--',sys.executable,'-c',verifier).returncode,0)
        self.assertEqual(self.state(tid)['status'],'completed');self.assertEqual(p.stat().st_mtime_ns,before)
    def test_corrupted_artifact_rejected_then_explicit_repair(self):
        tid,p,writer,verifier=self.artifact_task();p.write_text('{"total":999}')
        self.assertNotEqual(self.cli('verify',tid,'--',sys.executable,'-c',verifier).returncode,0)
        self.assertEqual(self.state(tid)['status'],'verification_failed')
        self.assertEqual(self.cli('run',tid,'--',sys.executable,'-c',writer).returncode,0)
        self.assertEqual(self.wait(tid)['status'],'awaiting_verification')
        self.assertEqual(self.cli('verify',tid,'--',sys.executable,'-c',verifier).returncode,0)
        self.assertTrue(self.state(tid)['verified'])
    def test_missing_artifact_rejected(self):
        tid,p,writer,verifier=self.artifact_task();p.unlink()
        self.assertNotEqual(self.cli('verify',tid,'--',sys.executable,'-c',verifier).returncode,0)
        self.assertEqual(self.state(tid)['status'],'verification_failed')

def load_tests(loader,tests,pattern):
    return unittest.TestSuite(HandoffTests(n) for n in HandoffTests.__dict__ if n.startswith('test_'))
