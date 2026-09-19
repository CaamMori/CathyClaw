#!/usr/bin/env bash
# ocwatch — OpenClaw 主动健康监控守护
# 循环检测：gateway 健康 / mihomo 代理可用性 / 浏览器状态 / 磁盘水位 / 内存水位
# 自动恢复：浏览器 down -> start；mihomo 静默死亡(连续失败) -> restart
# 告警：状态切换时经 openclaw Telegram 推送（在线时）；始终写状态文件 + journal
# 设计为幂等、非破坏性；gateway 自身不自动重启（交给 recovery-watchdog）。
set -u

GW=openclaw-gateway
MH=mihomo-tun
LOG=/var/log/ocwatch.log
STATE=/var/run/ocwatch.state
HIST=/var/run/ocwatch.prev          # 上一轮状态（供切换检测）
INTERVAL=60
MH_MAXFAIL=3
DISK_WARN=85                         # 磁盘使用率告警阈值 %
DISK_CRIT=92                         # 磁盘危险阈值 %
MEM_WARN=90                          # 内存使用率告警阈值 %
# 告警目标 Telegram chat id（留空则仅日志推送）。可在 /etc/ocwatch.conf 覆盖。
# 注意：上游生产机曾把具体 chat id 硬编码在这里，移植时改为空默认值——
# 具体 ID 属于个人信息，不能进入公开仓库，应由部署方在 /etc/ocwatch.conf 提供。
ALERT_TARGET="${OCWATCH_ALERT_TARGET:-}"

if [ -f /etc/ocwatch.conf ]; then
  # shellcheck disable=SC1091
  . /etc/ocwatch.conf
fi

ts()  { date '+%Y-%m-%d %H:%M:%S'; }
log() { echo "$(ts) $*" | tee -a "$LOG"; }

# 仅在 openclaw 在线时经 Telegram 推送；离线则仅日志
alert() {
  if [ -n "$ALERT_TARGET" ] && docker ps -f "name=^${GW}$" --format '{{.Names}}' | grep -q "$GW"; then
    timeout 25 docker exec "$GW" openclaw message send --channel telegram --target "$ALERT_TARGET" -m "[ocwatch] $*" >/dev/null 2>&1 || true
  fi
  log "ALERT: $*"
}

# 读取上一轮状态用于「切换才告警」
prev() { awk -F= -v k="$1" '$1==k{print $2}' "$HIST" 2>/dev/null; }

check_gateway() {
  if ! docker ps -f "name=^${GW}$" --format '{{.Names}}' | grep -q "$GW"; then
    echo BAD
    return
  fi
  if timeout 20 docker exec "$GW" openclaw health >/dev/null 2>&1; then echo ok; else echo BAD; fi
}

check_mihomo() {
  # 经 mihomo mixed 端口实测代理可用性（在 gateway netns 内，10808 才可达）
  if timeout 15 docker exec "$GW" curl -s -x http://127.0.0.1:10808 --max-time 8 https://api.telegram.org/ -o /dev/null 2>/dev/null; then
    echo ok
  else
    echo BAD
  fi
}

check_browser() {
  local st
  st=$(timeout 15 docker exec "$GW" openclaw browser status --json 2>/dev/null)
  if echo "$st" | grep -q '"running":\s*false'; then
    echo down
  elif echo "$st" | grep -q '"running":\s*true'; then
    echo ok
  else
    echo unknown
  fi
}

# 磁盘根分区使用率 -> ok / warn / crit
check_disk() {
  local p
  p=$(df / | awk 'NR==2{gsub("%","",$5); print $5}')
  if [ -z "$p" ]; then echo unknown; return; fi
  if [ "$p" -ge "$DISK_CRIT" ]; then echo "crit:$p"
  elif [ "$p" -ge "$DISK_WARN" ]; then echo "warn:$p"
  else echo "ok:$p"
  fi
}

# 内存使用率 -> ok / warn
check_mem() {
  local p
  p=$(free | awk '/^Mem:/{printf "%d", ($3/$2)*100}')
  if [ -z "$p" ]; then echo unknown; return; fi
  if [ "$p" -ge "$MEM_WARN" ]; then echo "warn:$p"
  else echo "ok:$p"
  fi
}

