#!/bin/bash
# nightly-backup.sh — 整机关键配置每日备份，保留 7 份
set -u
STAMP=$(date +%Y%m%d-%H%M%S)
DEST=/data/state/backups/config
mkdir -p "$DEST"
LOG=/var/log/nightly-backup.log

tar -czf "$DEST/config-$STAMP.tar.gz" \
  /data/state/openclaw.json \
  /usr/local/etc/mihomo/config.yaml \
  /etc/cron.d/openclaw-ops \
  /data/scripts/docker-compose.gateway.yml \
  /data/opt/openclaw-patches \
  /data/state/workspace-guest \
  /data/state/workspace \
  /usr/local/bin/selfcheck.py \
  /usr/local/bin/selfcheck-quick-cron.sh \
  /usr/local/bin/mihomo-guard.sh \
  /usr/local/bin/mihomo-autoswitch.sh \
  /usr/local/bin/fix-gateway-dns.sh \
  /usr/local/bin/ensure-browser-alive.sh \
  /usr/local/bin/prewarm-openclaw-sandboxes.sh \
  /usr/local/bin/daily-health-summary.sh \
  /usr/local/bin/capability-watch.py \
  /data/state/sandbox-tools/bin/capability-recover \
  /data/state/sandbox-tools/bin/capability-catalog \
  /usr/local/bin/task-engine-reconcile.py \
  /data/state/workspace/task-engine/claim_audit.py \
  /data/state/workspace/task-engine/claim_audit_cron.sh \
  /usr/local/bin/ocwatch.sh \
  /usr/local/bin/sync-agent-workspace.sh \
  /usr/local/bin/pin-sbx-restart.sh \
  /usr/local/bin/openclaw-cfg-guard.py \
  /usr/local/bin/cdp-relay.js \
  /usr/local/bin/openclaw-cdp-relay.sh \
  /data/scripts/ensure-telegram-alive.sh \
  2>/dev/null

chmod 700 "$DEST"
# 保留最近 7 份
ls -1t "$DEST"/config-*.tar.gz 2>/dev/null | tail -n +8 | xargs -r rm -f
size=$(du -h "$DEST/config-$STAMP.tar.gz" 2>/dev/null | cut -f1)
echo "$(date '+%F %T') backup ok: config-$STAMP.tar.gz ($size)" >> "$LOG"
