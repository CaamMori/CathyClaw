#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# cakeclaw audit — 会话日志审计 + 用量统计
# cron: 0 * * * * /data/scripts/audit.sh >> /data/logs/audit.log 2>&1
# ============================================================

AUDIT_DIR="/data/logs/audit"
# Gateway 日志在容器内 /tmp/openclaw/openclaw.log
# 优先从容器 cp 出来；不存在则静默跳过
GW_LOG="/tmp/openclaw/openclaw.log"
GW_LOG_TMP=""

# 尝试从运行中的容器拷贝日志
CID=$(docker ps --filter name=cakeclaw-gateway --format '{{.ID}}' 2>/dev/null | head -1)
if [ -n "${CID}" ]; then
  GW_LOG_TMP="/tmp/audit-gw-$$.log"
  docker cp "${CID}:/tmp/openclaw/openclaw.log" "${GW_LOG_TMP}" 2>/dev/null && GW_LOG="${GW_LOG_TMP}" || true
fi
REPORT="${AUDIT_DIR}/$(date -u +%Y%m%dT%H%M%SZ).json"
mkdir -p "${AUDIT_DIR}"

TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)
HOUR_AGO=$(date -u -d '1 hour ago' +%Y-%m-%dT%H:%M 2>/dev/null || date -u -v-1H +%Y-%m-%dT%H:%M 2>/dev/null || echo "")

# ── Gateway 日志摘要 ──
GW_RUNNING=$(docker ps --filter name=cakeclaw-gateway --format '{{.Status}}' 2>/dev/null | grep -c 'Up' || echo 0)
GW_UPTIME=$(docker ps --filter name=cakeclaw-gateway --format '{{.Status}}' 2>/dev/null | sed 's/.*Up //' | sed 's/ (.*//' || echo "N/A")

# ── System 状态快照 ──
DISK=$(df -P / | awk 'NR==2{gsub("%","",$5);print $5}')
MEM=$(free -g | awk '/Mem:/{print $7}')
CPU=$(awk '{print $1}' /proc/loadavg 2>/dev/null || echo 0)

# ── Docker 容器统计 ──
CONTAINERS=$(docker ps -q 2>/dev/null | wc -l)
IMAGES=$(docker images -q 2>/dev/null | wc -l)

# ── Nginx 最近请求统计 ──
NGX_REQUESTS=0; NGX_ERRORS=0
if [ -f /var/log/nginx/access.log ]; then
  if [ -n "${HOUR_AGO}" ]; then
    NGX_REQUESTS=$(awk -v since="${HOUR_AGO}" '$0 > since {count++} END{print count+0}' /var/log/nginx/access.log 2>/dev/null || echo 0)
    NGX_ERRORS=$(grep -c ' 500\| 502\| 503\| 504' /var/log/nginx/access.log 2>/dev/null | tail -1 || echo 0)
  else
    NGX_REQUESTS=$(wc -l < /var/log/nginx/access.log 2>/dev/null || echo 0)
  fi
fi

# ── Gateway 日志最近 error ──
GW_ERRORS=0
if [ -f "${GW_LOG}" ]; then
  GW_ERRORS=$(grep -ci 'error\|fatal\|fail' "${GW_LOG}" 2>/dev/null | tail -1 || echo 0)
fi

# ── 备份数量 + 最新备份 ──
BK_COUNT=$(find /data/backups/openclaw-state/ -maxdepth 1 -type d -name '20*' 2>/dev/null | wc -l)
BK_LATEST=$(find /data/backups/openclaw-state/ -maxdepth 1 -type d -name '20*' -printf '%f\n' 2>/dev/null | sort -r | head -1 || echo "none")

# ── 写报告 ──
cat > "${REPORT}" << EOF
{
  "ts": "${TS}",
  "gw": {
    "running": ${GW_RUNNING},
    "uptime": "${GW_UPTIME}",
    "errors_24h": ${GW_ERRORS}
  },
  "system": {
    "disk_pct": ${DISK},
    "mem_free_gb": ${MEM},
    "load_1m": ${CPU}
  },
  "docker": {
    "containers": ${CONTAINERS},
    "images": ${IMAGES}
  },
  "nginx": {
    "requests_1h": ${NGX_REQUESTS},
    "errors_5xx": ${NGX_ERRORS}
  },
  "backup": {
    "count": ${BK_COUNT},
    "latest": "${BK_LATEST}"
  }
}
EOF

echo "[$(date '+%Y-%m-%d %H:%M')] gw=${GW_RUNNING} disk=${DISK}% mem=${MEM}G ngx_req=${NGX_REQUESTS} bk=${BK_COUNT} → ${REPORT}"

# 清理临时日志转储
[ -n "${GW_LOG_TMP}" ] && rm -f "${GW_LOG_TMP}"

# 清理 30 天前的审计报告
find "${AUDIT_DIR}" -name '*.json' -mtime +30 -delete 2>/dev/null || true
