#!/usr/bin/env python3
"""Deterministic task-engine monitor: no Agent/model calls.

Reads task JSON directly, asks taskctl to diagnose only live-looking `running`
tasks, and sends Telegram only when actionable states are present. Identical
issue sets are suppressed for 24 hours; a clean queue is silent.
"""
import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import time

DEFAULT_TASKS = Path('/data/state/workspace/task-engine/tasks')
STATE = Path('/data/state/workspace/task-engine/.reconcile_alert_state.json')
LOCK = Path('/run/lock/openclaw-task-reconcile.lock')
GW = 'openclaw-gateway'
TARGET = os.environ.get('TE_ALERT_TARGET', '${TARGET_CHAT_ID:-YOUR_TELEGRAM_CHAT_ID}')
ACTIONABLE = {'orphaned', 'awaiting_verification', 'verification_failed', 'failed', 'timeout'}
ICONS = {
    'orphaned': '⚠️',
    'awaiting_verification': '⏳',
    'verification_failed': '❌',
    'failed': '❌',
    'timeout': '⌛',
}


def load_tasks(base: Path):
    tasks = []
    if not base.is_dir():
        return tasks
    for p in sorted(base.iterdir()):
        f = p / 'task.json'
        if p.is_symlink() or not f.is_file():
            continue
        try:
            obj = json.loads(f.read_text(encoding='utf-8'))
            if isinstance(obj, dict):
                tasks.append(obj)
        except (OSError, json.JSONDecodeError):
            continue
    return tasks


def diagnose_running(tasks, production: bool):
    if not production:
        return
    for task in tasks:
        if task.get('status') != 'running' or not task.get('id'):
            continue
        subprocess.run([
            'docker', 'exec', '-u', 'node', GW, 'python3',
            '/home/node/.openclaw/workspace/task-engine/taskctl.py',
            'status', str(task['id']),
        ], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=30, check=False)


def actionable(tasks):
    return [t for t in tasks if t.get('status') in ACTIONABLE]


def age_text(task):
    ts = task.get('updated_at') or task.get('created_at')
    if not isinstance(ts, (int, float)) or ts <= 0:
        return ''
    hours = max(0, (time.time() - ts) / 3600)
    return f'{hours:.1f}小时' if hours < 48 else f'{hours / 24:.1f}天'


def render(items):
    if not items:
        return ''
    lines = ['⚠️ 任务队列需要处理']
    for task in items[:12]:
        status = str(task.get('status', '?'))
        tid = str(task.get('id', '?'))
        goal = ' '.join(str(task.get('goal') or '').split())[:70]
        age = age_text(task)
        suffix = f',停留 {age}' if age else ''
        lines.append(f"• {ICONS.get(status, '⚠️')} {tid}: {status}{suffix}")
        if goal:
            lines.append(f'  {goal}')
        if status == 'awaiting_verification':
            lines.append(f'  建议:核验后执行 taskctl.py verify {tid}')
        elif status == 'orphaned':
            lines.append(f'  建议:确认后执行 taskctl.py reap {tid}')
        elif status in {'failed', 'timeout', 'verification_failed'}:
            lines.append(f'  建议:检查日志后 reset/retry,或明确关闭任务')
    if len(items) > 12:
        lines.append(f'• 另有 {len(items) - 12} 项,请用 /tasks 查看')
    return '\n'.join(lines)


def issue_signature(items):
    compact = sorted((str(t.get('id')), str(t.get('status')), str(t.get('updated_at'))) for t in items)
    return hashlib.sha256(json.dumps(compact, ensure_ascii=False).encode()).hexdigest()


def should_send(items, state_path: Path, dedupe_hours: float):
    if not items:
        try:
            state_path.write_text('{}\n', encoding='utf-8')
        except OSError:
            pass
        return False
    sig = issue_signature(items)
    try:
        state = json.loads(state_path.read_text(encoding='utf-8'))
    except (OSError, json.JSONDecodeError):
        state = {}
    now = time.time()
    if state.get('signature') == sig and now - float(state.get('sent_at', 0)) < dedupe_hours * 3600:
        return False
    state_path.write_text(json.dumps({'signature': sig, 'sent_at': now}) + '\n', encoding='utf-8')
    return True


def send_telegram(text):
    proc = subprocess.run([
        'docker', 'exec', GW, 'openclaw', 'message', 'send',
        '--channel', 'telegram', '--target', TARGET, '-m', text,
    ], capture_output=True, text=True, timeout=60)
    if proc.returncode != 0:
        err = (proc.stderr or proc.stdout or 'unknown delivery error').strip()[:300]
        raise RuntimeError(err)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--send', action='store_true', help='send actionable result to Telegram')
    ap.add_argument('--print', dest='print_result', action='store_true', help='print result; clean queue prints a short status')
    ap.add_argument('--tasks-dir', type=Path, default=DEFAULT_TASKS, help=argparse.SUPPRESS)
    ap.add_argument('--state-file', type=Path, default=STATE, help=argparse.SUPPRESS)
    ap.add_argument('--dedupe-hours', type=float, default=24.0)
    ap.add_argument('--no-diagnose', action='store_true', help=argparse.SUPPRESS)
    args = ap.parse_args()

    LOCK.parent.mkdir(parents=True, exist_ok=True)
    with LOCK.open('w') as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            return 0
        production = args.tasks_dir.resolve() == DEFAULT_TASKS.resolve()
        tasks = load_tasks(args.tasks_dir)
        if not args.no_diagnose:
            diagnose_running(tasks, production)
            tasks = load_tasks(args.tasks_dir)
        items = actionable(tasks)
        text = render(items)
        if args.print_result:
            print(text or '任务队列正常(确定性巡检,静默)')
        if args.send and text and should_send(items, args.state_file, args.dedupe_hours):
            send_telegram(text)
            print('task-reconcile: alert sent')
        elif args.send and not text:
            should_send([], args.state_file, args.dedupe_hours)
        return 0


if __name__ == '__main__':
    try:
        raise SystemExit(main())
    except Exception as exc:
        print(f'task-reconcile failed: {exc}', file=sys.stderr)
        raise SystemExit(1)
