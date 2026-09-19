#!/usr/bin/env python3
"""Minimal durable local task engine (Python standard library only)."""
import argparse, fcntl, json, os, shlex, shutil, signal, subprocess, sys, time, uuid, math, threading
from pathlib import Path
ROOT = Path(os.environ.get("TASK_ENGINE_HOME", Path(__file__).resolve().parent))
BASE = ROOT / "tasks"
# 任务脚本持久目录：凡任务用到的运行/验收脚本**必须**落在这里。
# 反例（2026-09-19 事故）：某任务 run_argv 指向 /tmp/n.sh，/tmp 被清理后
# 验收命令永久失效，任务卡在 awaiting_verification 6.18 天。
SCRIPTS = ROOT / "scripts"

# 易失路径前缀：落在这些位置的脚本会在重启/清理后消失
VOLATILE_PREFIXES = ("/tmp/", "/var/tmp/", "/dev/shm/", "/run/")

HEARTBEAT_STALE = float(os.environ.get("TE_HEARTBEAT_STALE", "45"))
def now(): return time.time()
def valid_id(value):
    if not value or not value.isidentifier() or value in (".", "..") or "/" in value or "\\" in value:
        raise ValueError("invalid task id")
    return value

# ── root 运行防护（2026-09-19 事故后加）────────────────────────────────
# 事故：运维侧以 root 直接跑本脚本，atomic_write 建出的 task.json 属主变成
#   root:root 且权限 600 → 容器内的 node(uid 1000) 读不到 →
#   taskboard.py --summary 抛 PermissionError，巡检整体失败。
# 根因同 §B9.10「root 污染」一脉：**宿主 root 身份写的文件，容器内消费方读不到**。
OWNER_UID = 1000

def _check_owner():
    """非 1000 身份运行、且目标目录已属 1000 时拒绝（防属主污染）。"""
    if os.environ.get("TE_ALLOW_ROOT") == "1":
        return
    try:
        st = ROOT.stat()
    except OSError:
        return
    if st.st_uid == OWNER_UID and os.geteuid() != OWNER_UID:
        raise SystemExit(
            "\n[拒绝执行] 目标目录属主是 %d:%d，但当前以 uid=%d 运行。\n"
            "  以 root 运行会把新建的 task.json 写成 root:root(600)，\n"
            "  导致容器内 node 用户无法读取、taskboard 巡检报 PermissionError。\n"
            "  正确用法：docker exec -u node openclaw-gateway python3 "
            "/home/node/.openclaw/workspace/task-engine/taskctl.py ...\n"
            "  或：  sudo -u '#1000' python3 %s ...\n"
            "  （确需放行：TE_ALLOW_ROOT=1）"
            % (OWNER_UID, OWNER_UID, os.geteuid(), __file__))


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

def check_volatile_argv(argv, where):
    """检查 argv 是否引用了易失路径，是则抛出可读错误。

    设计意图：把"脚本放 /tmp"这个错误**挡在创建时**，而不是等到几天后
    验收失败才暴露——那时脚本早没了，且失败态曾不可逆（§B9.15.1）。
    """
    if not argv:
        return
    for tok in argv:
        if not isinstance(tok, str):
            continue
        for pre in VOLATILE_PREFIXES:
            if tok.startswith(pre):
                raise ValueError(
                    f"[{where}] 脚本路径 {tok!r} 落在易失目录 {pre!r}。\n"
                    f"  该目录会在重启/清理后消失，导致任务无法重跑或验收失败。\n"
                    f"  请改用持久目录，例如：{SCRIPTS}/<task-id>-<名称>.sh\n"
                    f"  （可先 mkdir -p {SCRIPTS} 并 chown 1000:1000）"
                )


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
    path = taskdir / "task.json"
    t = now()
    task = {"id":tid,"goal":args.goal,"acceptance":args.acceptance,
        "status":"created","created_at":t,"updated_at":t,"pid":None,
        "run_argv":None,"exit_code":None,"verified":False}
    cmd = getattr(args, "accept_cmd", None)
    if cmd:
        # create 时登记的验收命令：后续 verify 无需再猜"该怎么验收"
        accept_argv = shlex.split(cmd)
        check_volatile_argv(accept_argv, "create --accept-cmd")
        task["acceptance_argv"] = accept_argv
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
            heartbeat(hb_path, "running", {"pgid": pgid_ref[0]})

    pgid_ref = [None]
    with os.fdopen(fd, "ab", buffering=0) as out:
        child = subprocess.Popen(argv, stdout=out, stderr=subprocess.STDOUT, start_new_session=True)
        pgid = child.pid  # start_new_session guarantees a worker-owned session/group.
        pgid_ref[0] = pgid
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
    check_volatile_argv(args.argv, "run")
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
                    reset_from=prev, reset_at=now(),
                    reset_count=int(data.get("reset_count") or 0) + 1)
        if getattr(args, "reason", None): data["reset_reason"] = args.reason
        save(path, data); print(data["status"])
        return 0

