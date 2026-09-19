#!/usr/bin/env python3
"""te_daemon.py — 统一任务守护（面向容器内权威引擎 taskctl.py）

职责（每 INTERVAL 秒一轮）：
  1. reconcile：对每个 running 任务调用 `taskctl.py status`，
     触发其内置的孤儿检测（worker 已死 → 标 orphaned）。
  2. 停滞检测：running 任务超过 STALL_SECS 无日志增长 → 经 Telegram 告警"疑似卡住"。
  3. 待验收提醒：进入 awaiting_verification 的任务，首次出现时提醒一次。
  4. 孤儿提醒：orphaned 任务，提醒一次（不自动重跑副作用，交人工/代理决定）。
  5. 完成通知：任务转为 completed 时推送一次（区分"已验收通过"与"仅完成"）。
  6. 失败/超时通知：任务转为 failed/timeout 时推送一次（附 exit code）。

设计原则：只观察与提醒，绝不自动执行有副作用的恢复动作。
"""
import json
import os
import subprocess
import sys
import time
from pathlib import Path

TE_DIR = Path(os.environ.get(
    "TE_DIR",
    "/data/state/workspace/task-engine"))
TASKS = TE_DIR / "tasks"
INTERVAL = float(os.environ.get("TE_INTERVAL", "30"))
STALL_SECS = float(os.environ.get("TE_STALL_SECS", "600"))   # 10 分钟无进展视为停滞
ALERT_TARGET = os.environ.get("TE_ALERT_TARGET", "YOUR_TELEGRAM_USER_ID")
GW = "openclaw-gateway"
STATE_FILE = Path("/var/run/te-daemon.state.json")
TG_LAST = [0.0]  # 上次推送时间戳（去抖用）
PY = sys.executable or "python3"


def log(msg):
    print(f"[te-daemon] {time.strftime('%Y-%m-%d %H:%M:%S')} {msg}", flush=True)


def send_telegram(text):
    """经容器内 gateway 推送；失败仅记日志。"""
    try:
        subprocess.run(
            ["timeout", "25", "docker", "exec", GW, "openclaw", "message", "send",
             "--channel", "telegram", "--target", ALERT_TARGET, "-m", text],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=30)
        return True
    except Exception:
        return False


def task_status(tid):
    """调用 taskctl.py status 提取 JSON（触发其孤儿检测）。"""
    try:
        out = subprocess.check_output(
            [PY, str(TE_DIR / "taskctl.py"), "status", tid],
            stderr=subprocess.DEVNULL, timeout=20).decode()
        # taskctl 输出为 JSON（可能有前置行），取最后一个 { ... }
        i = out.find("{")
        if i < 0:
            return None
        return json.loads(out[i:])
    except Exception:
        return None


def list_ids():
    if not TASKS.is_dir():
        return []
    return [d.name for d in sorted(TASKS.iterdir())
            if d.is_dir() and not d.is_symlink() and (d / "task.json").is_file()]


def log_size(tid):
    p = TASKS / tid / "run.log"
    try:
        return p.stat().st_size
    except FileNotFoundError:
        return 0


HEARTBEAT_STALE = float(os.environ.get("TE_HEARTBEAT_STALE", "45"))


def hb_age(tid):
    """心跳文件距现在的秒数；无则 None。"""
    p = TASKS / tid / "heartbeat.json"
    try:
        return max(0.0, time.time() - float(json.loads(p.read_text()).get("ts", 0)))
    except Exception:
        return None


def tg_quiet(seconds=30):
    """距离上次成功推送是否已超过 seconds（告警去抖）。"""
    try:
        return time.time() - TG_LAST[0] >= seconds
    except Exception:
        return True


def auto_reap(tid):
    """对单个孤儿任务执行收敛（补写终态）。失败静默。"""
    try:
        out = subprocess.check_output(
            [PY, str(TE_DIR / "taskctl.py"), "reap", tid],
            stderr=subprocess.DEVNULL, timeout=20).decode()
        return "reaped" in out
    except Exception:
        return False


def load_state():
    try:
        return json.loads(STATE_FILE.read_text())
    except Exception:
        return {}


def save_state(st):
    try:
        STATE_FILE.write_text(json.dumps(st, ensure_ascii=False))
    except Exception:
        pass


