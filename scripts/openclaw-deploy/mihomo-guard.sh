#!/usr/bin/env bash
# ============================================================
# mihomo-guard.sh - Auto-switch proxy nodes on failure
# ============================================================
# Detects dead proxy nodes and switches to best available.
# Run via cron: */5 * * * * /usr/local/bin/mihomo-guard.sh
#
# Requires: docker + curl + python3 on the docker HOST (queries mihomo external-controller on 127.0.0.1:9090)
# ============================================================

set -euo pipefail

MIHOMO="mihomo-tun"
GROUP="${MIHOMO_PROXY_GROUP:-main-proxy}"  # set MIHOMO_PROXY_GROUP env var or edit here
LOG="/var/log/mihomo-guard.log"
MAX_LOG=5120  # KB

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$LOG"
}

rotate_log() {
    if [ -f "$LOG" ] && [ "$(stat -c%s "$LOG" 2>/dev/null || echo 0)" -gt "$((MAX_LOG * 1024))" ]; then
        mv "$LOG" "${LOG}.old"
        log "Log rotated"
    fi
}

# Check if mihomo is running
if ! docker ps --format '{{.Names}}' | grep -q "$MIHOMO"; then
    log "WARN: $MIHOMO not running, attempting restart"
    docker restart "$MIHOMO" 2>/dev/null || true
    exit 0
fi

# Get current active proxy
ACTIVE=$(curl -s http://127.0.0.1:9090/proxies/$GROUP 2>/dev/null     | python3 -c "import sys,json; print(json.load(sys.stdin).get('now',''))" 2>/dev/null || echo "")

if [ -z "$ACTIVE" ]; then
    log "WARN: Cannot get active proxy from $GROUP"
    exit 1
fi

# Test connectivity through proxy (use a fast endpoint)
HTTP_CODE=$(curl -s -o /dev/null -w '%{http_code}'     --max-time 10 --proxy http://127.0.0.1:7890     http://cp.cloudflare.com/generate_204 2>/dev/null || echo "000")

if [ "$HTTP_CODE" = "204" ] || [ "$HTTP_CODE" = "200" ]; then
    # All good, just log and rotate
    rotate_log
    exit 0
fi

# Failed - try switching to next node
log "WARN: Proxy test failed (HTTP $HTTP_CODE) for $ACTIVE"

# Get all proxies in group and try next
PROXIES=$(curl -s http://127.0.0.1:9090/proxies/$GROUP 2>/dev/null     | python3 -c "
import sys, json
data = json.load(sys.stdin)
all_p = data.get('all', [])
now = data.get('now', '')
idx = next((i for i,p in enumerate(all_p) if p.get('name')==now), 0)
# Try next 3 proxies
for i in range(1, min(4, len(all_p))):
    p = all_p[(idx+i) % len(all_p)]
    if p.get('type') != 'Selector':
        print(p['name'])
" 2>/dev/null || echo "")

for NODE in $PROXIES; do
    log "Trying: $NODE"
    curl -s -X PUT http://127.0.0.1:9090/proxies/$GROUP         -H 'Content-Type: application/json'         -d "{"name":"$NODE"}" >/dev/null 2>&1

    sleep 2
    NEW_CODE=$(curl -s -o /dev/null -w '%{http_code}'         --max-time 10 --proxy http://127.0.0.1:7890         http://cp.cloudflare.com/generate_204 2>/dev/null || echo "000")

    if [ "$NEW_CODE" = "204" ] || [ "$NEW_CODE" = "200" ]; then
        log "OK: Switched to $NODE (HTTP $NEW_CODE)"
        exit 0
    fi
done

log "CRITICAL: All nodes failed. Current: $ACTIVE"
rotate_log
exit 1
