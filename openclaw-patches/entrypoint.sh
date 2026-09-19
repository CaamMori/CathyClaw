#!/usr/bin/env bash
# OpenClaw gateway 启动包装器
# 作用：容器每次启动时依次执行
#   1) 清理孤儿索引锁
#   2) 删除 /dashboard 聊天命令（保留底层 Control UI / browser / control-ui Skill）
#   3) 幂等注入工具调用预算补丁
# 然后按原始命令启动。
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

# --- 2) 删除 /dashboard 聊天命令（幂等 + fail-closed）---
# 为什么是「删除」而不是「打补丁修好」：该入口生成的地址是容器内部地址，
# 对用户的浏览器不可达，因此不具备使用价值；更糟的是它会进入 LLM/工具循环、
# 尝试读不可达的路径并走超时的浏览器控制链，长时间占用同一个 Telegram session，
# 导致后续命令全部排队，表现为「发什么都没回复」。
# 处理方式：删掉菜单注册、隐藏 native 命令、改走确定性 fast path、原执行体替换为
# 固定回复（保留原 body 注释以便升级比对）。底层 Control UI 与 browser 能力保留。
#
# fail-closed 的理由：本脚本依赖上游 dist 的文件名与源码片段。上游一旦升级导致
# 结构不匹配，盲打会留下「以为已禁用、实际仍会进模型循环」的不确定状态。
# 因此宁可拒绝启动，也不带着不确定行为启动。
DASHBOARD_PATCH="/data/opt/openclaw-patches/apply-disable-dashboard-command.sh"
if [ -x "$DASHBOARD_PATCH" ]; then
  "$DASHBOARD_PATCH" || { echo "[entrypoint] /dashboard 删除脚本执行失败，拒绝启动以避免行为漂移"; exit 1; }
else
  echo "[entrypoint] 未找到 /dashboard 删除脚本，拒绝启动: $DASHBOARD_PATCH"
  exit 1
fi

# --- 3) 工具调用预算补丁（幂等）---
PATCH="/data/opt/openclaw-patches/apply-maxtoolcalls-patch.sh"
if [ -x "$PATCH" ]; then
  "$PATCH" || echo "[entrypoint] 补丁注入失败，按原样继续启动"
else
  echo "[entrypoint] 未找到补丁脚本，跳过: $PATCH"
fi

exec tini -s -- node openclaw.mjs gateway
