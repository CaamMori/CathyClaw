#!/usr/bin/env python3
"""taskboard.py — 任务看板与简洁汇报（配合 taskctl.py 使用）

用法：
  taskboard.py                    # 人类可读总览
  taskboard.py --json             # 机器可读（供程序消费）
  taskboard.py --telegram <id>    # 生成单任务的简洁汇报文本
  taskboard.py --summary          # 生成整体进度摘要（供 Telegram 推送）

数据源：<TASK_ENGINE_HOME>/tasks/<id>/task.json
设计与 taskctl.py 同源（纯标准库），不依赖外部包。
"""
import argparse
import json
import os
import sys
import time
from pathlib import Path

ROOT = Path(os.environ.get("TASK_ENGINE_HOME", Path(__file__).resolve().parent))
BASE = ROOT / "tasks"

ICON = {
    "created": "○ 待执行",
    "running": "▶ 运行中",
    "awaiting_verification": "⏳ 待验收",
    "completed": "✅ 已完成",
    "failed": "❌ 失败",
    "timeout": "⌛ 超时",
    "orphaned": "⚠ 孤儿",
}
ORDER = {"running": 0, "orphaned": 1, "awaiting_verification": 2, "created": 3,
         "failed": 4, "timeout": 5, "completed": 6}


def load_all():
    tasks = []
    if not BASE.is_dir():
        return tasks
    for d in sorted(BASE.iterdir()):
        if not d.is_dir() or d.is_symlink():
            continue
        f = d / "task.json"
        if f.is_file():
            try:
                tasks.append(json.loads(f.read_text(encoding="utf-8")))
            except Exception:
                continue
    return tasks


def fmt_dur(t):
    if not t:
        return ""
    secs = int(time.time() - float(t))
    if secs < 0:
        return ""
    if secs < 60:
        return f"{secs}s"
    if secs < 3600:
        return f"{secs // 60}m{secs % 60}s"
    return f"{secs // 3600}h{(secs % 3600) // 60}m"


def board_text(tasks):
    if not tasks:
        return "📋 目前沒有任務"
    lines = [f"📋 任務看板（共 {len(tasks)}）"]
    done = sum(1 for t in tasks if t.get("status") == "completed")
    fail = sum(1 for t in tasks if t.get("status") in ("failed", "timeout"))
    for t in sorted(tasks, key=lambda x: ORDER.get(x.get("status"), 9)):
        st = t.get("status", "?")
        label = ICON.get(st, st)
        goal = (t.get("goal") or "")[:30]
        dur = fmt_dur(t.get("updated_at"))
        extra = ""
        if st == "awaiting_verification":
            extra = "待獨立驗收"
        elif st == "running" and t.get("pid"):
            extra = f"pid={t['pid']}"
        elif st in ("failed", "timeout") and t.get("exit_code") is not None:
            extra = f"exit={t['exit_code']}"
        lines.append(f"  {label:12s} {t.get('id',''):14s} {goal:32s} {dur:8s} {extra}")
    lines.append(f"\n  完成 {done} / 失敗 {fail} / 共 {len(tasks)}")
    return "\n".join(lines)


def one_summary(t):
    st = t.get("status", "?")
    label = ICON.get(st, st)
    dur = fmt_dur(t.get("updated_at"))
    parts = [f"{label} [{t.get('id')}] {t.get('goal','')}"]
    if dur:
        parts.append(f"用時 {dur}")
    if st == "awaiting_verification":
        parts.append("等待獨立驗收")
    if st in ("failed", "timeout") and t.get("exit_code") is not None:
        parts.append(f"exit={t['exit_code']}")
    return " | ".join(parts)


def board_html(tasks):
    """生成自包含 HTML 看板（可写入文件经 nginx 提供）。"""
    done = sum(1 for t in tasks if t.get("status") == "completed")
    fail = sum(1 for t in tasks if t.get("status") in ("failed", "timeout"))
    active = sum(1 for t in tasks if t.get("status") in
                 ("running", "awaiting_verification", "orphaned"))
    color = {
        "created": "#888", "running": "#1a73e8", "awaiting_verification": "#f9a825",
        "completed": "#188038", "failed": "#d93025", "timeout": "#d93025",
        "orphaned": "#e8710a",
    }
    rows = []
    for t in sorted(tasks, key=lambda x: ORDER.get(x.get("status"), 9)):
        st = t.get("status", "?")
        c = color.get(st, "#666")
        dur = fmt_dur(t.get("updated_at"))
        rows.append(
            f"<tr><td><span class='badge' style='background:{c}'>{st}</span></td>"
            f"<td><code>{t.get('id','')}</code></td>"
            f"<td>{t.get('goal','')}</td>"
            f"<td>{t.get('acceptance','')}</td>"
            f"<td>{dur}</td>"
            f"<td>{t.get('exit_code') if t.get('exit_code') is not None else '-'}</td></tr>")
    html = f"""<!doctype html><html lang="zh"><head><meta charset="utf-8">
<meta http-equiv="refresh" content="30">
<title>OpenClaw 任務看板</title>
<style>
 body{{font-family:-apple-system,Segoe UI,Roboto,Helvetica,Arial,sans-serif;margin:24px;background:#fafafa;color:#222}}
 h1{{font-size:20px}} .sum{{margin:12px 0;font-size:14px;color:#444}}
 .sum b{{font-size:18px}}
 table{{border-collapse:collapse;width:100%;background:#fff;box-shadow:0 1px 3px rgba(0,0,0,.1)}}
 th,td{{padding:10px 12px;text-align:left;border-bottom:1px solid #eee;font-size:14px}}
 th{{background:#f5f5f5;font-weight:600}} .badge{{color:#fff;padding:2px 8px;border-radius:10px;font-size:12px}}
 code{{background:#f2f2f2;padding:2px 5px;border-radius:4px}}
 .foot{{margin-top:12px;color:#888;font-size:12px}}
</style></head><body>
<h1>🦞 OpenClaw 任務看板</h1>
<div class="sum">共 <b>{len(tasks)}</b> ｜ 進行中 <b>{active}</b> ｜ 完成 <b>{done}</b> ｜ 失敗 <b>{fail}</b>
 　<span style="color:#999">（每 30 秒自動刷新）</span></div>
<table><thead><tr><th>狀態</th><th>ID</th><th>目標</th><th>驗收條件</th><th>耗時</th><th>exit</th></tr></thead>
<tbody>{''.join(rows) or '<tr><td colspan=6 style="color:#999">目前沒有任務</td></tr>'}</tbody></table>
<div class="foot">生成時間 {time.strftime('%Y-%m-%d %H:%M:%S')} ｜ 由 taskboard.py 產生</div>
</body></html>"""
    return html


