#!/usr/bin/env bash
# 启动期自愈：孤儿索引锁清理 + 工作区属主校正
# 幂等，可重复执行。在 gateway 进程起来之前运行（此刻无 openclaw 进程持锁）。
# 挂载点：宿主 /data/opt/openclaw-patches/ -> 容器内 /opt/openclaw-patches/
set -u
ts() { date '+%Y-%m-%d %H:%M:%S'; }

removed=0
fixed=0

# ---------- 1) 孤儿索引锁清理 ----------
# 判据：0 字节 + 无人持有。此刻容器内没有 openclaw 进程，所以凡 0 字节的
# *lock.sqlite / *.lock 都是上次异常退出遗留的孤儿，直接清掉。
# 注意 glob 必须写 *lock.sqlite（真实名是 openclaw-agent.sqlite.reindex-lock.sqlite），
# 绝不能写 *.lock.sqlite —— 少一个字符就永远匹配不到。
for d in /home/node/.openclaw/agents/*/agent; do
  [ -d "$d" ] || continue
  agent=$(basename "$(dirname "$d")")
  locks=$(find "$d" -maxdepth 1 -type f -size 0 \
            \( -name '*lock.sqlite' -o -name '*.lock' \) 2>/dev/null)
  for f in $locks; do
    [ -n "$f" ] || continue
    [ -e "$f" ] || continue
    if [ -s "$f" ]; then
      echo "[$(ts)] [lock-cleanup] 跳过非空锁 ${agent}/$(basename "$f")"
      continue
    fi
    age=$(( $(date +%s) - $(stat -c %Y "$f" 2>/dev/null || echo 0) ))
    rm -f "$f" 2>/dev/null && {
      removed=$((removed+1))
      echo "[$(ts)] [lock-cleanup] 清除孤儿锁 ${agent}/$(basename "$f") (age=${age}s)"
    }
  done
done

# 同时清理 reindex 运行时目录里的残留（部分版本会同时留这个）
for d in /home/node/.openclaw/agents/*/agent; do
  [ -d "$d" ] || continue
  for f in "$d"/.reindex-* "$d"/reindex-*.pid; do
    [ -e "$f" ] || continue
    rm -rf "$f" 2>/dev/null && echo "[$(ts)] [lock-cleanup] 清除残留状态 $(basename "$f")"
  done
done

if [ "$removed" -gt 0 ]; then
  echo "[$(ts)] [lock-cleanup] 本次清理 ${removed} 个孤儿锁（容器重启导致，索引将自动重建）"
else
  echo "[$(ts)] [lock-cleanup] 无孤儿锁"
fi

# ---------- 2) 工作区属主校正 ----------
# 沙箱容器把 /home/node/.openclaw/workspace 挂成自己的 /workspace，
# 进程身份是 uid=1000(node) 且无 capability。
# 凡属主是 root 的文件/目录，沙箱一律 EACCES —— agent 表现为「连写都写不了」。
# 宿主 ls -l 看不出问题（755 人人可读），必须切到 uid 1000 才暴露。
# 这里在启动期统一校正为 1000:1000，只改属主、不动内容与 mode。
WS=/home/node/.openclaw/workspace
if [ -d "$WS" ]; then
  n=$(find "$WS" -not -user 1000 2>/dev/null | wc -l)
  if [ "${n:-0}" -gt 0 ]; then
    find "$WS" -not -user 1000 -printf '%u:%g %M %p\n' 2>/dev/null \
      > "/tmp/wsown-before-$(date +%Y%m%d-%H%M%S).txt" || true
    if [ "$(id -u)" -ne 0 ]; then
      # 非 root（正常情况：容器以 node 运行）改不了别人属主。
      # 此时若发现异主条目，说明是历史遗留或外部以 root 写入，交给 selfcheck 报警。
      echo "[$(ts)] [wsown] 发现 ${n} 个异主条目，但当前非 root($(id -u))，跳过 chown（交由 selfcheck 告警）"
    elif chown -R 1000:1000 "$WS" 2>/dev/null; then
      fixed=$n
      echo "[$(ts)] [wsown] 校正 ${fixed} 个 root 属主条目 -> 1000:1000"
    else
      echo "[$(ts)] [wsown] chown 失败（可能为只读挂载），按原样继续"
    fi
  else
    echo "[$(ts)] [wsown] 属主已一致"
  fi
  # git 安全目录：属主非 root 时 root 跑 git 会报 dubious ownership
  git config --global --add safe.directory '*' 2>/dev/null || true
else
  echo "[$(ts)] [wsown] 未找到工作区 $WS，跳过"
fi

exit 0
