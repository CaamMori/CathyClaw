#!/usr/bin/env bash
# ocwatch — OpenClaw 主动健康监控守护
# 循环检测：gateway 健康 / mihomo 代理可用性 / 浏览器状态 / 磁盘水位 / 内存水位
# 自动恢复:浏览器配置/依赖异常时修复;Mihomo 静默死亡(连续失败)时重启
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
BR_MAXFAIL=3                           # 浏览器连续拉起失败告警阈值
GW_MAXFAIL=3                           # 网关健康检查连续失败阈值：单发超时(CPU尖峰)不误报
DISK_WARN=85                         # 磁盘使用率告警阈值 %
DISK_CRIT=92                         # 磁盘危险阈值 %
MEM_WARN=90                          # 内存使用率告警阈值 %
# 告警目标 Telegram chat id（留空则仅日志不自检推送）。可在 /etc/ocwatch.conf 覆盖。
ALERT_TARGET="${OCWATCH_ALERT_TARGET:-${TARGET_CHAT_ID:-YOUR_TELEGRAM_CHAT_ID}}"

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
  # 2026.9.4 按需启停语义：gateway 自有 chromium 空闲时 status.running=false 是正常态
  # （enabled 才是服务位，selfcheck browser_running 已同语义）。
  # 旧判据查 running 会把空闲态当 down，且"start 后复验 running"永远失败 → 每 3 轮告警刷屏。
  # 只认 enabled：false=服务位被关（真异常需人工）；true=ok（running 与否都是按需正常态）。
  local st
  st=$(timeout 15 docker exec "$GW" openclaw browser status --json 2>/dev/null)
  if echo "$st" | grep -q '"enabled":\s*false'; then
    echo down
  elif echo "$st" | grep -q '"enabled":\s*true'; then
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

# mihomo 恢复：mihomo-tun 已纳入 docker compose 管理（/data/scripts/docker-compose.gateway.yml）。
# 它的 network_mode 为 service:openclaw-gateway，gateway 被 compose 重建后由 compose 自动跟随，
# 因此这里只需 compose up --force-recreate / restart，绝不能再 docker rm -f + docker run 造野容器——
# 否则会丢掉 compose 标签、与 compose 状态漂移，正是此前清理掉的「野容器」技术债。
COMPOSE_FILE=/data/scripts/docker-compose.gateway.yml

recreate_mihomo() {
  if docker compose -f "$COMPOSE_FILE" up -d --force-recreate "$MH" >/dev/null 2>&1; then
    return 0
  fi
  docker compose -f "$COMPOSE_FILE" restart "$MH" >/dev/null 2>&1
}

# 先试重启；失败则走 compose 重建（gateway 可能被 compose recreate，netns 引用需刷新）。
bounce_mihomo() {
  if docker restart "$MH" >/dev/null 2>&1; then
    return 0
  fi
  log "mihomo restart 失败（gateway 可能被重建，容器 ID 已变）→ 重建 $MH"
  recreate_mihomo
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
gw_fails=0
br_fails=0
while true; do
  # gateway 健康检查：单次超时(BAD)可能因 CPU 尖峰导致 RPC 超时，属瞬时抖动。
  # 累计连续失败达到 GW_MAXFAIL 才判定为真正异常并告警；否则压制为 ok，避免误报。
  if [ "$(check_gateway)" = "BAD" ]; then
    gw_fails=$((gw_fails + 1))
  else
    gw_fails=0
  fi
  if [ "$gw_fails" -ge "$GW_MAXFAIL" ]; then
    gw=BAD
  else
    gw=ok
  fi
  mh=$(check_mihomo)
  br=$(check_browser)
  dk=$(check_disk)
  mem=$(check_mem)

  # 沙箱挂载路径自愈（幂等，无变更时静默）
  check_sandbox_paths

  # Gateway 容器变化后仅执行一次无模型 sandbox 预热;平时由 gateway-id 状态快速跳过。
  /usr/local/bin/prewarm-openclaw-sandboxes.sh >/dev/null 2>&1 || true

  # gateway 重启后 mihomo netns 需刷新（compose 会自动跟随，这里兜底检测并重建）
  if [ "$(netns_stale)" = "yes" ]; then
    if [ "$mh" != "ok" ] || [ "$gw" = "ok" ]; then
      alert "检测到 gateway 已重启，mihomo netns 需重绑 → Compose 强制重建 mihomo-tun"
      # docker restart 不会更新 NetworkMode=container:<old-id>,必须重建绑定新 netns。
      if ! recreate_mihomo; then
        alert "mihomo 重绑失败，将在下一轮重试"
      fi
      mh_fails=0
      mh=ok   # 乐观置位，下一轮实测确认
    fi
  fi

  # 浏览器服务位被禁用时修复依赖并告警;空闲 stopped 属按需正常态,不主动拉起。
  # 连续 BR_MAXFAIL 轮仍异常才告警
  if [ "$br" = "down" ]; then
    # enabled=false 是配置面问题，browser start 救不了；且按需启停语义下空闲态
    # start 会被 daemon 回收，旧"拉起+复验 running"永远失败（告警风暴根源，见 check_browser 注释）。
    # 仍跑 ensure-browser.sh 保证二进制/依赖在位（幂等，可用时秒级返回）。
    /usr/local/bin/ensure-browser.sh || true
    br_fails=$((br_fails + 1))
    if [ "$br_fails" -ge "$BR_MAXFAIL" ]; then
      alert "openclaw browser 服务位 enabled=false（配置面被关），需要人工检查"
      br_fails=0
    fi
  elif [ "$br" = "ok" ]; then
    br_fails=0
  fi

  # mihomo 不可用:先按 Telegram API 实测切换节点,只有切换仍失败才重启容器。
  if [ "$mh" = "BAD" ]; then
    mh_fails=$((mh_fails + 1))
    if [ "$mh_fails" -ge "$MH_MAXFAIL" ]; then
      alert "mihomo 代理连续 ${mh_fails} 次不可用,先尝试切换稳定节点"
      recovered=0
      if /usr/local/bin/mihomo-autoswitch.sh >/dev/null 2>&1; then
        sleep 3
        if [ "$(check_mihomo)" = "ok" ]; then
          recovered=1
          log "mihomo 节点切换后复验通过"
        fi
      fi
      if [ "$recovered" -eq 0 ]; then
        alert "mihomo 节点切换未恢复,尝试重启代理容器"
        if bounce_mihomo; then
          sleep 3
          if [ "$(check_mihomo)" = "ok" ]; then
            recovered=1
            log "mihomo 重启后复验通过"
          fi
        fi
      fi
      if [ "$recovered" -eq 1 ]; then
        alert "mihomo 代理已恢复"
      else
        alert "mihomo 恢复失败,将在下一轮重试"
      fi
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
