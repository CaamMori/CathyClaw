#!/usr/bin/env python3
"""Minimal durable local task engine (Python standard library only)."""
import argparse, fcntl, json, os, shlex, shutil, signal, subprocess, sys, time, uuid, math, threading
from pathlib import Path
ROOT = Path(os.environ.get("TASK_ENGINE_HOME", Path(__file__).resolve().parent))
BASE = ROOT / "tasks"

HEARTBEAT_STALE = float(os.environ.get("TE_HEARTBEAT_STALE", "45"))
def now(): return time.time()
def valid_id(value):
    if not value or not value.isidentifier() or value in (".", "..") or "/" in value or "\\" in value:
        raise ValueError("invalid task id")
    return value

def atomic_write(path, data):
    path.parent.mkdir(parents=True, exist_ok=True)
    os.chmod(path.parent, 0o700)
    tmp = path.parent / ("." + path.name + "." + uuid.uuid4().hex)
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            json.dump(data, f, ensure_ascii=False, indent=2)
            f.write("\n"); f.flush(); os.fsync(f.fileno())
        os.replace(tmp, path)
        os.chmod(path, 0o600)
        dfd = os.open(path.parent, os.O_RDONLY)
        try: os.fsync(dfd)
        finally: os.close(dfd)
    finally:
        try: tmp.unlink()
        except FileNotFoundError: pass

def load(tid):
    valid_id(tid); path = BASE / tid / "task.json"
    if path.parent.is_symlink() or not path.is_file(): raise ValueError("task not found")
    with path.open(encoding="utf-8") as f: return path, json.load(f)
def save(path, data): data["updated_at"] = now(); atomic_write(path, data)

def open_lock(path):
    fd = os.open(path, os.O_RDWR | os.O_CREAT, 0o600)
    os.chmod(path, 0o600)
    return os.fdopen(fd, "a+")

def create(args):
    tid = valid_id(args.id or ("t_" + uuid.uuid4().hex[:12]))
    BASE.mkdir(parents=True, exist_ok=True); os.chmod(BASE, 0o700)
    taskdir = BASE / tid
    try:
        taskdir.mkdir(mode=0o700)
    except FileExistsError:
        raise ValueError("task already exists")
    os.chmod(taskdir, 0o700)  # 显式设置，避免 umask 削成 755
    path = taskdir / "task.json"
    t = now()
    task = {"id":tid,"goal":args.goal,"acceptance":args.acceptance,
        "status":"created","created_at":t,"updated_at":t,"pid":None,
        "run_argv":None,"exit_code":None,"verified":False}
    cmd = getattr(args, "accept_cmd", None)
    if cmd:
        # create 时登记的验收命令：后续 verify 无需再猜"该怎么验收"
        task["acceptance_argv"] = shlex.split(cmd)
    atomic_write(path, task)
    print(tid)
    if not cmd:
        print(f"warning: acceptance is prose (no --accept-cmd); `verify {tid}` will require "
              f"an explicit command. Prefer: --accept-cmd 'test -s <artifact>'", file=sys.stderr)

def owned_group_alive(pgid):
    """Confirm a live member remains in the session/group created by our child."""
    try:
        entries = os.scandir("/proc")
    except OSError:
        return False
    with entries:
        for entry in entries:
            if not entry.name.isdigit(): continue
            try:
                raw = (Path(entry.path) / "stat").read_text()
                fields = raw[raw.rfind(")") + 2:].split()
                state, pgrp, session = fields[0], int(fields[2]), int(fields[3])
                if state != "Z" and pgrp == pgid and session == pgid:
                    return True
            except (OSError, ValueError, IndexError):
                continue
    return False

def signal_owned_group(pgid, sig):
    # Never signal based only on a stale numeric PID/group identifier.
    if owned_group_alive(pgid):
        try: os.killpg(pgid, sig)
        except ProcessLookupError: pass

def heartbeat(path, status="running", extra=None):
    """写心跳 beacon。独立于 run.log 增长，便于外部判定 worker 是否还活着。"""
    try:
        payload = {"ts": now(), "pid": os.getpid(), "status": status}
        if extra: payload.update(extra)
        atomic_write(path, payload)
    except Exception:
        pass

