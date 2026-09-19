#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# cakeclaw master-discover — Worker 心跳 + 发现脚本
# 注意: 依赖 Gateway 端 /api/workers/heartbeat 接口（OpenClaw 当前无此接口）
# 用法: bash master-discover.sh <master-url>
# ============================================================

MASTER="${1:-}"
HEARTBEAT_FILE="/data/state/heartbeat.last"
WORKER_ID_FILE="/data/state/worker-id"
mkdir -p /data/state

if [ -z "${MASTER}" ]; then echo "用法: master-discover.sh <master-url>"; exit 1; fi

WORKER_ID=$(cat "${WORKER_ID_FILE}" 2>/dev/null || echo "unknown")

HTTP_CODE=$(curl -s -o /dev/null -w '%{http_code}' \
  --connect-timeout 5 \
  "${MASTER}/api/workers/heartbeat" \
  -H "Content-Type: application/json" \
  -d "{\"worker_id\":\"${WORKER_ID}\"}" 2>/dev/null || echo "000")

NOW=$(date +%s)
echo "${NOW}" > "${HEARTBEAT_FILE}"

case "${HTTP_CODE}" in
  200)
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] heartbeat ok (${WORKER_ID})"
    ;;
  404)
    echo "[$(date '+%H:%M:%S')] /api/workers/heartbeat 不存在 — OpenClaw 当前版本无多 Worker API"
    echo "  此脚本为设计稿配套客户端，参见 docs/phase4-plan.md"
    ;;
  000)
    echo "[$(date '+%H:%M:%S')] Master 不可达 (${MASTER})"
    ;;
  *)
    echo "[$(date '+%H:%M:%S')] heartbeat failed (HTTP ${HTTP_CODE})"
    ;;
esac
