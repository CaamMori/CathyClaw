#!/bin/bash
# CDP 回环转发器守护（v4，2026-09-14）
# v4 修复：scope:"session" 后存在多个 per-session browser 容器（各自宿主映射端口），
#   v3 的 head -1 只为第一个容器建 relay，其余会话 browser 全瘫。
#   v4 遍历全部 openclaw-sbx-browser-* 容器，逐个探测并按需拉起独立 relay。
# 保留 v3 自愈：每次拉起前重拷 js（容器层易失）；确保 gateway attach browser 网络。
# 保留 v2 修复：先探测按需拉起，不杀进程；端口占用时新实例自行退出，无害。
set +e

LOGTAG="cdp-relay"
JS_SRC=/usr/local/bin/cdp-relay.js

log() { echo "$(date -Is) [$LOGTAG] $*"; }

relay_alive() {
  local hp="$1"
  docker exec openclaw-gateway sh -lc \
    "curl -s -m 2 -o /dev/null -w '%{http_code}' http://127.0.0.1:$hp/json/version" 2>/dev/null
}

# js 与网络 attach 每轮确保一次（幂等）
ensure_prereq() {
  if [ -f "$JS_SRC" ]; then
    docker cp "$JS_SRC" openclaw-gateway:/usr/local/bin/cdp-relay.js 2>/dev/null
  else
    log "ERR missing $JS_SRC on host"; return 1
  fi
  NETS=$(docker inspect openclaw-gateway --format '{{range $k,$v := .NetworkSettings.Networks}}{{$k}} {{end}}' 2>/dev/null)
  case "$NETS" in
    *openclaw-sandbox-browser*) : ;;
    *) docker network connect openclaw-sandbox-browser openclaw-gateway 2>/dev/null && log "network re-attached" ;;
  esac
  return 0
}

while true; do
  BCS=$(docker ps --filter name=openclaw-sbx-browser --format '{{.Names}}')
  if [ -n "$BCS" ] && ensure_prereq; then
    for BC in $BCS; do
      BIP=$(docker inspect "$BC" --format '{{range .NetworkSettings.Networks}}{{.IPAddress}} {{end}}' 2>/dev/null | awk '{print $1}')
      HP=$(docker port "$BC" 9222/tcp 2>/dev/null | head -1 | sed 's/.*://')
      [ -n "$BIP" ] && [ -n "$HP" ] || continue
      CODE=$(relay_alive "$HP")
      if [ "$CODE" != "200" ]; then
        docker exec -d openclaw-gateway node /usr/local/bin/cdp-relay.js \
          "{\"listenPort\":$HP,\"targetHost\":\"$BIP\",\"targetPort\":9222}"
        log "relay 127.0.0.1:$HP -> $BIP:9222 ($BC)"
      fi
    done
  fi
  sleep 30
done
