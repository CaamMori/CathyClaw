#!/usr/bin/env bash
set -euo pipefail
# cakeclaw 备份脚本 — 备份 state / 策略文件（不含明文 token）
# 用法: sudo bash backup.sh

TS=$(date -u +%Y%m%dT%H%M%SZ)
OUT="/data/backups/openclaw-state/${TS}"
RETENTION="${BACKUP_RETENTION_DAYS:-7}"
mkdir -p "${OUT}"

echo "[$(date '+%H:%M:%S')] cakeclaw backup starting..."

# 核心：备份 state。tar 失败必须显式失败（而非静默 skip），否则调用方（update.sh/install.sh）
# 会误以为备份成功，导致更新/部署在无备份保护的前提下继续。
if [ -d /data/state ]; then
  if ! tar -czf "${OUT}/state.tar.gz" -C /data/state . 2>/tmp/backup-tar.err; then
    echo "[$(date '+%H:%M:%S')] ERROR: state 备份失败，详情:" >&2
    cat /tmp/backup-tar.err >&2 || true
    rm -f /tmp/backup-tar.err
    exit 1
  fi
  rm -f /tmp/backup-tar.err
  echo "[$(date '+%H:%M:%S')] state 备份完成 (${OUT}/state.tar.gz)"
else
  echo "[$(date '+%H:%M:%S')] WARNING: /data/state 不存在，跳过 state 备份" >&2
fi

# 策略文件为非致命项：缺失只告警，不阻断备份主流程。
for f in /data/workspace/SOUL.md /data/workspace/AGENTS.md; do
  if [ -f "$f" ]; then
    cp -a "$f" "${OUT}/" 2>/dev/null && echo "[$(date '+%H:%M:%S')] 已备份 $(basename "$f")" || \
      echo "[$(date '+%H:%M:%S')] WARNING: 复制 $(basename "$f") 失败" >&2
  else
    echo "[$(date '+%H:%M:%S')] WARNING: $(basename "$f") 不存在，跳过" >&2
  fi
done

find /data/backups/openclaw-state -maxdepth 1 -type d -name '20*' -mtime "+${RETENTION}" -exec rm -rf {} \; 2>/dev/null || true

echo "[$(date '+%H:%M:%S')] done → ${OUT}"
