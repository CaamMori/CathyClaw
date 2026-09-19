#!/usr/bin/env bash
# nightly-backup.sh - Daily config backup, keep 7
# Cron: 17 4 * * * /usr/local/bin/nightly-backup.sh
set -euo pipefail
BACKUP_DIR="/data/backups/nightly-$(date +%Y%m%d-%H%M%S)"
KEEP=7
mkdir -p "$BACKUP_DIR"
cp /data/state/openclaw.json "$BACKUP_DIR/" 2>/dev/null || true
cp /data/etc/openclaw/runtime.env "$BACKUP_DIR/" 2>/dev/null || true
cp /data/scripts/docker-compose.gateway.yml "$BACKUP_DIR/" 2>/dev/null || true
cp /data/etc/mihomo/config.yaml "$BACKUP_DIR/" 2>/dev/null || true
if [ -d /data/state/workspace ]; then
    tar czf "$BACKUP_DIR/workspace.tar.gz" -C /data/state workspace             --exclude='*.pyc' --exclude='__pycache__' --exclude='.git' 2>/dev/null || true
fi
# 安全删除：只删目录、只删 nightly- 前缀、保留最近 KEEP 个
find /data/backups -maxdepth 1 -type d -name 'nightly-*' -printf '%T@ %p\0' 2>/dev/null | \
  sort -z -r -n | tail -z -n +$((KEEP+1)) | cut -z -d' ' -f2 | xargs -0 -r rm -rf 2>/dev/null || true
echo "[$(date)] Backup: $BACKUP_DIR"
