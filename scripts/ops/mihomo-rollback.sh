#!/bin/bash
# 回滚：以野容器方式重建 mihomo-tun（共享网关 netns）
GWID=$(docker inspect openclaw-gateway --format '{{.Id}}')
docker rm -f mihomo-tun 2>/dev/null
docker run -d --name mihomo-tun \
  --restart unless-stopped \
  --network "container:$GWID" \
  --cap-add NET_ADMIN \
  --device /dev/net/tun:/dev/net/tun \
  -v /usr/local/etc/mihomo/config.yaml:/sub.yaml \
  -v mihomo-data:/root/.config/mihomo \
  --entrypoint /mihomo \
  metacubex/mihomo -f /sub.yaml
echo "mihomo-tun restored (wild container mode)"
