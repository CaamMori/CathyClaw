#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# cakeclaw alert — 告警通知脚本 (webhook / stdout)
# 由 watchdog.sh 调用，也支持独立触发
# ============================================================

SEVERITY="${1:-UNKNOWN}"
MESSAGE="${2:-}"
WEBHOOK_URL="${CAKECLAW_WEBHOOK_URL:-}"

TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')
HOST=$(hostname 2>/dev/null || echo "unknown")

# stdout 输出（始终有）
echo "[${TIMESTAMP}] [${SEVERITY}] ${HOST}: ${MESSAGE}"

# webhook（如果配置了）
if [ -n "${WEBHOOK_URL}" ]; then
  curl -s -X POST "${WEBHOOK_URL}" \
    -H 'Content-Type: application/json' \
    -d "{\"severity\":\"${SEVERITY}\",\"message\":\"${MESSAGE}\",\"host\":\"${HOST}\",\"ts\":\"${TIMESTAMP}\"}" \
    >/dev/null 2>&1 || true
fi
