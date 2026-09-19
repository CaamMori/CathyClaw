#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# cakeclaw changelog — 系统变更记录
# 用法: bash changelog.sh "描述" [category]
# ============================================================

MSG="${1:-}"
CAT="${2:-general}"
CHANGELOG="/data/knowledge/changelog/system.md"
mkdir -p "$(dirname "${CHANGELOG}")"

[ -n "${MSG}" ] || { echo "用法: changelog.sh \"变更描述\" [ufw|docker|nginx|os|general]"; exit 1; }

TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)
ENTRY="- **${TS}** [${CAT}] ${MSG}"

# 如果文件不存在，创建带标题的
if [ ! -f "${CHANGELOG}" ]; then
  echo "# system changelog" > "${CHANGELOG}"
  echo "" >> "${CHANGELOG}"
fi

# 插入到标题后
sed -i "/^# system changelog/a ${ENTRY}" "${CHANGELOG}"
echo "[$(date '+%H:%M:%S')] logged: ${CAT} → ${MSG}"