def execute(argv, timeout, log_path, hb_path=None):
    if not argv: raise ValueError("explicit argv required")
    fd = os.open(log_path, os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600)
    os.chmod(log_path, 0o600)
    stop_hb = threading.Event()

    def _hb_loop():
        # 每 10s 刷新心跳；worker 被 SIGKILL 后心跳自然停止 -> 外部可判定死亡
        while not stop_hb.wait(10):
            heartbeat(hb_path, "running", {"pgid": pgid})

    # 实际命令与 worker wrapper 保持在同一个 process group/session。
    # worker wrapper 由 run_task() 以 start_new_session=True 启动，已是 group/session leader。
    # 这里不创建新 session，子进程自动继承 worker wrapper 的 pgid，
    # 这样外部 signal_owned_group(data["pid"]) 才能同时终止 wrapper 和真正任务进程。
    pgid = os.getpgid(0)
    with os.fdopen(fd, "ab", buffering=0) as out:
        child = subprocess.Popen(argv, stdout=out, stderr=subprocess.STDOUT)
        if hb_path is not None:
            heartbeat(hb_path, "running", {"pgid": pgid})
            threading.Thread(target=_hb_loop, daemon=True).start()
        deadline = time.monotonic() + timeout
        try:
            while child.poll() is None or owned_group_alive(pgid):
                if time.monotonic() >= deadline:
                    signal_owned_group(pgid, signal.SIGTERM)
                    grace = time.monotonic() + 1
                    while (child.poll() is None or owned_group_alive(pgid)) and time.monotonic() < grace:
                        time.sleep(.02)
                    signal_owned_group(pgid, signal.SIGKILL)
                    child.wait()
                    return 124, True
                time.sleep(.02)
            return child.returncode, False
        finally:
            stop_hb.set()

def worker(tid, timeout, argv):
    path, _ = load(tid); lock_path = path.parent / "run.lock"
    with open_lock(lock_path) as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        path, data = load(tid)
        # Parent has already recorded running state. Worker now owns the durable lease.
        hb_path = path.parent / "heartbeat.json"
        data.update(status="running", pid=os.getpid(), worker_started_at=now())
        save(path, data)
        try:
            code, timed_out = execute(argv, timeout, path.parent / "run.log", hb_path)
            path, data = load(tid)
            data.update(status=("timeout" if timed_out else ("awaiting_verification" if code == 0 else "failed")),
                        exit_code=code, pid=None, finished_at=now())
            save(path, data)
            heartbeat(hb_path, data["status"])
        except BaseException as e:
            path, data = load(tid); data.update(status="failed", pid=None,
                worker_error=type(e).__name__, finished_at=now()); save(path, data)
            raise

def normalize_timeout_argv(args, accept_flags=()):
    # argparse REMAINDER preserves command flags; accept documented timeout/--force after ID.
    if not hasattr(args, "force"):
        args.force = False
    for flag in accept_flags:
        attr = flag.lstrip("-").replace("-", "_")
        if not hasattr(args, attr):
            setattr(args, attr, False)
    # Extract a leading --force flag (only before the command separator "--").
    argv = args.argv
    if "--" in argv:
        sep = argv.index("--"); head, tail = argv[:sep], argv[sep:]
    else:
        head, tail = argv, []
    if "--force" in head:
        head = [x for x in head if x != "--force"]; args.force = True
    for flag in accept_flags:
        if flag in head:
            head = [x for x in head if x != flag]
            setattr(args, flag.lstrip("-").replace("-", "_"), True)
    argv = head + tail
    if len(argv) >= 2 and argv[0] == "--timeout":
        args.timeout = float(argv[1]); argv = argv[2:]
    if argv[:1] == ["--"]: argv = argv[1:]
    if not math.isfinite(args.timeout) or args.timeout <= 0: raise ValueError("timeout must be finite and positive")
    args.argv = argv