def verify(args):
    normalize_timeout_argv(args, accept_flags=("--accept",))
    if args.argv:
        check_volatile_argv(args.argv, "verify")
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

def migrate_volatile(args, tasks=None):
    """把历史任务里指向易失路径的 argv **标记**出来（不改写、不伪造）。

    为什么是"标记"而不是"重写路径"：
      原脚本（如 /tmp/n.sh）已经不存在，任何"改写成一个新路径"都是**伪造**——
      新路径下并没有那个脚本。诚实的做法是：
        · 记录 volatile_paths（原始路径，留痕）
        · 记录 migrated_at / migrate_note
        · 若任务因此**永远无法重跑/重验**，把它标为需要人工决策
      这与本项目"不许编造"的铁律一致（§A5.1 铁律 27）。
    """
    scanned = flagged = 0
    for taskdir in sorted(BASE.iterdir()) if BASE.is_dir() else []:
        if not taskdir.is_dir() or taskdir.is_symlink():
            continue
        tj = taskdir / "task.json"
        if not tj.is_file():
            continue
        if tasks and taskdir.name not in tasks:
            continue
        scanned += 1
        try:
            with tj.open(encoding="utf-8") as f:
                data = json.load(f)
        except Exception:
            continue
        hits = []
        for field in ("run_argv", "verification_argv", "acceptance_argv"):
            argv = data.get(field) or []
            if not isinstance(argv, list):
                continue
            for tok in argv:
                if isinstance(tok, str):
                    for pre in VOLATILE_PREFIXES:
                        if tok.startswith(pre):
                            hits.append({"field": field, "path": tok})
                            break
        if not hits:
            continue
        flagged += 1
        # 已存在且内容相同则不重复写（幂等）
        if data.get("volatile_paths") == hits:
            if not args.quiet:
                print(f"  [=] {taskdir.name}: 已标记（{len(hits)} 处）")
            continue
        data["volatile_paths"] = hits
        data["migrated_at"] = now()
        data["migrate_note"] = (
            "argv 指向易失目录（脚本已不存在）。脚本被清理后本任务无法重跑/重验；"
            "如需重跑，请把脚本放到 scripts/ 下并更新 argv，或直接 delete 本任务（已 completed 可保留留痕）。"
        )
        # 已完成且已验收的任务：只留痕，不改状态（改状态会造成"任务回退"的假象）
        if not args.quiet:
            print(f"  [!] {taskdir.name}: 标记 {len(hits)} 处易失路径 "
                  f"({', '.join(h['path'] for h in hits)})")
        atomic_write(tj, data)

    print(f"\n扫描 {scanned} 个任务，标记 {flagged} 个含易失路径的任务")
    print(f"  易失前缀: {', '.join(VOLATILE_PREFIXES)}")
    print(f"  持久脚本目录: {SCRIPTS}")


def main(argv=None):
    _check_owner()
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
    p=sub.add_parser("migrate-volatile"); p.add_argument("--quiet",action="store_true",help="只报标记数，不逐条打印"); p.set_defaults(func=migrate_volatile)
    p=sub.add_parser("reap"); p.add_argument("id", nargs="?"); p.add_argument("--dry-run",action="store_true"); p.set_defaults(func=reap)
    p=sub.add_parser("run"); p.add_argument("id"); p.add_argument("--timeout",type=float,default=30); p.add_argument("--force",action="store_true"); p.add_argument("argv",nargs=argparse.REMAINDER); p.set_defaults(func=run_task)
    p=sub.add_parser("verify"); p.add_argument("id"); p.add_argument("--timeout",type=float,default=30); p.add_argument("--accept",action="store_true",help="人工裁决直接通过，跳过验收命令执行"); p.add_argument("argv",nargs=argparse.REMAINDER); p.set_defaults(func=verify)
    args=ap.parse_args(argv)
    if hasattr(args,"argv") and args.argv[:1]==["--"]: args.argv=args.argv[1:]
    return args.func(args) or 0
if __name__ == "__main__":
    try: raise SystemExit(main())
    except Exception as e: print("error:", e, file=sys.stderr); raise SystemExit(1)
