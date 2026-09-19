#!/usr/bin/env bash
# selfcheck-quick-cron.sh - Quick health check for cron
# Cron: */10 * * * * /usr/local/bin/selfcheck-quick-cron.sh
# Silent if green, logs failures
set -euo pipefail
LOG="/var/log/selfcheck-quick.log"
log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$LOG"; }
RESULT=$(python3 /usr/local/bin/selfcheck.py --quick --write-state 2>&1) || true
if echo "$RESULT" | grep -q 'X '; then
    FAIL_COUNT=$(echo "$RESULT" | grep -c 'X ' || true)
    log "ALERT: $FAIL_COUNT checks failed"
    log "$RESULT"
fi