def all_summary(tasks):
    """整体进度摘要，供 Telegram 推送。包含刚完成的、待验收的、异常的。"""
    groups = [
        ("▶ 進行中", ("running",)),
        ("⚠ 需處理", ("orphaned", "failed", "timeout")),
        ("⏳ 待驗收", ("awaiting_verification",)),
    ]
    lines = []
    for title, sts in groups:
        hit = [t for t in tasks if t.get("status") in sts]
        if hit:
            lines.append(f"{title}（{len(hit)}）")
            for t in hit[:8]:
                lines.append("  " + one_summary(t))
    if not lines:
        done = sum(1 for t in tasks if t.get("status") == "completed")
        if done:
            return f"📋 任務隊列正常｜累計完成 {done} 項，無進行中／待驗收／異常任務"
        return "📋 任務隊列為空"
    return "📋 任務日報\n" + "\n".join(lines)


def push_telegram(text, target=None):
    """经 gateway CLI 把文本真正推送到 Telegram。"""
    import shutil
    import subprocess
    target = target or os.environ.get("TE_ALERT_TARGET") or ""
    if not target:
        print("⚠ TE_ALERT_TARGET not set, skip telegram push", file=sys.stderr)
        return 1
    exe = shutil.which("openclaw")
    cmd = None
    if exe:
        cmd = [exe, "message", "send", "--channel", "telegram",
               "--target", target, "-m", text]
    elif shutil.which("docker"):
        cmd = ["docker", "exec", "openclaw-gateway", "openclaw", "message", "send",
               "--channel", "telegram", "--target", target, "-m", text]
    if cmd is None:
        print("⚠ 找不到 openclaw/docker，无法推送", file=sys.stderr)
        return 1
    # Telegram 偶发 409 冲突，短重试
    for attempt in range(1, 4):
        try:
            r = subprocess.run(cmd, capture_output=True, text=True, timeout=60)
        except subprocess.TimeoutExpired:
            print(f"⚠ 推送超时（第{attempt}次）", file=sys.stderr)
            continue
        if r.returncode == 0:
            print("✅ 已推送 Telegram")
            return 0
        err = (r.stderr or r.stdout or "").strip()[:200]
        print(f"⚠ 推送失败（第{attempt}次）: {err}", file=sys.stderr)
        time.sleep(2 * attempt)
    return 1


def main(argv=None):
    p = argparse.ArgumentParser(
        description="OpenClaw 任务看板与汇报（数据源：taskctl.py 的 tasks/ 目录）")
    p.add_argument("--json", action="store_true", help="以 JSON 输出全部任务")
    p.add_argument("--html", metavar="PATH", help="输出 HTML 看板到文件")
    p.add_argument("--telegram", metavar="TARGET", nargs="?", const="",
                   help="生成摘要并推送到 Telegram（可指定 target；缺省从 TE_ALERT_TARGET 读取）")
    p.add_argument("--summary", action="store_true", help="打印总体进度摘要（不推送）")
    p.add_argument("--one", metavar="ID", help="打印单个任务的简洁汇报")
    args = p.parse_args(argv)

    tasks = load_all()

    if args.json:
        print(json.dumps(tasks, ensure_ascii=False, indent=2))
    elif args.html:
        Path(args.html).write_text(board_html(tasks), encoding="utf-8")
        print(f"HTML 看板已写入 {args.html}")
    elif args.one:
        for t in tasks:
            if t.get("id") == args.one:
                print(one_summary(t))
                return 0
        print(f"⚠ 找不到任務 {args.one}")
        return 1
    elif args.telegram:
        text = all_summary(tasks)
        print(text)
        return push_telegram(text, args.telegram)
    elif args.summary:
        print(all_summary(tasks))
    else:
        print(board_text(tasks))
    return 0


if __name__ == "__main__":
    sys.exit(main())