# 关键：mihomo-tun 用 network_mode=container:<gateway> 共享 netns。
# gateway 一旦重启，mihomo 的 netns 引用即失效 → 代理静默死亡。
# 检测：mihomo 容器 StartedAt 早于 gateway StartedAt，即说明需要重绑。
# 沙箱 bind mount 源路径自愈：
# gateway 用容器内视角路径做 Source，docker 在宿主机解析会指向错误目录，
# 导致沙箱内 AGENTS.md/HEARTBEAT.md 等 ENOENT。ensure-sandbox-paths.sh 幂等修复。
check_sandbox_paths() {
  local out
  out=$(/usr/local/bin/ensure-sandbox-paths.sh 2>&1) || return 0
  case "$out" in
    *"无需变更"*) return 0 ;;
    *) alert "沙箱路径异常，已修复: $(echo "$out" | head -2 | tr '\n' ' ')" ;;
  esac
}

netns_stale() {
  local gw_start mh_start
  gw_start=$(docker inspect -f '{{.State.StartedAt}}' "$GW" 2>/dev/null)
  mh_start=$(docker inspect -f '{{.State.StartedAt}}' "$MH" 2>/dev/null)
  [ -z "$gw_start" ] || [ -z "$mh_start" ] && { echo no; return; }
  # ISO8601 字符串可直接字典序比较（同时区）
  if [ "$mh_start" \< "$gw_start" ]; then echo yes; else echo no; fi
}

mh_fails=0
while true; do
  gw=$(check_gateway)
  mh=$(check_mihomo)
  br=$(check_browser)
  dk=$(check_disk)
  mem=$(check_mem)

  # 沙箱挂载路径自愈（幂等，无变更时静默）
  check_sandbox_paths

  # gateway 重启后 mihomo netns 失效 -> 立即重绑（重置失败计数，避免误判为普通抖动）
  if [ "$(netns_stale)" = "yes" ]; then
    if [ "$mh" != "ok" ] || [ "$gw" = "ok" ]; then
      alert "检测到 gateway 已重启，mihomo netns 需重绑 → 重启 mihomo-tun"
      docker restart "$MH" >/dev/null 2>&1 || true
      mh_fails=0
      mh=ok   # 乐观置位，下一轮实测确认
    fi
  fi

  # 浏览器 down -> 拉起（不计入告警刷屏，拉起即恢复）
  if [ "$br" = "down" ]; then
    alert "浏览器未运行，尝试拉起"
    docker exec "$GW" openclaw browser start >/dev/null 2>&1 || true
    br=starting
  fi

  # mihomo 静默死亡 -> 连续失败达到阈值则重启
  if [ "$mh" = "BAD" ]; then
    mh_fails=$((mh_fails + 1))
    if [ "$mh_fails" -ge "$MH_MAXFAIL" ]; then
      alert "mihomo 代理连续 ${mh_fails} 次不可用，尝试重启"
      docker restart "$MH" >/dev/null 2>&1 || true
      mh_fails=0
    fi
  else
    mh_fails=0
  fi

  # gateway 异常（切换才告警）
  if [ "$gw" = "BAD" ] && [ "$(prev gw)" != "BAD" ]; then
    alert "openclaw-gateway 健康检查失败（不自动重启，交给 recovery-watchdog）"
  fi

  # 磁盘水位（切换才告警：进入 warn/crit 时推一次）
  case "$dk" in
    crit:*)
      [ "$(prev dk)" != "$dk" ] && alert "磁盘告急：根分区使用 ${dk#crit:}%（阈值 ${DISK_CRIT}%），请清理"
      ;;
    warn:*)
      [ "$(prev dk)" != "$dk" ] && alert "磁盘告警：根分区使用 ${dk#warn:}%（阈值 ${DISK_WARN}%）"
      ;;
  esac

  # 内存水位（切换才告警）
  case "$mem" in
    warn:*)
      [ "$(prev mem)" != "$mem" ] && alert "内存告警：使用 ${mem#warn:}%（阈值 ${MEM_WARN}%）"
      ;;
  esac

  # 写状态：一行可读摘要 + 键值对（供 prev 判切换）
  echo "$(ts) gateway=$gw mihomo=$mh browser=$br disk=$dk mem=$mem" > "$STATE"
  printf 'gw=%s\nmh=%s\nbr=%s\ndk=%s\nmem=%s\n' "$gw" "$mh" "$br" "$dk" "$mem" > "${HIST}.tmp" && mv "${HIST}.tmp" "$HIST"

  sleep "$INTERVAL"
done
