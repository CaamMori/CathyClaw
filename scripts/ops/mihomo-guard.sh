#!/bin/bash
# mihomo-guard.sh v2 — 模型 API 出口连通守护
# 每 2 分钟探测；连续 2 次失败自动切节点；自愈失败且全死持续 6 分钟 → 推一次 Telegram 告警（恢复后自动解除）。
GW=openclaw-gateway
PROBE_URL="https://newapitest.caner.hk/v1/models"
TARGET="${TARGET_CHAT_ID:-YOUR_TELEGRAM_CHAT_ID}"
STATE=/var/run/mihomo-guard.fail
DEAD=/var/run/mihomo-guard.alldead
LOG=/var/log/mihomo-guard.log

log() { echo "$(date '+%F %T') $*" >> "$LOG"; }
notify() { docker exec "$GW" openclaw message send --channel telegram --target "$TARGET" -m "$1" >/dev/null 2>&1; }

probe() {
  code=$(docker exec "$GW" curl -s -o /dev/null -w '%{http_code}' --max-time 8 "$PROBE_URL" 2>/dev/null)
  [ -n "$code" ] && [ "$code" != "000" ]
}

if probe; then
  [ -f "$STATE" ] && rm -f "$STATE"
  if [ -f "$DEAD" ]; then
    rm -f "$DEAD" "$DEAD.notified"
    log "出口已恢复"
    notify "[mihomo-guard] 模型API出口已恢复 ✅"
  fi
  exit 0
fi

n=$(cat "$STATE" 2>/dev/null || echo 0)
n=$((n+1))
echo "$n" > "$STATE"
log "探测失败($n): code=${code:-none}"
[ "$n" -lt 2 ] && exit 0

rm -f "$STATE"
if /usr/local/bin/mihomo-autoswitch.sh >> "$LOG" 2>&1; then
  sleep 3
  if probe; then
    log "自动切换成功,复验通过"
    exit 0
  fi
  log "切换后仍失败"
fi

d=$(cat "$DEAD" 2>/dev/null || echo 0)
d=$((d+1))
echo "$d" > "$DEAD"
log "自愈失败($d)"
if [ "$d" -ge 3 ] && [ ! -f "$DEAD.notified" ]; then
  touch "$DEAD.notified"
  log "全部节点不可用,推送告警"
  notify "[mihomo-guard] ⚠️ 机场节点全部不可用(约 $((d*2)) 分钟),模型API不通,agent 无法响应。节点恢复后本守护会自动切换并通知。"
fi
