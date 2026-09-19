#!/usr/bin/env bash
# ensure-telegram-alive.sh - Telegram polling keepalive
# Cron: */3 * * * * /usr/local/bin/ensure-telegram-alive.sh
set -euo pipefail
GW="openclaw-gateway"
LOG="/var/log/ensure-tg-alive.log"
log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$LOG"; }
RECENT=$(docker logs "$GW" --since 5m 2>&1 | grep -c 'outbound send ok' || true)
if [ "$RECENT" -gt 0 ]; then exit 0; fi
if ! docker ps --format '{{.Names}}' | grep -q "$GW"; then
    log "WARN: gateway not running, restarting"
    docker start "$GW" 2>/dev/null || true
    exit 0
fi
if ! docker exec "$GW" openclaw health >/dev/null 2>&1; then
    log "WARN: gateway unhealthy, restarting"
    docker restart "$GW" 2>/dev/null || true
    exit 0
fi
ERRORS=$(docker logs "$GW" --since 5m 2>&1 | grep -ci 'telegram.*error' || true)
if [ "$ERRORS" -gt 0 ]; then
    log "WARN: $ERRORS TG errors, restarting"
    docker restart "$GW" 2>/dev/null || true
fi
