#!/bin/sh
SBX=$(docker ps --format '{{.Names}}' | grep sbx-browser | head -1)
GW=openclaw-gateway
for round in 1 2 3 4; do
  MISS=$(docker exec $GW sh -c "ldd /usr/lib/chromium/chromium 2>/dev/null | grep 'not found' | cut -d' ' -f1" | sort -u)
  [ -z "$MISS" ] && break
  echo "round$round: missing: $(echo $MISS | tr '\n' ' ')"
  for lib in $MISS; do
    docker exec $SBX tar -ch -C /usr/lib/x86_64-linux-gnu "$lib" 2>/dev/null | docker exec -i $GW tar -x -C /usr/lib/x86_64-linux-gnu 2>/dev/null
  done
  docker exec $GW ldconfig >/dev/null 2>&1
done
echo FINAL_NOT_FOUND=$(docker exec $GW sh -c "ldd /usr/lib/chromium/chromium 2>/dev/null | grep -c 'not found'")
docker exec $GW chromium --version 2>&1 | head -1
