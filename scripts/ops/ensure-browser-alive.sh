#!/bin/bash
# ensure-browser-alive.sh — 幂等自愈 Chromium 二进制/依赖;浏览器进程按需启动
#
# 历史缺陷(v1):
#   - chromium 缺失时调用 ensure-browser.sh,后者会跑 `apt-get update`,
#     在网络经 mihomo 代理时经常卡死数分钟;而且故障期间每 5 分钟盲重试,
#     把 gateway 启动/响应拖垮。
#   - 检测只看 /usr/bin/chromium (Debian launcher 包装脚本),它依赖
#     /etc/chromium.d/* 存在,空目录时 glob 不展开会误报"不可用"。
#
# v2 改进:
#   1. 检测优先用真实二进制 /usr/lib/chromium/chromium。
#   2. 修复优先「从 browser 沙箱容器离线同步库」——秒级、不依赖网络。
#   3. 失败退避:记录失败时间,300 秒内不重复重试,避免拖垮 gateway。
set -u

GW=openclaw-gateway
BROWSER_SBX=$(docker ps --format '{{.Names}}' | grep -m1 '^openclaw-sbx-browser-agent-main-' || echo openclaw-sbx-browser-agent-main-f331f052)
LIBDIR=/usr/lib/x86_64-linux-gnu
LOG=/var/log/ensure-browser-alive.log
STAMP=/var/run/ensure-browser-alive.lastfail
REAL_BIN=/usr/lib/chromium/chromium
WRAP_BIN=/usr/bin/chromium

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$LOG"; }

chromium_ok() {
  docker exec "$GW" "$REAL_BIN" --version >/dev/null 2>&1 && return 0
  docker exec "$GW" "$WRAP_BIN" --version >/dev/null 2>&1 && return 0
  return 1
}

gateway_running() {
  docker inspect -f '{{.State.Running}}' "$GW" 2>/dev/null | grep -q true
}

# 从 browser 沙箱容器离线同步库文件(经 tar 管道,解引用符号链接)
sync_libs_from_browser() {
  docker inspect -f '{{.State.Running}}' "$BROWSER_SBX" 2>/dev/null | grep -q true || {
    log "browser 沙箱未运行,无法离线同步"; return 1;
  }
  # 1) 先补关键库
  local libs="libdouble-conversion.so.3 libharfbuzz-subset.so.0 libasound.so.2 \
libpulse.so.0 libFLAC.so.12 libopus.so.0 libXNVCtrl.so.0 libminizip.so.1 \
libogg.so.0 libsndfile.so.1 libasyncns.so.0 libmp3lame.so.0 libvorbis.so.0 \
libvorbisenc.so.2 libmpg123.so.0 liblzma.so.5 libsqlite3.so.0 libapparmor.so.1"
  docker exec "$BROWSER_SBX" tar -ch -C "$LIBDIR" $libs 2>/dev/null \
    | docker exec -i "$GW" tar -x -C "$LIBDIR" 2>/dev/null
  # 2) 全量补齐(不覆盖已有)
  docker exec "$BROWSER_SBX" tar -ch -C "$LIBDIR" . 2>/dev/null \
    | docker exec -i "$GW" tar -x --skip-old-files -C "$LIBDIR" 2>/dev/null
  docker exec "$GW" ldconfig >/dev/null 2>&1
  # 3) 补 launcher 需要的目录(空 glob 会报错)
  docker exec "$GW" sh -c "mkdir -p /etc/chromium.d && touch /etc/chromium.d/00-defaults" >/dev/null 2>&1
  return 0
}

main() {
  gateway_running || { log "gateway 未运行,跳过"; exit 0; }

  if ! chromium_ok; then
    # 退避:5 分钟内不重复尝试(避免故障期拖垮 gateway)
    if [ -f "$STAMP" ]; then
      local last now
      last=$(cat "$STAMP" 2>/dev/null || echo 0)
      now=$(date +%s)
      if [ $((now - last)) -lt 300 ]; then
        log "chromium 不可用,但处于退避期($((300 - now + last))s 后可重试),跳过"
        exit 0
      fi
    fi
    log "chromium 不可用 → 离线同步 browser 沙箱库文件"
    if sync_libs_from_browser && chromium_ok; then
      log "离线同步成功,chromium 已恢复"
      rm -f "$STAMP"
    else
      log "离线同步未成功,回退 ensure-browser.sh"
      /usr/local/bin/ensure-browser.sh >>"$LOG" 2>&1
      if chromium_ok; then
        log "ensure-browser.sh 恢复成功"
        rm -f "$STAMP"
      else
        date +%s > "$STAMP"
        log "chromium 仍不可用,已记录退避时间戳"
        exit 0
      fi
    fi
  fi

  # OpenClaw 2026.9.4 的浏览器为按需启动并在空闲后自动回收。
  # 不在健康守护中强制 start,避免每 5 分钟制造 Chromium 冷启动和聊天延迟抖动。
  # browser 能力及真实出口仍由按需调用和 selfcheck browser_egress 验证。
  log "chromium 二进制可用;浏览器进程保持按需启动"

  tail -n 800 "$LOG" > "$LOG.tmp" 2>/dev/null && mv "$LOG.tmp" "$LOG"
  exit 0
}

main "$@"
