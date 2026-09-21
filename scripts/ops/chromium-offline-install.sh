#!/bin/bash
# 离线安装 chromium 全套依赖(绕开 apt 网络)
# 用法: 宿主机执行; 内部通过 docker exec 在 gateway 容器里 dpkg -i
set +e
GW=openclaw-gateway
LOG=/var/log/chromium-offline-install.log
SRC=/tmp/chromedeps2
WORK=/tmp/chromedeps-in-container

echo "=== $(date -Is) 开始离线安装 chromium 依赖 ===" >> "$LOG"

# 1) 把 deb 目录拷进容器
docker exec "$GW" mkdir -p "$WORK" >> "$LOG" 2>&1
docker cp "$SRC/." "$GW:$WORK/" >> "$LOG" 2>&1
echo "已拷贝 $(ls "$SRC"/*.deb | wc -l) 个 deb 到容器 $WORK" >> "$LOG"

# 2) 安装 xkb-data(被 chromium 依赖)
if [ -f /root/xkb-data_2.35.1-1_all.deb ]; then
  docker cp /root/xkb-data_2.35.1-1_all.deb "$GW:$WORK/" >> "$LOG" 2>&1
fi

# 3) dpkg -i 批量安装(不依赖网络), 容忍顺序问题后用 --configure -a 收尾
docker exec "$GW" sh -lc "dpkg -i --force-depends $WORK/*.deb" >> "$LOG" 2>&1
docker exec "$GW" sh -lc "dpkg --configure -a" >> "$LOG" 2>&1

# 4) 验证
echo "--- 验证 chromium ---" >> "$LOG"
docker exec "$GW" /usr/lib/chromium/chromium --version >> "$LOG" 2>&1
V1=$?
docker exec "$GW" /usr/bin/chromium --version >> "$LOG" 2>&1
V2=$?
echo "real_binary_exit=$V1 wrapper_exit=$V2" >> "$LOG"

if [ "$V1" = "0" ] || [ "$V2" = "0" ]; then
  echo "RESULT=SUCCESS" >> "$LOG"
else
  echo "RESULT=FAILED" >> "$LOG"
fi
echo "=== $(date -Is) 结束 ===" >> "$LOG"
touch /tmp/chromium-offline-install.done
