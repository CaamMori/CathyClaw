#!/bin/bash
# selfcheck-quick-cron.sh — 10 分钟关键项快检;全绿静默,异常才经 Telegram 推送
set -u
LOG=/var/log/selfcheck-cron.log
# 统一落盘机读产物(gen_status.py 面板消费),使本脚本成为唯一自检触发者;
# --write-state 与输出互不干扰(结果同时写 stdout 与 state 文件)。参考 §B9.14。
OUT=$(timeout 400 /usr/local/bin/selfcheck.py --quick --write-state 2>&1)
RC=$?

# 全绿(exit=0)→ 静默退出,忽略 stdout 噪音(mihomo-autoswitch 等子进程可能混入)
if [ "$RC" -eq 0 ]; then
  exit 0
fi

# 空输出也静默退出
if [ -z "$OUT" ]; then
  exit 0
fi

echo "$(date '+%Y-%m-%d %H:%M:%S') rc=$RC" >> "$LOG"
echo "$OUT" >> "$LOG"

# 异常 → 推送 Telegram(在容器内发,宿主无外网)
docker exec openclaw-gateway sh -c 'cat > /tmp/selfcheck-msg.txt' <<< "$OUT" 2>/dev/null
docker exec openclaw-gateway openclaw message send --channel telegram \
  --target ${TARGET_CHAT_ID:-YOUR_TELEGRAM_CHAT_ID} -m "$OUT" >/dev/null 2>&1 || \
  docker exec openclaw-gateway openclaw message send --channel telegram \
  --target ${TARGET_CHAT_ID:-YOUR_TELEGRAM_CHAT_ID} --text "$(echo "$OUT" | tr '\n' ' ')" >/dev/null 2>&1

# 日志滚动
tail -n 200 "$LOG" > "$LOG.tmp" 2>/dev/null && mv "$LOG.tmp" "$LOG"
exit 0
