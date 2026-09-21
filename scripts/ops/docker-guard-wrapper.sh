#!/bin/sh
# docker-guard v1 — 防自杀门卫
# 拦截对 OpenClaw 自身三个组件的破坏性操作；其余 docker 命令原样放行。
# 真二进制: /usr/local/bin/docker.real
SELF_NAMES="openclaw-gateway|openclaw-singbox-sidecar|openclaw-recovery-watchdog"
DANGER_VERBS="rm|kill|stop|restart|update|exec|pause|unpause|rename|commit"

intercept() {
  echo "⛔ docker-guard 已拦截: docker $*" >&2
  echo "   不允许对 OpenClaw 自身组件(openclaw-gateway/openclaw-singbox-sidecar/openclaw-recovery-watchdog)执行破坏性操作。" >&2
  echo "   需要维护请直接告知 Caam，由宿主机侧操作。普通 docker 运维不受影响。" >&2
  exit 1
}

compose_mode=0
verb=""
for a in "$@"; do
  if [ "$a" = "compose" ]; then compose_mode=1; verb=""; continue; fi
  if [ "$compose_mode" = "1" ]; then
    case "$a" in
      down|stop|rm|restart|kill)
        echo "⛔ docker-guard 已拦截: docker compose $*" >&2
        echo "   compose 服务级销毁会连带停掉 OpenClaw 自身组件。需要停别的服务请用 docker stop <容器名>。" >&2
        exit 1;;
      *) : ;;
    esac
    continue
  fi
  case "$a" in
    rm|kill|stop|restart|update|exec|pause|unpause|rename|commit) verb="$a"; continue;;
    -*) continue;;
  esac
  case "$a" in
    openclaw-gateway|openclaw-singbox-sidecar|openclaw-recovery-watchdog)
      [ -n "$verb" ] && intercept "$@";;
  esac
done

exec /usr/local/bin/docker.real "$@"
