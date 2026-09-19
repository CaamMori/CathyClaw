#!/bin/bash
# Telegram 入站轮询僵死兜底
# 背景：宿主机自身无出网能力，出网由 mihomo-tun（与网关共享 netns）提供。
#       因此探测必须在「容器内」执行，不能走宿主机的 curl。
# 逻辑：容器内 getWebhookInfo 的 pending_update_count 连续 3 次 > 0 则重启网关。
#       重启网关后拉起 mihomo-tun（共享 netns），恢复出网。
set -u

TOKEN=$(docker exec openclaw-gateway printenv TELEGRAM_BOT_TOKEN 2>/dev/null) || exit 0
[ -z "$TOKEN" ] && exit 0

# 关键：在网关容器内探测（宿主机直连无效，host 侧无出网）
RAW=$(docker exec openclaw-gateway sh -c "curl -sk --max-time 20 'https://api.telegram.org/bot${TOKEN}/getWebhookInfo'" 2>/dev/null)
PENDING=$(printf '%s' "$RAW" | python3 -c 'import json,sys
try:
    print(json.load(sys.stdin)["result"].get("pending_update_count",0))
except Exception:
    print(-1)
' 2>/dev/null)

CNTFILE=/tmp/tg-stuck-count
FAILFILE=/tmp/tg-probe-fail

if [ "$PENDING" -gt 0 ] 2>/dev/null; then
  CNT=$(( $(cat "$CNTFILE" 2>/dev/null || echo 0) + 1 ))
  echo "$CNT" > "$CNTFILE"
  logger -t tg-alive "pending=$PENDING (count=$CNT/3)"
  if [ "$CNT" -ge 3 ]; then
    logger -t tg-alive "pending=$PENDING for $CNT consecutive checks -> restarting gateway"
    docker restart openclaw-gateway >/dev/null 2>&1
    sleep 20
    # Gateway restart 会更换 network namespace。统一重建 Mihomo 并清理旧沙箱,
    # 由 OpenClaw 按需创建并绑定当前 namespace;失败保留计数供下一轮继续恢复。
    if /usr/local/bin/openclaw-network-recover.sh >/dev/null 2>&1; then
      rm -f "$CNTFILE" "$FAILFILE"
    else
      logger -t tg-alive "post-restart network recovery failed; will retry"
    fi
  fi
elif [ "$PENDING" = "-1" ]; then
  FC=$(( $(cat "$FAILFILE" 2>/dev/null || echo 0) + 1 ))
  echo "$FC" > "$FAILFILE"
  logger -t tg-alive "probe FAILED (unreachable) count=$FC"
  rm -f "$CNTFILE"
else
  rm -f "$CNTFILE" "$FAILFILE"
fi
