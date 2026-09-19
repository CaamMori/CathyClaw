#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# cakeclaw worker-register — Worker 节点注册脚本
# 用法: bash worker-register.sh <master-url> [--labels tag1,tag2]
# 注意: 依赖 Gateway 端 /api/workers/register 接口（OpenClaw 当前无此接口）
# ============================================================

MASTER="${1:-}"
LABELS_ARG=""
[ "${2:-}" = "--labels" ] && LABELS_ARG="${3:-}"

if [ -z "${MASTER}" ]; then
  echo "用法: worker-register.sh <master-url> [--labels tag1,tag2]"
  echo "例如: worker-register.sh http://10.0.0.4:18789 --labels primary"
  exit 1
fi

WORKER_ID=$(hostname)
WORKER_PORT="${CAKECLAW_WORKER_PORT:-18789}"
WORKER_HOST="${CAKECLAW_WORKER_HOST:-$(hostname -I | awk '{print $1}')}"

REGISTER_FILE="/data/state/worker-id"
mkdir -p /data/state

if [ -f "${REGISTER_FILE}" ]; then
  WORKER_ID=$(cat "${REGISTER_FILE}")
else
  WORKER_ID="${WORKER_ID}-$(date +%s)"
  echo "${WORKER_ID}" > "${REGISTER_FILE}"
fi

CPU_CORES=$(nproc)
MEM_GB=$(free -g | awk '/Mem:/{print $2}')
DISK_GB=$(df -BG / | awk 'NR==2{gsub("G","",$2);print $2}')

LABEL_LIST="[]"
if [ -n "${LABELS_ARG}" ] && [ -n "$(echo "${LABELS_ARG}" | tr -d ' ')" ]; then
  LABEL_LIST=$(echo "${LABELS_ARG}" | tr ',' '\n' | sed 's/^/"/;s/$/"/' | paste -sd,)
  LABEL_LIST="[${LABEL_LIST}]"
fi

PAYLOAD=$(cat << EOF
{
  "worker_id": "${WORKER_ID}",
  "host": "${WORKER_HOST}",
  "port": ${WORKER_PORT},
  "capacity": {"cpu": ${CPU_CORES}, "mem_gb": ${MEM_GB}, "disk_gb": ${DISK_GB}},
  "labels": ${LABEL_LIST}
}
EOF
)

echo "[$(date '+%Y-%m-%d %H:%M:%S')] registering ${WORKER_ID} → ${MASTER}"

HTTP_CODE=$(curl -s -o /tmp/worker-register-response.json -w '%{http_code}' \
  -X POST "${MASTER}/api/workers/register" \
  -H "Content-Type: application/json" \
  -d "${PAYLOAD}" 2>/dev/null || echo "000")

case "${HTTP_CODE}" in
  200|201)
    echo "[$(date '+%H:%M:%S')] registered ok"
    ;;
  404)
    echo "[$(date '+%H:%M:%S')] FAILED — /api/workers/register 不存在"
    echo "  OpenClaw Gateway 当前版本无多 Worker API。此脚本为设计稿配套客户端。"
    echo "  参见 docs/phase4-plan.md 了解完整设计。"
    exit 1
    ;;
  *)
    echo "[$(date '+%H:%M:%S')] FAILED (HTTP ${HTTP_CODE})"
    echo "  检查 Master 是否可达: curl ${MASTER}/"
    exit 1
    ;;
esac
