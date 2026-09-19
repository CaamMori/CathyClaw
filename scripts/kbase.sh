#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# cakeclaw kbase — 知识库初始化与维护框架
# 用法: bash kbase.sh [init|check]
#   init  - 初始化所有知识库文件（首次部署）
#   check - 检查文件状态（每日 cron），不做主观评估
# ============================================================

KB="/data/knowledge"
CMD="${1:-check}"

init() {
  mkdir -p "${KB}"/{runbooks,playbooks,templates,changelog,architecture}

  cat > "${KB}/environment.md" << EOF
# 环境信息

- **OS**: $(. /etc/os-release && echo "$PRETTY_NAME" 2>/dev/null || uname -sr)
- **CPU**: $(nproc) 核
- **RAM**: $(free -h | awk '/Mem:/{print $2}')
- **Disk**: $(df -h / | awk 'NR==2{print $4}')
- **Docker**: $(docker --version 2>/dev/null | cut -d' ' -f3 | cut -d, -f1 || echo N/A)
- **Deployed**: $(date -u +%Y-%m-%dT%H:%M:%SZ)
EOF

  touch "${KB}/decisions.md"
  touch "${KB}/incidents.md"
  touch "${KB}/projects.md"

  echo "[$(date '+%H:%M:%S')] kbase initialized"
}

check() {
  local issues=0

  # 检查文件是否存在
  for f in environment.md decisions.md incidents.md projects.md; do
    if [ ! -f "${KB}/${f}" ]; then
      echo "[$(date '+%H:%M')] missing: ${KB}/${f}"
      issues=$((issues + 1))
    fi
  done

  # 实际环境检测（不依赖 projects.md 里硬编码的"完成"）
  GW_STATUS=$(docker ps --filter name=cakeclaw-gateway --format '{{.Status}}' 2>/dev/null | head -1 || echo "not-found")
  DISK_PCT=$(df -P / | awk 'NR==2{gsub("%","",$5); print $5}')
  MEM_FREE=$(free -g | awk '/Mem:/{print $7}')
  LOAD=$(awk '{print $1}' /proc/loadavg 2>/dev/null || echo 0)

  echo "[$(date '+%H:%M')] gw=${GW_STATUS%%(*} disk=${DISK_PCT}% mem=${MEM_FREE}G load=${LOAD}"

  if [ "${issues}" -eq 0 ]; then
    echo "[$(date '+%H:%M')] kbase files ok (4/4)"
  else
    echo "[$(date '+%H:%M')] kbase files: ${issues} issues"
  fi
  return 0
}

case "${CMD}" in
  init)  init ;;
  check) check ;;
  *)     echo "用法: kbase.sh [init|check]"; exit 1 ;;
esac
