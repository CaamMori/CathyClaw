#!/usr/bin/env bash
# ============================================================
# entrypoint.sh - Gateway entrypoint with lock cleanup
# ============================================================
# Run BEFORE openclaw starts. Cleans stale locks left by
# previous crashes or force-kills.
#
# Mount into gateway container and set as entrypoint override,
# or run as part of your init process.
# ============================================================

set -euo pipefail

WS="/data/state/workspace"
STATE="/data/state"

echo "[entrypoint] Cleaning stale locks..."

# Remove zero-byte lock files older than 30 minutes
# Only deletes 0-byte files (active locks have data)
if [ -d "$WS" ]; then
    find "$WS" -maxdepth 2 \( -name "*lock.sqlite" -o -name "*.lock" \) -size 0 -mmin +30 -print -delete 2>/dev/null || true
fi

# Also clean state-level locks
if [ -d "$STATE" ]; then
    find "$STATE" -maxdepth 2 \( -name "*lock.sqlite" -o -name "*.lock" \) -size 0 -mmin +30 -print -delete 2>/dev/null || true
fi

echo "[entrypoint] Lock cleanup done."

# Start the gateway
exec openclaw gateway start
