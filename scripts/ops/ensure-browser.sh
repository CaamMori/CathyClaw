#!/bin/bash
# ensure-browser.sh: 保证 openclaw-gateway 内有可用 chromium，并清除陈旧 SingletonLock
# 重建安全：chromium 二进制 + 全量系统依赖库（实体化）打包在
#   /usr/local/lib/openclaw-browser/bundle-full.tar.gz
#   （2026-09-14 重打：browser 沙箱流式 tar -czhf，-h 解引用消除断链符号链接，
#    含 /usr/lib/x86_64-linux-gnu 全量 2635 项；旧 bundle.tar 保留作回滚）
set -u
GW="${GW:-openclaw-gateway}"
BUNDLE=/usr/local/lib/openclaw-browser/bundle-full.tar.gz
PROFILE_UD=/home/node/.openclaw/browser/openclaw/user-data

# chromium 可用性判定：必须能真正跑起来（--version 成功）才算 OK。
# 注意：容器工作目录是 /app，历史 bug 是 tar 未加 -C / 导致解到 /app/usr/... 而“假成功”。
chromium_ok() {
  docker exec "$GW" /usr/bin/chromium --version >/dev/null 2>&1
}

ensure_chromium() {
  # 2026-09-17 变更：容器已从 user:root 改回镜像默认的 node(uid 1000)。
  # 还原 chromium 需要写 /usr、/etc，node 身份会 Permission denied，
  # 因此凡「写系统路径」的操作一律用 docker exec --user root 临时提权。
  # 注意：这只是借用 root 完成一次性落盘，容器运行身份仍是 node，
  # 不会重新引入「agent 以 root 写文件」的属主污染问题。
  PRIV=(docker exec --user root)
  # /etc/chromium.d 缺失会让 wrapper 脚本 source /etc/chromium.d/* 失败
  # （报 "cannot open /etc/chromium.d/*"），即便二进制与库都齐也跑不起来。
  # bundle 只含 usr 路径，容器重建后该目录不随 bundle 恢复，故每次幂等补齐。
  "${PRIV[@]}" "$GW" mkdir -p /etc/chromium.d >/dev/null 2>&1
  "${PRIV[@]}" "$GW" sh -c 'touch /etc/chromium.d/00-defaults' >/dev/null 2>&1
  if chromium_ok; then
    return 0
  fi
  # 优先 bundle：bundle-full 已含全量系统库（libglib/libnss/libX*/...），还原即可用，
  # 秒级完成；tar -xf 自动识别 gz。apt 在坏网（官方源直连）时会卡满
  # timeout 300+900 共 20 分钟才失败，故降为兜底。
  echo "chromium 不可用，从全量 bundle 还原（-C /）..."
  if [ -f "$BUNDLE" ]; then
    docker exec -i --user root "$GW" tar -xzf - -C / < "$BUNDLE" 2>/dev/null || true
    chromium_ok && return 0
  fi
  # 兜底：apt 在线安装（bundle 丢失/损坏时）
  echo "bundle 未成功，尝试 apt 安装 chromium..."
  timeout 300 "${PRIV[@]}" "$GW" apt-get update -qq >/dev/null 2>&1
  if timeout 900 "${PRIV[@]}" "$GW" apt-get install -y --no-install-recommends chromium >/dev/null 2>&1; then
    chromium_ok && return 0
  fi
  echo "chromium 还原失败"
  return 1
}

clear_stale_lock() {
  docker exec "$GW" rm -f "$PROFILE_UD/SingletonLock" "$PROFILE_UD/SingletonCookie" "$PROFILE_UD/SingletonSocket" "$PROFILE_UD/lock" 2>/dev/null
  return 0
}

# 清理「无 CDP 监听的遗留 chromium」：崩溃/异常退出残留的孤儿进程与 <defunct> 僵尸，
# 但绝不误杀常驻 CDP chromium（其进程树持有 18800 监听）。
# 容器里 ss/fuser 不可用，改用 /proc/net/tcp 的 inode -> /proc/<pid>/fd 映射定位 18800 持有者；
# 仅保留该 keeper 及其后代子树，其余 chromium 一律清除（含其直接子进程；僵尸杀父以回收）。
cleanup_orphan_chromium() {
  docker exec "$GW" sh -c '
    inodes=$(awk "NR>1 && \$4==\"0A\"{split(\$2,a,\":\"); if(a[2]==\"4970\") print \$10}" /proc/net/tcp /proc/net/tcp6 2>/dev/null)
    keeper=""
    for ino in $inodes; do
      for fd in /proc/[0-9]*/fd/*; do
        tgt=$(readlink "$fd" 2>/dev/null)
        case "$tgt" in socket:\[$ino\]) pid=$(echo "$fd" | cut -d/ -f3); keeper="$keeper $pid";; esac
      done
    done
    if [ -z "$keeper" ]; then
      echo "无 CDP chromium 监听 18800，跳过孤儿清理"
      exit 0
    fi
    ps -eo pid=,ppid= > /tmp/ocw_pp.$$ 2>/dev/null || exit 0
    keep="$keeper"
    changed=1
    while [ "$changed" = 1 ]; do
      changed=0
      for d in $(awk -v k="$keep" "BEGIN{split(k,a,\" \");for(i in a)K[a[i]]=1} \$2 in K && !(\$1 in K){print \$1}" /tmp/ocw_pp.$$ 2>/dev/null); do
        echo "$keep" | grep -qw "$d" || { keep="$keep $d"; changed=1; }
      done
    done
    rm -f /tmp/ocw_pp.$$
    killed=0
    for p in /proc/[0-9]*; do
      pid=${p#/proc/}
      comm=$(cat "$p/comm" 2>/dev/null)
      case "$comm" in chromium*|chrome*) ;; *) continue ;; esac
      echo "$keep" | grep -qw "$pid" && continue
      st=$(sed "s/.*) //" "$p/stat" 2>/dev/null | awk "{print \$1}")
      if [ "$st" = "Z" ]; then
        # 僵尸(defunct)无法被 kill 回收；其父通常是 openclaw(PID1)，
        # 绝不可 kill 其父(会毁掉整个容器)。交由 openclaw 自身回收，这里安全跳过。
        continue
      fi
      # 仅清理「存活」的遗留 chromium（含其直接子进程）；不会触及 keeper 子树。
      pkill -9 -P "$pid" 2>/dev/null; kill -9 "$pid" 2>/dev/null
      killed=$((killed+1))
    done
    [ "$killed" -gt 0 ] && echo "清理了 $killed 个遗留(非僵尸) chromium 进程（保留 CDP 浏览器子树）"
  '
  return 0
}

ensure_chromium
clear_stale_lock
cleanup_orphan_chromium
exit 0
