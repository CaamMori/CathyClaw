#!/usr/bin/env python3
"""stale_guard.py —— 任务停滞看门狗（只读，绝不修改任何任务状态）

存在的理由：
  2026-09-19 `notify_e2e` 卡在 awaiting_verification 达 6.18 天才被发现。
  原有 reconcile.py 只做"列出"，没有时间维度判断，于是每 2 小时重复推送
  同一条「⏳ 待验收」，推到第七十几次时已经没人看了（告警疲劳）。

本脚本按"停留时长"分级，让长期停滞自动升级为醒目告警：
  - 正常等待期内：静默（避免噪音）
  - 超过提醒阈值：INFO
  - 超过升级阈值：WARN，明确要求人工介入

用法：
  python3 stale_guard.py                # 人类可读输出
  python3 stale_guard.py --json         # 机器可读
  python3 stale_guard.py --hours 6      # 自定义提醒阈值（默认 2h）
  python3 stale_guard.py --critical 24  # 自定义升级阈值（默认 24h）

退出码：
  0 = 无异常（含静默项）   1 = 存在 WARN   2 = 存在 ERROR/严重停滞
便于 cron 根据退出码决定是否推送。
"""
import argparse
import json
import os
import sys
import time
from pathlib import Path

ROOT = Path(os.environ.get("TASK_ENGINE_HOME", Path(__file__).resolve().parent))
BASE = ROOT / "tasks"

# 需要关注的状态 -> 该状态允许的合理停留时长（小时）；超过即提醒
WATCH = {
    "awaiting_verification": 2.0,   # 等待验收：正常应在数小时内处理
    "created": 12.0,                # 建了没跑
    "verification_failed": 6.0,     # 验收失败待处理
    "orphaned": 1.0,                # 孤儿任务
}


def age_hours(data):
    """用 updated_at 计算停留时长；缺失则用 created_at，再缺失返回 None。"""
    ts = data.get("updated_at") or data.get("created_at")
    if not isinstance(ts, (int, float)) or ts <= 0:
        return None
    return (time.time() - ts) / 3600.0


def scan(remind_h, critical_h):
    items = []
    if not BASE.is_dir():
        return items
    for p in sorted(BASE.iterdir()):
        if p.is_symlink() or not (p / "task.json").is_file():
            continue
        try:
            data = json.loads((p / "task.json").read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            continue
        status = data.get("status")
        if status not in WATCH:
            continue
        age = age_hours(data)
        if age is None:
            continue
        # 阈值取"该状态允许时长"与"用户显式指定"的较大者，避免对 created 之类误报
        threshold = max(WATCH[status], remind_h if status == "awaiting_verification" else 0)
        if age < threshold:
            continue
        level = "WARN" if age >= critical_h else "INFO"
        items.append({
            "id": data.get("id", p.name),
            "status": status,
            "age_hours": round(age, 2),
            "level": level,
            "goal": (data.get("goal") or "")[:60],
            "last_cmd": data.get("run_argv"),
            "has_accept_cmd": bool(data.get("acceptance_argv")),
        })
    # 严重的排前面
    items.sort(key=lambda x: (-x["age_hours"], x["id"]))
    return items


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--hours", type=float, default=2.0,
                    help="awaiting_verification 提醒阈值（小时），默认 2")
    ap.add_argument("--critical", type=float, default=24.0,
                    help="升级为 WARN 的阈值（小时），默认 24")
    ap.add_argument("--json", action="store_true")
    args = ap.parse_args()

    items = scan(args.hours, args.critical)

    if args.json:
        print(json.dumps({"items": items, "count": len(items)}, ensure_ascii=False, indent=2))
    elif not items:
        print("任务队列正常（无停滞任务）")
    else:
        print(f"发现 {len(items)} 个停滞任务：")
        for it in items:
            d = it["age_hours"]
            when = f"{d:.1f} 小时" if d < 48 else f"{d / 24:.1f} 天"
            print(f"  [{it['level']}] {it['id']}  {it['status']}  已 {when}")
            if it["goal"]:
                print(f"         目标: {it['goal']}")
            if it["status"] == "awaiting_verification":
                hint = ("verify <id> --accept  # 人工已确认通过，直接关闭"
                        if not it["has_accept_cmd"] else
                        "verify <id>  # 跑登记的验收命令；或用 --accept 人工裁决")
                print(f"         建议: {hint}")
            elif it["status"] == "verification_failed":
                print("         建议: reset <id> 重开验收，或 verify <id> --accept")
        warns = [i for i in items if i["level"] == "WARN"]
        if warns:
            print(f"\n⚠️  {len(warns)} 个任务停滞超过 {args.critical:.0f} 小时，需要人工介入")

    if any(i["level"] == "WARN" for i in items):
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
