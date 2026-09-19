#!/usr/bin/env bash
# ============================================================
# ensure-browser.sh - Chromium recovery for OpenClaw sandbox
# ============================================================
# Restores Chromium from recovery bundle if broken.
# Run via cron: */10 * * * * /usr/local/bin/ensure-browser.sh
#
# Checks:
#   1. Chromium binary exists
#   2. Dynamic libraries OK (ldd)
#   3. Can launch (timeout test)
# ============================================================

set -euo pipefail

GW="openclaw-gateway"
BUNDLE="/usr/local/lib/openclaw-browser/bundle-full.tar.gz"
LOG="/var/log/ensure-browser.log"
CHROMIUM_PATH="/usr/lib/chromium/chromium"

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$LOG"
}

# Check if chromium exists
if ! docker exec "$GW" test -x "$CHROMIUM_PATH" 2>/dev/null; then
    log "WARN: Chromium not found, restoring from bundle"
    if [ -f "$BUNDLE" ]; then
        docker exec "$GW" tar xzf "$BUNDLE" -C / 2>/dev/null
        if docker exec "$GW" test -x "$CHROMIUM_PATH"; then
            log "OK: Chromium restored from bundle"
        else
            log "ERROR: Restore failed"
            exit 1
        fi
    else
        log "ERROR: No recovery bundle at $BUNDLE"
        exit 1
    fi
fi

# Check dynamic libraries
MISSING=$(docker exec "$GW" ldd "$CHROMIUM_PATH" 2>&1 | grep -c "not found" || true)
if [ "$MISSING" -gt 0 ]; then
    log "WARN: $MISSING missing libraries, restoring bundle"
    if [ -f "$BUNDLE" ]; then
        docker exec "$GW" tar xzf "$BUNDLE" -C / 2>/dev/null
        MISSING2=$(docker exec "$GW" ldd "$CHROMIUM_PATH" 2>&1 | grep -c "not found" || true)
        if [ "$MISSING2" -gt 0 ]; then
            log "ERROR: Still $MISSING2 missing after restore"
            exit 1
        fi
        log "OK: Libraries restored"
    fi
fi

# Quick launch test
if docker exec "$GW" timeout 5 "$CHROMIUM_PATH" --headless --no-sandbox --dump-dom about:blank >/dev/null 2>&1; then
    log "OK: Chromium launch test passed"
else
    log "WARN: Launch test failed, attempting restore"
    if [ -f "$BUNDLE" ]; then
        docker exec "$GW" tar xzf "$BUNDLE" -C / 2>/dev/null
        log "OK: Bundle restored after failed launch"
    fi
fi
