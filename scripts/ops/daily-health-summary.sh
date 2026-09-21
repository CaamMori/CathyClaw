#!/usr/bin/env bash
# 每日确定性健康摘要:读取已有 status.json,直接发送 Telegram,不调用 Agent/模型。
set -euo pipefail

MODE="${1:---print}"
STATUS=/data/state/workspace/status.json
TARGET="${HEALTH_SUMMARY_TARGET:-${TARGET_CHAT_ID:-YOUR_TELEGRAM_CHAT_ID}}"
LOCK=/var/run/openclaw-daily-health-summary.lock
LOG=/var/log/openclaw-daily-health-summary.log

case "$MODE" in
  --print|--send) ;;
  *) echo "Usage: $0 [--print|--send]" >&2; exit 2 ;;
esac

exec 9>"$LOCK"
flock -n 9 || exit 0

msg=$(python3 - "$STATUS" <<'PY'
import datetime as dt
import json
import os
import sys

path=sys.argv[1]
now=dt.datetime.now().astimezone()
lines=[f"🩺 OpenClaw 每日健康摘要 {now:%Y-%m-%d %H:%M:%S %Z}"]
try:
    with open(path, encoding='utf-8') as f:
        data=json.load(f)
except Exception as e:
    print("\n".join(lines+[f"🔴 状态文件不可读: {type(e).__name__}"]))
    raise SystemExit(1)

sc=data.get('selfcheck') or {}
total=int(sc.get('total') or 0)
ok=int(sc.get('ok') or 0)
failed=int(sc.get('failed') or 0)
state_ts=sc.get('ts')
age_seconds=sc.get('age_seconds')
if age_seconds is None and state_ts:
    try:
        parsed=dt.datetime.strptime(state_ts, '%Y-%m-%dT%H:%M:%S%z')
        age_seconds=max(0, int((now-parsed).total_seconds()))
    except Exception:
        age_seconds=None

fresh=age_seconds is not None and age_seconds <= 1800
healthy=total > 0 and failed == 0 and ok == total and fresh
lines.append(f"{'🟢' if healthy else '🔴'} 自检: {ok}/{total} 通过,{failed} 项异常")
if age_seconds is None:
    lines.append("⚠️ 自检时间不可解析")
elif not fresh:
    lines.append(f"⚠️ 自检数据已过期 {age_seconds//60} 分钟")
else:
    lines.append(f"• 自检数据年龄: {age_seconds//60} 分钟")

for item in sc.get('items') or []:
    if not item.get('ok'):
        detail=str(item.get('detail') or '')[:120]
        lines.append(f"  ❌ {item.get('name') or item.get('id')}: {detail}")

eg=data.get('egress') or {}
eg_ok=bool(eg.get('ok'))
lines.append(f"{'🟢' if eg_ok else '🔴'} 出口: {'可达' if eg_ok else '异常'} (HTTP {eg.get('code') or '无'})")

containers=[]
for c in data.get('containers') or []:
    name=str(c.get('name') or '')
    if name == 'openclaw-gateway' or 'mihomo' in name:
        status=str(c.get('status') or 'unknown')
        up=status.startswith('Up')
        containers.append((name,status,up))
        lines.append(f"{'🟢' if up else '🔴'} {name}: {status}")
if not containers:
    lines.append("🔴 未找到 Gateway/Mihomo 容器状态")

all_ok=healthy and eg_ok and bool(containers) and all(v[2] for v in containers)
lines.append("结论: 今日运行正常" if all_ok else "结论: 存在异常,请查看实时告警或 /status")
print("\n".join(lines))
raise SystemExit(0 if all_ok else 1)
PY
) || build_rc=$?
build_rc=${build_rc:-0}

if [ "$MODE" = "--print" ]; then
  printf '%s\n' "$msg"
  exit "$build_rc"
fi

# 即使状态异常也发送摘要;异常退出码只用于日志标记,不阻止告警投递。
if timeout 30 docker exec openclaw-gateway openclaw message send \
  --channel telegram --target "$TARGET" -m "$msg" >/dev/null 2>&1; then
  printf '%s send=ok health_rc=%s\n' "$(date -Is)" "$build_rc" >> "$LOG"
  exit 0
fi
printf '%s send=failed health_rc=%s\n' "$(date -Is)" "$build_rc" >> "$LOG"
exit 1
