#!/bin/bash
# fix-gateway-dns.sh — gateway 容器重建后 resolv.conf 会回退到 docker 内嵌 DNS(127.0.0.11 → 宿主国内DNS → 被污染)。
# 本脚本确保 gateway 的 DNS 指向 mihomo(fake-ip, 反污染)。幂等，每 5 分钟跑一次。
GW=openclaw-gateway
cur=$(docker exec "$GW" grep -m1 nameserver /etc/resolv.conf 2>/dev/null | awk '{print $2}')
if [ "$cur" != "127.0.0.1" ]; then
  docker exec "$GW" sh -c "printf 'nameserver 127.0.0.1\noptions ndots:0\n' > /etc/resolv.conf"
  echo "$(date '+%F %T') gateway resolv.conf fixed (was: ${cur:-none})" >> /var/log/mihomo-guard.log
fi