def run_task(args):
    normalize_timeout_argv(args)
    if not args.argv: raise ValueError("explicit argv required")
    path, _ = load(args.id); lock_path = path.parent / "run.lock"
    with open_lock(lock_path) as lock:
        try: fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError: raise RuntimeError("task already running")
        path, data = load(args.id)  # reload only after lock acquisition
        if data["status"] == "running": raise RuntimeError("task already running")
        if not args.force and data["status"] not in ("created", "failed", "timeout", "verification_failed"):
            raise RuntimeError("task state cannot be run (use --force to override)")
        # On --force, reap any leftover worker process group; safe no-op if already dead.
        if args.force and isinstance(data.get("pid"), int) and data["pid"] > 1:
            signal_owned_group(data["pid"], signal.SIGTERM)
            deadline = time.monotonic() + 2
            while owned_group_alive(data["pid"]) and time.monotonic() < deadline:
                time.sleep(.05)
            signal_owned_group(data["pid"], signal.SIGKILL)
        cmd = [sys.executable, str(Path(__file__).resolve()), "__worker", args.id,
               str(args.timeout), "--", *args.argv]
        proc = subprocess.Popen(cmd, start_new_session=True, stdout=subprocess.DEVNULL,
                                stderr=subprocess.DEVNULL, close_fds=True)
        data.update(status="running", pid=proc.pid, run_argv=args.argv,
                    run_timeout=args.timeout, started_at=now(), verified=False,
                    exit_code=None, finished_at=None)
        save(path, data)
        print(proc.pid)

def pid_matches(data):
    pid = data.get("pid")
    if not isinstance(pid, int) or pid <= 1: return False
    try:
        raw = (Path("/proc") / str(pid) / "cmdline").read_bytes().split(b"\0")
    except (FileNotFoundError, PermissionError, ProcessLookupError): return False
    values = [x.decode(errors="replace") for x in raw]
    return "__worker" in values and data.get("id") in values

def hb_age(taskdir):
    """心跳文件距现在的秒数；无心跳文件返回 None。"""
    p = taskdir / "heartbeat.json"
    try:
        return max(0.0, now() - float(json.loads(p.read_text()).get("ts", 0)))
    except Exception:
        return None

def diagnose(path, data):
    """判定 running 任务是否已失去 worker（无需持有 run.lock）。

    返回 None（仍健康）或 (new_status, reason)。判据（任一成立即视为孤儿）：
      a) pid 记录的 worker 进程已不存在（cmdline 不匹配）
      b) 心跳文件存在但已过期(> HEARTBEAT_STALE)
      c) 完全没有 worker_started_at 且已超过 2s（启动失败）
    """
    if data.get("status") != "running":
        return None
    taskdir = path.parent
    if not data.get("worker_started_at") and now() - data.get("started_at", 0) < 2:
        return None  # 刚启动，仍视为 launching
    if pid_matches(data):
        return None  # worker 进程确认存活
    age = hb_age(taskdir)
    if age is not None and age <= HEARTBEAT_STALE:
        return None  # worker 进程已不在但心跳仍新鲜 -> 可能正在交接
    reason = "worker_vanished" if age is None or age > HEARTBEAT_STALE else "worker_vanished"
    return ("orphaned", reason)

def status(args):
    path, data = load(args.id)
    with open_lock(path.parent / "run.lock") as lock:
        try: fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            # lock 被占用：可能 worker 正在跑，也可能 worker 已被强杀而 flock 随进程释放前的窗口。
            # 关键修复：拿不到锁也执行独立诊断，避免"卡住"永远检测不出来。
            _, data = load(args.id)
            diag = diagnose(path, data)
            if diag:
                data.update(status=diag[0], pid=None, orphan_detected_at=now(),
                            orphan_reason=diag[1], hb_age=None if hb_age(path.parent) is None else round(hb_age(path.parent),1))
                save(path, data)
        else:
            path, data = load(args.id)
            diag = diagnose(path, data)
            if diag:
                data.update(status=diag[0], pid=None, orphan_detected_at=now(),
                            orphan_reason=diag[1], hb_age=None if hb_age(path.parent) is None else round(hb_age(path.parent),1))
                save(path, data)
    print(json.dumps(data, ensure_ascii=False, indent=2))
def list_tasks(_):
    BASE.mkdir(parents=True, exist_ok=True)
    for p in sorted(BASE.iterdir()):
        if p.is_symlink(): continue
        try:
            with (p/"task.json").open(encoding="utf-8") as f: d=json.load(f)
            print(d["id"], d["status"])
        except (OSError, KeyError, json.JSONDecodeError): continue

