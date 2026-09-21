#!/usr/bin/env bash
# ensure-sandbox-paths.sh — 修复沙箱 bind mount 源路径
#
# 背景（2026-09-12 排查）：
#   gateway 容器内把数据根挂在 /home/node/.openclaw（宿主 /data/state）。
#   openclaw 创建沙箱容器时，用「容器内视角」的路径
#     /home/node/.openclaw/sandboxes/<agent-key>
#   作为 bind mount 的 Source 交给 docker daemon。
#   但 docker daemon 在宿主机解析该路径，于是指向了宿主机上另一个（近乎空的）同名目录，
#   导致沙箱内看不到 AGENTS.md / HEARTBEAT.md 等文件：
#     Sandbox FS error (ENOENT): /home/node/.openclaw/sandboxes/<key>/HEARTBEAT.md
#
# 修复：把宿主机的 /home/node/.openclaw/sandboxes/<key> 变成指向真实数据目录的符号链接。
#   真实数据目录 = /data/state/sandboxes/<key>（= 容器内 /home/node/.openclaw/sandboxes/<key>）
#
# 本脚本幂等，可在服务启动时或容器重建后重复执行。
set -uo pipefail

HOST_SANDBOXES=/home/node/.openclaw/sandboxes
REAL_ROOT=/data/state/sandboxes
changed=0

mkdir -p "$HOST_SANDBOXES" "$REAL_ROOT"

# 排除备份/临时目录
is_ignored() {
  case "$1" in
    *-bak-*|*-bak|*.bak|*emptydir*|*tmp*) return 0 ;;
  esac
  return 1
}

# 对每个真实目录，确保宿主机同名路径是指向它的符号链接
for real in "$REAL_ROOT"/*/; do
  [ -d "$real" ] || continue
  name=$(basename "$real")
  is_ignored "$name" && continue
  link="$HOST_SANDBOXES/$name"

  if [ -L "$link" ]; then
    # 已是链接，检查指向是否正确
    target=$(readlink -f "$link" 2>/dev/null || true)
    want=$(readlink -f "$real" 2>/dev/null || true)
    if [ "$target" = "$want" ]; then
      continue
    fi
    rm -f "$link"
  elif [ -d "$link" ]; then
    # 是真实目录：把里面独有的内容先搬到真实目录，避免丢数据
    if [ -n "$(ls -A "$link" 2>/dev/null)" ]; then
      cp -an "$link"/. "$real"/ 2>/dev/null || true
      echo "[sandbox-paths] 已合并 $link 的内容到 $real"
    fi
    rm -rf "$link"
  fi

  ln -sfn "$real" "$link"
  echo "[sandbox-paths] 已链接 $link -> $real"
  changed=1
done

# 反向：真实目录缺失但宿主机有同名真实目录（历史遗留），搬过去
for d in "$HOST_SANDBOXES"/*/; do
  [ -d "$d" ] || continue
  [ -L "${d%/}" ] && continue
  name=$(basename "$d")
  is_ignored "$name" && continue
  real="$REAL_ROOT/$name"
  if [ ! -e "$real" ]; then
    mkdir -p "$real"
    cp -an "$d"/. "$real"/ 2>/dev/null || true
    rm -rf "$d"
    ln -sfn "$real" "$HOST_SANDBOXES/$name"
    echo "[sandbox-paths] 迁移并链接 $name"
    changed=1
  fi
done

# OpenClaw 2026.9+ 会为受保护的内置 Skill 生成独立 workspace:
#   容器内 /home/node/.openclaw/sandbox/skills-workspaces/<workspace-id>
#   宿主真实 /data/state/sandbox/skills-workspaces/<workspace-id>
# 与上面的 sandboxes/ 同理,Gateway 通过宿主 Docker socket 创建子容器时,
# bind source 必须在宿主视角可解析。缺少该映射会让 control-ui 等 Skill 目录为空。
HOST_SKILL_WORKSPACES=/home/node/.openclaw/sandbox/skills-workspaces
REAL_SKILL_WORKSPACES=/data/state/sandbox/skills-workspaces
mkdir -p "$HOST_SKILL_WORKSPACES" "$REAL_SKILL_WORKSPACES"

for real in "$REAL_SKILL_WORKSPACES"/*/; do
  [ -d "$real" ] || continue
  name=$(basename "$real")
  is_ignored "$name" && continue
  link="$HOST_SKILL_WORKSPACES/$name"

  if [ -L "$link" ]; then
    target=$(readlink -f "$link" 2>/dev/null || true)
    want=$(readlink -f "$real" 2>/dev/null || true)
    [ "$target" = "$want" ] && continue
    rm -f "$link"
  elif [ -d "$link" ]; then
    if [ -n "$(ls -A "$link" 2>/dev/null)" ]; then
      cp -an "$link"/. "$real"/ 2>/dev/null || true
      echo "[sandbox-paths] 已合并 protected Skill 目录 $link 到 $real"
    fi
    rm -rf "$link"
  fi

  ln -sfn "$real" "$link"
  echo "[sandbox-paths] 已链接 protected Skill 目录 $link -> $real"
  changed=1
done

# 兼容真实目录尚不存在、数据只落在错误宿主路径的历史情况。
for d in "$HOST_SKILL_WORKSPACES"/*/; do
  [ -d "$d" ] || continue
  [ -L "${d%/}" ] && continue
  name=$(basename "$d")
  is_ignored "$name" && continue
  real="$REAL_SKILL_WORKSPACES/$name"
  if [ ! -e "$real" ]; then
    mkdir -p "$real"
    cp -an "$d"/. "$real"/ 2>/dev/null || true
    rm -rf "$d"
    ln -sfn "$real" "$HOST_SKILL_WORKSPACES/$name"
    echo "[sandbox-paths] 已迁移并链接 protected Skill workspace $name"
    changed=1
  fi
done

# protected Skill workspace 由 Gateway(uid 1000)维护。Docker 曾以 root 自动创建
# 中间目录,导致 Gateway 无法更新 .openclaw-sync.json。只修正该生成目录的数字属主。
if find "$REAL_SKILL_WORKSPACES" -xdev \( ! -uid 1000 -o ! -gid 1000 \) -print -quit 2>/dev/null | grep -q .; then
  chown -R 1000:1000 "$REAL_SKILL_WORKSPACES"
  echo "[sandbox-paths] 已修正 protected Skill workspace 属主为 1000:1000"
  changed=1
fi

if [ "$changed" = "0" ]; then
  echo "[sandbox-paths] 无需变更（全部正确）"
else
  echo "[sandbox-paths] 已修复；沙箱容器需重建后生效："
  echo "  docker exec openclaw-gateway openclaw sandbox recreate --all --force"
fi
exit 0
