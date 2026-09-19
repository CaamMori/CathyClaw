import json, os, shutil, subprocess, sys, tempfile, unittest
from pathlib import Path
CLI = Path(__file__).parents[1] / "taskctl.py"
# 子进程超时可调：CI/负载高的机器上默认 15s，避免与并发的 te-daemon
# reconcile 争抢资源时偶发 TimeoutExpired（那是环境抖动，不是功能缺陷）。
TIMEOUT = float(os.environ.get("TE_TEST_TIMEOUT", "15"))


class VolatileGuardTests(unittest.TestCase):
    """针对 check_volatile_argv 的回归测试（2026-09-19 新增）。"""

    def setUp(self):
        # ⚠️ 不能直接用 tempfile 默认目录：它在 /tmp 下，会被易失路径校验（正确地）拦掉。
        # 这里建一个非易失的临时根，模拟真实部署的持久盘位置。
        base = Path(tempfile.mkdtemp(prefix="te-volatile-", dir=os.getcwd()))
        self.addCleanup(shutil.rmtree, base, True)
        self.tmp = base
        (base / "scripts").mkdir()
        self.env = {**os.environ, "TASK_ENGINE_HOME": str(base)}

    def cli(self, *args):
        return subprocess.run([sys.executable, str(CLI), *args], env=self.env,
                              text=True, capture_output=True, timeout=TIMEOUT)

    # ---- create --accept-cmd ----
    def test_accept_cmd_tmp_rejected(self):
        r = self.cli("create", "g", "a", "--id", "t1", "--accept-cmd", "test -s /tmp/x.log")
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("易失目录", r.stderr)
        self.assertIn("/tmp/", r.stderr)

    def test_accept_cmd_persistent_ok(self):
        # 注意：不能拿 tempfile 目录做举例——它默认在 /tmp 下，会被校验（正确地）拦掉。
        # 这里用 TASK_ENGINE_HOME 下的 scripts/ 作为持久路径。
        target = str(Path(str(self.tmp)) / "scripts" / "x.log")
        self.assertFalse(target.startswith("/tmp/"))   # 前置断言：确认它真不是易失路径
        r = self.cli("create", "g", "a", "--id", "t2", "--accept-cmd", "test -s %s" % target)
        self.assertEqual(r.returncode, 0, r.stderr)
        d = json.loads(self.cli("status", "t2").stdout)
        self.assertEqual(d["acceptance_argv"], ["test", "-s", target])

    # ---- run ----
    def test_run_tmp_rejected(self):
        self.cli("create", "g", "a", "--id", "t3")
        r = self.cli("run", "t3", "--", "bash", "/tmp/y.sh")
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("易失目录", r.stderr)

    def test_run_vartmp_rejected(self):
        self.cli("create", "g", "a", "--id", "t4")
        r = self.cli("run", "t4", "--", "bash", "/var/tmp/y.sh")
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("易失目录", r.stderr)

    def test_run_devshm_rejected(self):
        self.cli("create", "g", "a", "--id", "t5")
        r = self.cli("run", "t5", "--", "bash", "/dev/shm/y.sh")
        self.assertNotEqual(r.returncode, 0)

    def test_run_normal_ok(self):
        self.cli("create", "g", "a", "--id", "t6")
        r = self.cli("run", "t6", "--timeout", "3", "--", sys.executable, "-c", "print('ok')")
        self.assertEqual(r.returncode, 0, r.stderr)

    # ---- verify ----
    def test_verify_tmp_rejected(self):
        self.cli("create", "g", "a", "--id", "t7")
        self.cli("run", "t7", "--timeout", "3", "--", sys.executable, "-c", "pass")
        r = self.cli("verify", "t7", "--", "test", "-s", "/tmp/z.log")
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("易失目录", r.stderr)

    # ---- migrate-volatile ----
    def test_migrate_marks_and_is_idempotent(self):
        # 手工造一个带易失 argv 的任务（绕过 create 校验，模拟历史数据）
        tdir = Path(str(self.tmp)) / "tasks" / "legacy"
        tdir.mkdir(parents=True)
        (tdir / "task.json").write_text(json.dumps({
            "id": "legacy", "goal": "g", "acceptance": "a", "status": "completed",
            "verified": True, "run_argv": ["bash", "/tmp/old.sh"],
        }), encoding="utf-8")
        r = self.cli("migrate-volatile")
        self.assertEqual(r.returncode, 0, r.stderr)
        d = json.loads((tdir / "task.json").read_text(encoding="utf-8"))
        self.assertEqual(d["volatile_paths"], [{"field": "run_argv", "path": "/tmp/old.sh"}])
        self.assertEqual(d["status"], "completed")     # 状态不被改动
        self.assertIn("migrate_note", d)
        # 幂等：再跑不应改变内容
        before = (tdir / "task.json").read_text(encoding="utf-8")
        self.cli("migrate-volatile")
        self.assertEqual(before, (tdir / "task.json").read_text(encoding="utf-8"))

    def test_migrate_clean_task_untouched(self):
        self.cli("create", "g", "a", "--id", "clean1")
        tdir = Path(str(self.tmp)) / "tasks" / "clean1"
        before = (tdir / "task.json").read_text(encoding="utf-8")
        r = self.cli("migrate-volatile")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(before, (tdir / "task.json").read_text(encoding="utf-8"))


if __name__ == "__main__":
    unittest.main()