def reap(args):
    """把孤儿/无终态任务收敛为真实终态（failed, exit_code=-9）。

    默认处理全部 orphaned 任务；--id 指定单个。
    --dry-run 只列出不写。这是"消除悬空状态"的安全操作：
    不重启任务、不删目录，只补写终态字段。
    """
    targets = []
    if getattr(args, "id", None):
        path, data = load(args.id)
        targets.append((path, data))
    else:
        BASE.mkdir(parents=True, exist_ok=True)
        for p in sorted(BASE.iterdir()):
            if p.is_symlink() or not (p / "task.json").is_file():
                continue
            try:
                path, data = load(p.name)
            except Exception:
                continue
            targets.append((path, data))

    reaped = []
    for path, data in targets:
        if data.get("status") not in ("orphaned",):
            continue
        lock_path = path.parent / "run.lock"
        with open_lock(lock_path) as lock:
            try:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                continue  # 任务正在操作，跳过，避免与 running worker 竞态
            # 加锁后重新加载，防止状态已被其他进程更新
            try:
                path, data = load(path.parent.name)
            except Exception:
                continue
            if data.get("status") not in ("orphaned",):
                continue
            # 再确认一次确实没人活着，避免误杀健康的 running->_orphan 竞态
            if pid_matches(data):
                continue
            hb = hb_age(path.parent)
            if hb is not None and hb <= HEARTBEAT_STALE:
                continue  # 心跳仍新鲜，可能在交接中，放过
            if args.dry_run:
                reaped.append((data.get("id"), "DRY-RUN"))
                continue
            data.update(
                status="failed",
                exit_code=-9,
                pid=None,
                finished_at=data.get("orphan_detected_at") or now(),
                failure_reason="orphaned_worker_reaped",
                killed_by="external_signal (worker was terminated, no exit code recorded)",
                hb_age=None if hb is None else round(hb, 1),
            )
            save(path, data)
            # 心跳文件标记为终态，防止后续误判
            try:
                heartbeat(path.parent / "heartbeat.json", "failed_reaped")
            except Exception:
                pass
            reaped.append((data.get("id"), "REAPED"))
            print(f"reaped {data.get('id')} -> failed(-9) reason=orphaned_worker_reaped")

    if not reaped:
        print("nothing to reap")
    return 0

def delete_task(args):
    """Delete a task directory entirely. Stops any live worker first (safe: only
    this task's process group), then removes tasks/<id> including task.json/run.log/run.lock."""
    path, data = load(args.id)  # raises ValueError if missing (no-op, other tasks untouched)
    taskdir = path.parent
    pid = data.get("pid")
    if isinstance(pid, int) and pid > 1:
        signal_owned_group(pid, signal.SIGTERM)
        deadline = time.monotonic() + 2
        while owned_group_alive(pid) and time.monotonic() < deadline:
            time.sleep(.05)
        signal_owned_group(pid, signal.SIGKILL)
    shutil.rmtree(taskdir, ignore_errors=True)
    print("deleted", args.id)

RESETTABLE = ("verification_failed", "failed", "timeout", "orphaned")

def reset(args):
    """把终态任务退回 awaiting_verification，使其可被重新验收。

    存在意义：verify 失败会把任务打成 verification_failed，而该状态原本不可逆，
    导致 agent 因惧怕"一次验收失败即永久报废"而不敢发起验收，只能无限推理。
    """
    path, _ = load(args.id)
    with open_lock(path.parent / "run.lock") as lock:
        try: fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError: raise RuntimeError("task busy")
        path, data = load(args.id)
        prev = data.get("status")
        if prev == "running": raise RuntimeError("task already running")
        if prev not in RESETTABLE and not args.force:
            raise RuntimeError(f"task state cannot be reset: {prev} (use --force to override)")
        data.update(status="awaiting_verification", verified=False,
                    verification_exit_code=None, verified_at=None,
                    verification_mode=None, verification_argv=None,
                    accept_reason=None,
                    # 清理上一次运行/失败/孤儿遗留的终态字段，避免误导
                    exit_code=None, finished_at=None, worker_error=None,
                    failure_reason=None, killed_by=None,
                    orphan_detected_at=None, orphan_reason=None, hb_age=None,
                    reset_from=prev, reset_at=now(),
                    reset_count=int(data.get("reset_count") or 0) + 1)
        if getattr(args, "reason", None): data["reset_reason"] = args.reason
        save(path, data); print(data["status"])
        return 0

