#!/usr/bin/env bash
# OpenClaw gateway 启动包装器
# 作用：容器每次启动时先清理孤儿锁 + 幂等注入工具调用预算补丁，再按原始命令启动。
# 原始入口：tini -s -- node openclaw.mjs gateway
set -uo pipefail

# --- 1) 孤儿索引锁清理（必须最先做：此刻容器内还没有 openclaw 进程）---
# /home/node/.openclaw 是宿主机 /data/state 的 bind mount，锁文件会跨重启残留。
# 若上次重建途中容器被强杀，残留的 0 字节锁会让索引永久停止更新，且不报错。
LOCKCLEAN="/data/opt/openclaw-patches/lock-cleanup.sh"
if [ -x "$LOCKCLEAN" ]; then
  "$LOCKCLEAN" || echo "[entrypoint] 孤儿锁清理异常，按原样继续启动"
else
  echo "[entrypoint] 未找到孤儿锁清理脚本，跳过: $LOCKCLEAN"
fi

# --- 2) 工具调用预算补丁（幂等）---
PATCH="/data/opt/openclaw-patches/apply-maxtoolcalls-patch.sh"
if [ -x "$PATCH" ]; then
  "$PATCH" || echo "[entrypoint] 补丁注入失败，按原样继续启动"
else
  echo "[entrypoint] 未找到补丁脚本，跳过: $PATCH"
fi

exec tini -s -- node openclaw.mjs gateway
