#!/usr/bin/env bash
# stale_alert.sh —— 任务停滞告警（带去重，避免告警疲劳）
#
# 设计要点：
#   1) 只在 stale_guard.py 判定为 WARN（默认停滞 >24h）时才可能推送
#   2) 同一任务 24 小时内最多推送一次（去重），避免重复刷屏
#   3) 正常时完全静默，退出码 0，什么都不做
#
# 用法：由 cron 定期调用，无需人工干预
set -u

TE_DIR="/data/state/workspace/task-engine"
STATE="$TE_DIR/.stale_alert_state.json"
GW="openclaw-gateway"
TARGET="${TE_ALERT_TARGET:-YOUR_TELEGRAM_USER_ID}"
DEDUPE_HOURS="${STALE_DEDUPE_HOURS:-24}"

export TASK_ENGINE_HOME="$TE_DIR"
cd "$TE_DIR" || exit 1

# 1) 取 JSON 结果
out=$(python3 stale_guard.py --json 2>/dev/null) || exit 0

# 2) 只保留 WARN 级，并按去重窗口过滤
msg=$(python3 - "$STATE" "$DEDUPE_HOURS" <<'PY'
import json, sys, time, os
state_path, dedupe_h = sys.argv[1], float(sys.argv[2])
try:
    data = json.loads(sys.stdin.read())
except Exception:
    sys.exit(0)

state = {}
if os.path.exists(state_path):
    try:
        state = json.loads(open(state_path).read())
    except Exception:
        state = {}

now = time.time()
lines = []
dirty = False
for it in data.get("items", []):
    if it.get("level") != "WARN":
        continue
    tid = it["id"]
    last = state.get(tid, 0)
    if now - last < dedupe_h * 3600:
        continue  # 去重窗口内，跳过
    state[tid] = now
    dirty = True
    d = it["age_hours"]
    when = f"{d:.1f} 小时" if d < 48 else f"{d/24:.1f} 天"
    lines.append(f"• {tid}\n  状态 {it['status']}，已停滞 {when}\n  {it.get('goal','')}")

if dirty:
    try:
        json.dump(state, open(state_path, "w"))
    except Exception:
        pass

if lines:
    print("⚠️ 任务停滞告警（超过阈值需人工介入）\n" + "\n".join(lines) +
          "\n\n处理：verify <id> --accept 人工裁决通过；或 reset <id> 重开验收")
PY
)

[ -z "$msg" ] && exit 0

# 3) 经 gateway 推送到 Telegram
docker exec "$GW" openclaw message send --channel telegram --target "$TARGET" -m "$msg" >/dev/null 2>&1 || {
  echo "推送失败（gateway 可能不在线）" >&2
  exit 1
}
echo "已推送停滞告警"
