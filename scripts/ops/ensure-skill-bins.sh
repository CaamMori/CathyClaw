#!/bin/sh
# ensure-skill-bins.sh — 自愈 gateway 容器与沙箱镜像中的 skills CLI（tmux/gh/summarize）
# 2026-09-14 v2：gateway 分支加 USTC 源切换（debian 官方源直连会卡死，实测 7min+ 无产出；USTC 秒过）
LOG=/var/log/ensure-skill-bins.log
ts(){ date '+%F %T'; }
if ! docker exec openclaw-gateway sh -c 'command -v tmux >/dev/null && command -v gh >/dev/null && command -v summarize >/dev/null' 2>/dev/null; then
  echo "$(ts) gateway bins missing -> reinstall (USTC mirror)" >> $LOG
  docker exec openclaw-gateway sh -c 'for f in /etc/apt/sources.list.d/debian.sources /etc/apt/sources.list; do [ -f "$f" ] && ! grep -q mirrors.ustc.edu.cn "$f" && sed -i "s|deb.debian.org|mirrors.ustc.edu.cn|g; s|security.debian.org|mirrors.ustc.edu.cn|g" "$f"; done; exit 0' >> $LOG 2>&1
  docker exec openclaw-gateway sh -c 'apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq tmux gh && npm install -g --registry=https://registry.npmmirror.com @steipete/summarize@0.21.14 && echo "$(date "+%F %T") gateway reinstall OK" >> /var/log/ensure-skill-bins.log' >> $LOG 2>&1
fi
SBX=$(docker run --rm --entrypoint /bin/sh openclaw-sandbox:bookworm-slim -c 'command -v tmux >/dev/null && command -v gh >/dev/null && command -v summarize >/dev/null && echo OK || echo MISS' 2>/dev/null)
if [ "$SBX" != "OK" ]; then
  echo "$(ts) sandbox image bins missing -> rebuild" >> $LOG
  sh /usr/local/bin/rebuild-sandbox-skills.sh >> $LOG 2>&1
fi
