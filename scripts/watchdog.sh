#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# cakeclaw watchdog — 健康评分 + 自动重启 + 告警
# cron: */5 * * * * /data/scripts/watchdog.sh >> /data/logs/watchdog.log 2>&1
# ============================================================

GW="cakeclaw-gateway"
LOG_DIR="/data/logs/watchdog"
STATE="${LOG_DIR}/state"
ALERT="/data/scripts/alert.sh"
mkdir -p "${LOG_DIR}"

now() { date '+%Y-%m-%d %H:%M:%S'; }

alert() {
  local sev="$1" msg="$2"
  echo "[$(now)] ALERT[${sev}] ${msg}"
  [ -x "${ALERT}" ] && bash "${ALERT}" "${sev}" "${msg}" 2>/dev/null || true
}

# ── 指标收集 ──
DISK=$(df -P / | awk 'NR==2{gsub("%","",$5);print $5}')
MEM=$(free -g | awk '/Mem:/{print $7}')
CPU=$(awk '{print $1}' /proc/loadavg 2>/dev/null || echo 0)
GW_S=$(docker ps --filter "name=${GW}" --format '{{.Status}}' 2>/dev/null || echo "down")

if echo "${GW_S}" | grep -q "^Up"; then
  echo "${GW_S}" | grep -q "unhealthy" && GW_H="unhealthy" || GW_H="healthy"
else
  GW_H="down"
fi

# ── 加载历史 ──
FAILS=0; LAST_RESTART=0
# shellcheck disable=SC1090  # STATE 是运行时状态文件，路径非常量属于正常设计
[ -f "${STATE}" ] && source "${STATE}" 2>/dev/null || true

# ── 评分 ──
SCORE=100; ALERTS=""
[ "${DISK}" -gt 90 ] && { SCORE=$((SCORE-30)); ALERTS="${ALERTS} disk:${DISK}%"; }
[ "${MEM}" -lt 1 ]   && { SCORE=$((SCORE-30)); ALERTS="${ALERTS} mem:${MEM}G"; }
[ "${GW_H}" = "down" ]      && { SCORE=$((SCORE-50)); ALERTS="${ALERTS} gw:down"; }
[ "${GW_H}" = "unhealthy" ] && { SCORE=$((SCORE-20)); ALERTS="${ALERTS} gw:unhealthy"; }

# ── 连续异常计数 ──
[ "${GW_H}" != "healthy" ] && FAILS=$((FAILS+1)) || FAILS=0

# ── 自动重启 ──
TS=$(date +%s)
RESTART=false
[ "${GW_H}" = "down" ]      && [ "${FAILS}" -ge 3 ] && RESTART=true
[ "${GW_H}" = "unhealthy" ] && [ "${FAILS}" -ge 6 ] && RESTART=true

if [ "${RESTART}" = true ] && [ $((TS - LAST_RESTART)) -lt 600 ]; then
  echo "[$(now)] restart skipped: cooldown"
  RESTART=false
fi

if [ "${RESTART}" = true ]; then
  echo "[$(now)] restarting ${GW} (${GW_H} ×${FAILS})"
  docker rm -f "${GW}" 2>/dev/null || true
  sleep 3
  COMPOSE_FILE="/data/etc/openclaw/docker-compose.yml"
  if [ -f "${COMPOSE_FILE}" ]; then
    docker compose -f "${COMPOSE_FILE}" up -d 2>&1
    alert "HIGH" "Gateway restarted (was ${GW_H}, score=${SCORE})"
  else
    alert "HIGH" "Gateway restart FAILED: ${COMPOSE_FILE} missing (was ${GW_H}, score=${SCORE}). Container removed, compose file not found."
  fi
  LAST_RESTART=${TS}; FAILS=0
fi

# ── 告警 ──
[ "${SCORE}" -lt 70 ] && alert "HIGH" "score=${SCORE}${ALERTS}"
[ "${SCORE}" -ge 70 ] && [ "${SCORE}" -lt 90 ] && alert "LOW" "score=${SCORE}${ALERTS}"

# ── 持久化 ──
cat > "${STATE}" << EOF
FAILS=${FAILS}
LAST_RESTART=${LAST_RESTART}
LAST_SCORE=${SCORE}
LAST_RUN=${TS}
EOF

echo "[$(now)] score=${SCORE} disk=${DISK}% mem=${MEM}G cpu=${CPU} gw=${GW_H} fails=${FAILS}"