def refresh_board():
    """每轮刷新 HTML 看板（写入 nginx 可读的 web 根目录）。失败静默。"""
    dest = os.environ.get("TE_BOARD_HTML", "/var/www/openclaw-board/index.html")
    try:
        subprocess.run(
            [PY, str(TE_DIR / "taskboard.py"), "--html", dest],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=20)
    except Exception:
        pass


def main():
    log(f"启动 dir={TE_DIR} interval={INTERVAL}s stall={STALL_SECS}s")
    notified_awaiting = set()
    notified_orphan = set()
    notified_done = set()      # completed 已通知
    notified_fail = set()      # failed/timeout 已通知

    while True:
        state = load_state()
        refresh_board()
        for tid in list_ids():
            data = task_status(tid)
            if not data:
                continue
            st = data.get("status")
            goal = (data.get("goal") or "")[:40]

            if st == "running":
                cur = log_size(tid)
                prev = state.get(tid, {}).get("log_size", cur)
                last_change = state.get(tid, {}).get("last_change", time.time())
                if cur != prev:
                    last_change = time.time()
                else:
                    idle = time.time() - last_change
                    if idle >= STALL_SECS and not state.get(tid, {}).get("stalled"):
                        # 心跳感知：日志不动不代表进程死了。
                        # 仅当「心跳也过期」时才升级为卡死告警；否则只是长任务静默。
                        age = hb_age(tid)
                        if age is not None and age <= HEARTBEAT_STALE:
                            log(f"QUIET {tid} idle={int(idle)}s hb_age={age:.0f}s "
                                f"(長任務靜默，進程存活，不告警)")
                        else:
                            send_telegram(
                                f"⚠️ 任務疑似卡住 [{tid}] {goal}\n"
                                f"已 {int(idle // 60)} 分鐘無進展，且心跳停滯\n"
                                f"（可查: taskctl.py status {tid}）")
                            log(f"STALL {tid} idle={int(idle)}s hb_age={age}")
                            state.setdefault(tid, {})["stalled"] = True
                state.setdefault(tid, {}).update(
                    {"log_size": cur, "last_change": last_change})
                if state.get(tid, {}).get("stalled") and cur != prev:
                    state[tid]["stalled"] = False  # 有新进展则复位

            elif st == "awaiting_verification":
                if tid not in notified_awaiting:
                    send_telegram(f"⏳ 任務待驗收 [{tid}] {goal}\n（等待獨立驗收）")
                    notified_awaiting.add(tid)

            elif st == "orphaned":
                # 关键修复：自动把孤儿收敛为真实终态（failed/-9），避免状态悬空。
                # 仅补写终态字段，不重启任务、不删目录 —— 无副作用。
                did = auto_reap(tid)
                if did:
                    log(f"REAP {tid} -> failed(-9) 已自動收斂終態")
                    data = task_status(tid) or data
                    st = data.get("status", "failed")
                if tid not in notified_orphan:
                    send_telegram(
                        f"⚠️ 任務孤兒 [{tid}] {goal}\n"
                        f"worker 已不在（外部終止或崩潰），已自動標記為 failed(-9)，"
                        f"無需人工清理；如需重跑請用 run --force")
                    notified_orphan.add(tid)
                    log(f"ORPHAN {tid}")

            elif st == "completed":
                notified_awaiting.discard(tid)
                notified_orphan.discard(tid)
                state.pop(tid, None)
                if tid not in notified_done:
                    verified = "✅ 已驗收通過" if data.get("verified") else "✅ 已完成"
                    send_telegram(f"{verified} [{tid}] {goal}")
                    notified_done.add(tid)
                    log(f"DONE {tid}")

            elif st in ("failed", "timeout"):
                notified_awaiting.discard(tid)
                notified_orphan.discard(tid)
                state.pop(tid, None)
                if tid not in notified_fail:
                    ec = data.get("exit_code")
                    ec_s = f" exit={ec}" if ec is not None else ""
                    label = "❌ 任務失敗" if st == "failed" else "⌛ 任務超時"
                    send_telegram(
                        f"{label} [{tid}] {goal}{ec_s}\n"
                        f"（詳情: taskctl.py status {tid}，人工決定是否重跑）")
                    notified_fail.add(tid)
                    log(f"FAIL {tid} status={st}")

        save_state(state)
        time.sleep(INTERVAL)


if __name__ == "__main__":
    main()
