#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# cakeclaw failover — 主备切换框架
# 单机模式: 同机重启备用 Gateway 实例（同一镜像，不同端口）
# 多机模式: 检测主节点不可达时 SSH 到备机启动 Gateway
# ============================================================

PRIMARY_PORT="${1:-18789}"
FALLBACK_PORT="${GATEWAY_PORT:-28779}"
MODE="${CAKECLAW_FAILOVER_MODE:-local}"  # local | remote
REMOTE_HOST="${CAKECLAW_FAILOVER_HOST:-}"

now() { date '+%Y-%m-%d %H:%M:%S'; }

# 检测主 Gateway
check_primary() {
  curl -s -o /dev/null -w '%{http_code}' --connect-timeout 5 \
    "http://127.0.0.1:${PRIMARY_PORT}/" 2>/dev/null || echo "000"
}

# 本地 fallback: 同机启动备用实例
fallback_local() {
  echo "[$(now)] starting fallback on port ${FALLBACK_PORT}"
  docker run -d --rm \
    --name cakeclaw-fallback \
    --restart unless-stopped \
    --memory "${GATEWAY_MEM_LIMIT:-4g}" \
    --cpus "${GATEWAY_CPU_LIMIT:-1}" \
    --pids-limit "${GATEWAY_PID_LIMIT:-1024}" \
    -p "127.0.0.1:${FALLBACK_PORT}:18789" \
    -v /data/state:/home/node/.openclaw \
    -v /data/workspace:/data/workspace \
    --env-file /data/etc/openclaw/runtime.env \
    "${GATEWAY_IMAGE:-ghcr.io/openclaw/openclaw:2026.7.1}" 2>&1

  echo "[$(now)] fallback started on :${FALLBACK_PORT}"

  # 更新 Nginx 到 fallback 端口
  local ngx_conf="/etc/nginx/sites-available/cakeclaw"
  if [ -f "${ngx_conf}" ]; then
    sed -i "s|proxy_pass http://127.0.0.1:${PRIMARY_PORT};|proxy_pass http://127.0.0.1:${FALLBACK_PORT};|" "${ngx_conf}"
    nginx -t && systemctl reload nginx
    echo "[$(now)] nginx → :${FALLBACK_PORT}"
  fi
}

# 远程 fallback: SSH 到备机（需配置 CAKECLAW_FAILOVER_HOST）
fallback_remote() {
  echo "[$(now)] remote failover to ${REMOTE_HOST}"
  ssh -o ConnectTimeout=10 "${REMOTE_HOST}" \
    "cd /opt/cakeclaw && docker compose up -d" 2>&1

  [ -x /data/scripts/alert.sh ] && \
    bash /data/scripts/alert.sh "HIGH" "Failover to ${REMOTE_HOST} triggered" 2>/dev/null || true
}

# ── main ──
STATUS=$(check_primary)

if [ "${STATUS}" != "200" ]; then
  echo "[$(now)] primary :${PRIMARY_PORT} returned ${STATUS}, triggering failover"

  if [ "${MODE}" = "remote" ] && [ -n "${REMOTE_HOST}" ]; then
    fallback_remote
  else
    # 检查 fallback 是否已在运行
    if docker ps --filter name=cakeclaw-fallback --format '{{.Status}}' 2>/dev/null | grep -q 'Up'; then
      echo "[$(now)] fallback already running, skip"
    else
      fallback_local
    fi
  fi
else
  # 如果主节点恢复了，先恢复 Nginx 路由，再停掉 fallback
  if docker ps --filter name=cakeclaw-fallback --format '{{.Status}}' 2>/dev/null | grep -q 'Up' 2>/dev/null; then
    echo "[$(now)] primary recovered, restoring nginx, stopping fallback"
    ngx_conf="/etc/nginx/sites-available/cakeclaw"
    if [ -f "${ngx_conf}" ]; then
      sed -i "s|proxy_pass http://127.0.0.1:${FALLBACK_PORT};|proxy_pass http://127.0.0.1:${PRIMARY_PORT};|" "${ngx_conf}"
      if nginx -t && systemctl reload nginx; then
        echo "[$(now)] nginx → :${PRIMARY_PORT}"
        docker rm -f cakeclaw-fallback 2>/dev/null || true
      else
        echo "[$(now)] ERROR: nginx validation/reload failed"
        if ! sed -i "s|proxy_pass http://127.0.0.1:${PRIMARY_PORT};|proxy_pass http://127.0.0.1:${FALLBACK_PORT};|" "${ngx_conf}"; then
          echo "[$(now)] FATAL: config rollback failed, manual recovery required"
        else
          echo "[$(now)] config restored to fallback :${FALLBACK_PORT}"
        fi
        exit 1
      fi
    else
      docker rm -f cakeclaw-fallback 2>/dev/null || true
      echo "[$(now)] fallback stopped, no nginx config to update"
    fi
  fi
fi
