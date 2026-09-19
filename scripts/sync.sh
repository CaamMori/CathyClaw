#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# cakeclaw sync — 跨节点备份同步
# 用法: bash sync.sh <user@host:/path>
# cron: 0 2 * * * /data/scripts/sync.sh backup@192.168.1.2:/data/backups
# ============================================================

TARGET="${1:-}"
SRC="/data/backups/openclaw-state"
LOG="/data/logs/sync.log"

[ -n "${TARGET}" ] || { echo "用法: sync.sh user@host:/remote/path"; echo "例如: sync.sh backup@192.168.1.2:/data/backups"; exit 1; }

TS=$(date -u +%Y%m%d)

echo "[$(date '+%Y-%m-%d %H:%M:%S')] syncing ${SRC} → ${TARGET}"

# rsync 过去，只增量。set -o pipefail 已开。
# 不用 `|| true` 吞错误，否则 RSYNC_EXIT 恒为 0，失败告警永远不触发。
RSYNC_EXIT=0
rsync -avz --delete -e "ssh -o ConnectTimeout=10" \
  "${SRC}/" "${TARGET}/cakeclaw-${TS}/" >> "${LOG}" 2>&1 || RSYNC_EXIT=$?

if [ "${RSYNC_EXIT}" -eq 0 ]; then
  echo "[$(date '+%H:%M:%S')] sync ok"

  # 保留元数据
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) ${TARGET}" > /data/logs/sync-target

  # 远程清理 30 天外的
  ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 "${TARGET%%:*}" \
    "find ${TARGET#*:}/cakeclaw-* -maxdepth 0 -type d -mtime +30 -exec rm -rf {} \; 2>/dev/null || true" 2>/dev/null || true
else
  echo "[$(date '+%H:%M:%S')] sync FAILED"

  # 告警
  [ -x /data/scripts/alert.sh ] && bash /data/scripts/alert.sh "HIGH" "Backup sync to ${TARGET} failed" 2>/dev/null || true
  exit 1
fi
