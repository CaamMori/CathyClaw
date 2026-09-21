#!/usr/bin/env bash
# pin-sbx-restart.sh
# 将 openclaw 动态创建的沙箱容器（openclaw-sbx-workspace-* / openclaw-sbx-browser-workspace-*）
# 重启策略钉死为 unless-stopped。
# 设计原则：最小、安全、可逆、幂等。
#  - 仅使用 `docker update --restart`（不影响运行中容器，不改动其它配置、不 recreate）。
#  - 仅对名字匹配 openclaw-sbx-(workspace-|browser-workspace-) 的容器生效，不碰其它容器。
#  - 每轮写一行带时间戳的汇总日志到 /var/log/pin-sbx-restart.log。
set -u

LOG="/var/log/pin-sbx-restart.log"
# 2026.9.4 沙箱重构后命名：agent → workspace / browser-workspace（详见 OpenClaw 总览 §A1.1 / §B10.4）
NAME_RE='^openclaw-sbx-(workspace-|browser-workspace-)'
TS="$(date '+%Y-%m-%d %H:%M:%S')"

# 确保日志文件存在
touch "$LOG" 2>/dev/null || true

# 列出匹配的沙箱容器（含已停止的，防止被 recreate 成 stopped 形态后漏钉）
containers="$(docker ps -a --format '{{.Names}}' 2>/dev/null | grep -E "${NAME_RE}" || true)"

if [ -z "$containers" ]; then
  echo "${TS} SUMMARY checked=0 fixed=0 (no openclaw-sbx-* sandbox containers)" >> "$LOG"
  exit 0
fi

total=0
fixed=0
fixed_names=""
for c in $containers; do
  total=$((total + 1))
  rp="$(docker inspect -f '{{.HostConfig.RestartPolicy.Name}}' "$c" 2>/dev/null || echo "unknown")"
  if [ "$rp" != "unless-stopped" ]; then
    if docker update --restart unless-stopped "$c" >/dev/null 2>&1; then
      fixed=$((fixed + 1))
      fixed_names="${fixed_names} ${c}(was:${rp})"
      echo "${TS} FIX  $c restartPolicy '${rp}' -> 'unless-stopped'" >> "$LOG"
    else
      echo "${TS} ERR  failed to docker update $c (rp='${rp}')" >> "$LOG"
    fi
  fi
done

if [ "$fixed" -eq 0 ]; then
  echo "${TS} SUMMARY checked=${total} fixed=0 (all already unless-stopped)" >> "$LOG"
else
  echo "${TS} SUMMARY checked=${total} fixed=${fixed} ->${fixed_names}" >> "$LOG"
fi

exit 0