def verify(args):
    normalize_timeout_argv(args, accept_flags=("--accept",))
    path, _ = load(args.id)
    with open_lock(path.parent / "run.lock") as lock:
        try: fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError: raise RuntimeError("task busy")
        path, data = load(args.id)
        if data["status"] != "awaiting_verification": raise RuntimeError("task is not awaiting verification")
        # 人工裁决入口：验收人已确认通过时，无需再跑验收命令即可关闭任务。
        # 缺少这个逃生舱时，"验收命令已失效 + 失败不可逆"会让 agent 陷入不敢行动的死锁。
        if getattr(args, "accept", False):
            data.update(verification_argv=["<manual-accept>"], verification_exit_code=0,
                        verified=True, status="completed", verified_at=now(),
                        verification_mode="manual_accept",
                        accept_reason=getattr(args, "reason", None) or "operator confirmed")
            save(path, data); print(data["status"])
            return 0
        argv = args.argv
        # 未给出命令时，回退到 create 时登记的验收命令，避免 agent 因不知验什么而卡住
        if not argv and isinstance(data.get("acceptance_argv"), list) and data["acceptance_argv"]:
            argv = list(data["acceptance_argv"])
        if not argv:
            raise ValueError("explicit acceptance argv required; "
                             "or pass --accept to mark completed without running a command")
        code, timed_out = execute(argv, args.timeout, path.parent / "verify.log")
        ok = code == 0 and not timed_out
        data.update(verification_argv=argv, verification_exit_code=code,
                    verified=ok, status="completed" if ok else "verification_failed",
                    verified_at=now(), verification_mode="command")
        save(path, data); print(data["status"])
        if not ok:
            print(f"hint: recover with `reset {args.id}` then verify again, "
                  f"or `--accept` if a human already approved", file=sys.stderr)
        return 0 if ok else 1

def main(argv=None):
    argv = sys.argv[1:] if argv is None else argv
    if argv and argv[0] == "__worker":
        if len(argv) < 5 or argv[3] != "--": raise ValueError("bad worker invocation")
        return worker(argv[1], float(argv[2]), argv[4:]) or 0
    ap=argparse.ArgumentParser(); sub=ap.add_subparsers(dest="command", required=True)
    p=sub.add_parser("create"); p.add_argument("goal"); p.add_argument("acceptance"); p.add_argument("--id"); p.add_argument("--accept-cmd",default=None,help="可执行验收命令(字符串)，登记后 verify 可直接使用"); p.set_defaults(func=create)
    p=sub.add_parser("list"); p.set_defaults(func=list_tasks)
    p=sub.add_parser("status"); p.add_argument("id"); p.set_defaults(func=status)
    p=sub.add_parser("delete"); p.add_argument("id"); p.set_defaults(func=delete_task)
    p=sub.add_parser("reset"); p.add_argument("id"); p.add_argument("--force",action="store_true"); p.add_argument("--reason"); p.set_defaults(func=reset)
    p=sub.add_parser("reap"); p.add_argument("id", nargs="?"); p.add_argument("--dry-run",action="store_true"); p.set_defaults(func=reap)
    p=sub.add_parser("run"); p.add_argument("id"); p.add_argument("--timeout",type=float,default=30); p.add_argument("--force",action="store_true"); p.add_argument("argv",nargs=argparse.REMAINDER); p.set_defaults(func=run_task)
    p=sub.add_parser("verify"); p.add_argument("id"); p.add_argument("--timeout",type=float,default=30); p.add_argument("--accept",action="store_true",help="人工裁决直接通过，跳过验收命令执行"); p.add_argument("argv",nargs=argparse.REMAINDER); p.set_defaults(func=verify)
    args=ap.parse_args(argv)
    if hasattr(args,"argv") and args.argv[:1]==["--"]: args.argv=args.argv[1:]
    return args.func(args) or 0
if __name__ == "__main__":
    try: raise SystemExit(main())
    except Exception as e: print("error:", e, file=sys.stderr); raise SystemExit(1)
