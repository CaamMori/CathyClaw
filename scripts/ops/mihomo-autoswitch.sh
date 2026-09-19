#!/bin/bash
# mihomo-autoswitch.sh — 测各节点延迟,切换 主代理 到最快活节点(供 mihomo-guard 与 selfcheck 调用)
# 输出切到哪个节点;全部死节点时 exit 1。
# 节点名与选择器名请按你的 mihomo 配置填写：
#   MIHOMO_CANDIDATE_NODES="节点A 节点B 节点C"   # 空格分隔的候选节点名
#   MIHOMO_SELECTOR_NAME="主代理"                 # 要切换的代理组名

GW=openclaw-gateway
LOG=/var/log/mihomo-guard.log
CANDIDATE_NODES="${MIHOMO_CANDIDATE_NODES:-JP-1 JP-2 JP-3}"
SELECTOR="${MIHOMO_SELECTOR_NAME:-主代理}"

cat <<'EOF' | docker exec -e CANDIDATE_NODES="$CANDIDATE_NODES" -e SELECTOR="$SELECTOR" -i "$GW" python3 - 2>&1
import json, urllib.request, urllib.parse, os
BASE = 'http://127.0.0.1:9090'
enc = lambda s: urllib.parse.quote(s, safe='')
def get(p, t=8):
    with urllib.request.urlopen(BASE + p, timeout=t) as r: return json.loads(r.read().decode())
def put(p, o, t=8):
    req = urllib.request.Request(BASE + p, data=json.dumps(o).encode(), method='PUT',
                                 headers={'Content-Type': 'application/json'})
    with urllib.request.urlopen(req, timeout=t) as r: return r.status
cands = [n for n in os.environ.get("CANDIDATE_NODES", "").split() if n]
alive = []
for n in cands:
    try:
        d = get('/proxies/%s/delay?url=%s&timeout=4000' % (enc(n), enc('https://www.gstatic.com/generate_204')), t=10)
        if d.get('delay'): alive.append((d['delay'], n))
    except Exception: pass
alive.sort()
if not alive:
    print('ALL_DEAD'); raise SystemExit(1)
best = alive[0][1]
selector = os.environ.get("SELECTOR", "主代理")
try:
    cur = get('/proxies/%s' % enc(selector)).get('now')
except Exception:
    cur = None
# 自动选择子组自己会自愈;只有主代理当前选中仍不可行时才抢手动切换
if best:
    print('SWITCH %s: %s -> %s (delay=%sms)' % (selector, cur, best, alive[0][0]))
    print('PUT', put('/proxies/%s' % enc(selector), {'name': best}))
EOF
rc=$?
if [ $rc -eq 0 ]; then
  echo "$(date '+%F %T') autoswitch done" >> "$LOG"
fi
exit $rc
