#!/usr/bin/env bash
# pin-sbx-restart.sh - Ensure sandbox containers have unless-stopped policy
# Run via cron: */2 * * * * /usr/local/bin/pin-sbx-restart.sh
set -euo pipefail
LOG="/var/log/pin-sbx-restart.log"
NAME_RE='^openclaw-sbx-(workspace-|browser-workspace-)'
log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$LOG"; }
checked=0 fixed=0
for c in $(docker ps -a --format '{{.Names}}' | grep -E "$NAME_RE"); do
    policy=$(docker inspect "$c" --format '{{.HostConfig.RestartPolicy.Name}}' 2>/dev/null || echo "unknown")
    checked=$((checked + 1))
    if [ "$policy" != "unless-stopped" ]; then
        docker update --restart unless-stopped "$c" >/dev/null 2>&1 && {
            log "FIX: $c $policy -> unless-stopped"
            fixed=$((fixed + 1))
        }
    fi
done
[ "$checked" -gt 0 ] && log "checked=$checked fixed=$fixed"
