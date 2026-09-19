#!/usr/bin/env bash
# te_notify.sh — 任务状态变化时，经 openclaw 向 Telegram 推送简洁进度
#
# 设计：只推进度/结果/产物，绝不推过程日志。
# 用法：
#   te_notify.sh <id>                    # 推该任务当前状态
#   te_notify.sh <id> --artifact /path   # 附带产物路径
#
# 依赖：taskboard.py（生成简洁文本）+ openclaw message send（发送）
set -u

TE_CANDIDATES="/data/state/workspace/task-engine /home/node/.openclaw/workspace/task-engine"
TE_DIR=""
for d in $TE_CANDIDATES; do
  if [ -f "$d/taskboard.py" ]; then TE_DIR="$d"; break; fi
done
[ -z "$TE_DIR" ] && { echo "找不到 task-engine 目录" >&2; exit 1; }
export TASK_ENGINE_HOME="${TASK_ENGINE_HOME:-$TE_DIR}"
TARGET="${TE_ALERT_TARGET:-}"
GW="openclaw-gateway"

id="${1:-}"
[ -z "$id" ] && { echo "usage: te_notify.sh <id> [--artifact PATH]" >&2; exit 64; }
shift
artifacts=()
while [ $# -gt 0 ]; do
  case "$1" in
    --artifact) artifacts+=("$2"); shift 2 ;;
    *) shift ;;
  esac
done

cd "$TE_DIR"
msg=$(python3 taskboard.py --telegram "$id" 2>/dev/null) || exit 1
[ -z "$msg" ] && exit 0

if [ ${#artifacts[@]} -gt 0 ]; then
  msg="$msg
📦 產物:"
  for a in "${artifacts[@]}"; do msg="$msg
  - $a"; done
fi

# 经容器内 gateway 发送（走 mihomo 代理）
docker exec "$GW" openclaw message send --channel telegram --target "$TARGET" -m "$msg" >/dev/null 2>&1 || {
  echo "推送失败（gateway 可能不在线）" >&2
  exit 1
}
echo "已推送: $msg"
