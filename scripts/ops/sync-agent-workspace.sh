#!/usr/bin/env bash
# sync-agent-workspace.sh — 把主工作区的 agent 文档同步进各沙箱的 bind 挂载点
#
# 背景：沙箱容器按 configHash 重建时，工作区文档（AGENTS.md 等）可能未随之刷新。
# 本脚本遍历 /data/state/sandboxes/ 下所有 agent 沙箱，把主工作区的核心文档幂等同步过去。
# 与 ensure-sandbox-paths.sh 互补：后者修 bind 源路径，本脚本刷内容。
set -uo pipefail

SRC_WS="/data/state/workspace"
SANDBOX_ROOT="/data/state/sandboxes"

# 需要保持同步的核心文档（不存在的自动跳过，不报错）
DOCS="AGENTS.md SOUL.md IDENTITY.md USER.md SELF.md"

[ -d "$SANDBOX_ROOT" ] || { echo "[sync-agent-workspace] 无沙箱目录，跳过"; exit 0; }

changed=0
for sbx in "$SANDBOX_ROOT"/*/; do
  [ -d "$sbx" ] || continue
  name=$(basename "$sbx")
  # 跳过备份/临时目录
  case "$name" in *-bak-*|*-bak|*.bak|*tmp*) continue ;; esac

  for d in $DOCS; do
    [ -f "$SRC_WS/$d" ] || continue
    dst="$sbx$d"
    # 内容一致则跳过（幂等）
    if [ -f "$dst" ] && cmp -s "$SRC_WS/$d" "$dst"; then
      continue
    fi
    cp -f "$SRC_WS/$d" "$dst" 2>/dev/null && changed=$((changed + 1))
  done
done

# 同时确保工作区属主正确（uid 1000 = 容器内 node/sandbox）
chown -R 1000:1000 "$SRC_WS" 2>/dev/null || true

if [ "$changed" -gt 0 ]; then
  echo "[sync-agent-workspace] 已同步 $changed 个文件到沙箱"
else
  echo "[sync-agent-workspace] 无需变更（全部一致）"
fi
exit 0
