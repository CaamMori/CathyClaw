#!/usr/bin/env bash
# Rebind services that share the gateway network namespace after gateway restart/recreate.
set -uo pipefail
GW=openclaw-gateway
MH=mihomo-tun
COMPOSE_FILE=/data/scripts/docker-compose.gateway.yml
LOG=/var/log/openclaw-network-recover.log

log() { printf '%s %s\n' "$(date '+%F %T')" "$*" | tee -a "$LOG"; }

if ! docker ps --format '{{.Names}}' | grep -qx "$GW"; then
  log "ERROR gateway is not running"
  exit 1
fi

# A restart creates a fresh network namespace. Force-recreate the sidecar so it
# binds the current namespace instead of retaining the old container namespace.
if ! docker compose -f "$COMPOSE_FILE" up -d --force-recreate "$MH" >/dev/null 2>&1; then
  log "ERROR failed to recreate $MH"
  exit 1
fi

# Wait for the mixed proxy port and validate Telegram through the actual proxy.
ok=0
for _ in $(seq 1 12); do
  if timeout 12 docker exec "$GW" curl -fsS -x http://127.0.0.1:10808 --max-time 8 https://api.telegram.org/ -o /dev/null 2>/dev/null; then
    ok=1
    break
  fi
  sleep 3
done
if [ "$ok" -ne 1 ]; then
  log "ERROR $MH recreated but Telegram proxy probe failed"
  exit 1
fi

# Sandboxes joining the gateway namespace must be removed, not merely restarted;
# OpenClaw recreates them on demand with the current namespace and config.
timeout 45 docker exec "$GW" openclaw sandbox recreate --all --force >/dev/null 2>&1 || true
/usr/local/bin/pin-sbx-restart.sh >/dev/null 2>&1 || true
log "OK mihomo rebound, proxy verified, sandboxes marked for clean recreation"
