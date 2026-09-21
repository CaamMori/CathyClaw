#!/bin/bash
# mihomo-autoswitch.sh — 按 Telegram API 实测各节点,切换 主代理 到最快活节点(供 mihomo-guard 与 selfcheck 调用)
# 诊断信息写日志,不污染 stdout(避免混入 selfcheck 推送到 Telegram)
# 全部死节点时 exit 1。

GW=openclaw-gateway
LOG=/var/log/mihomo-guard.log

log() { echo "$(date '+%F %T') $*" >> "$LOG"; }

result=$(cat <<'EOF' | docker exec -i "$GW" python3 - 2>&1
import json, urllib.request, urllib.parse
BASE = 'http://127.0.0.1:9090'
enc = lambda s: urllib.parse.quote(s, safe='')
def get(p, t=8):
    with urllib.request.urlopen(BASE + p, timeout=t) as r: return json.loads(r.read().decode())
def put(p, o, t=8):
    req = urllib.request.Request(BASE + p, data=json.dumps(o).encode(), method='PUT',
                                 headers={'Content-Type': 'application/json'})
    with urllib.request.urlopen(req, timeout=t) as r: return r.status
cands = ["🇯🇵 日本-东京","🇩🇪 德国-法兰克福","🇭🇰 香港","JP8-HY2","SG3-HY2","JP-2","JP6-HY2","US-2TCP","US-5TCP","US-3TCP"]
alive = []
for n in cands:
    try:
        d = get('/proxies/%s/delay?url=%s&timeout=4000' % (enc(n), enc('https://api.telegram.org/')), t=10)
        if d.get('delay'): alive.append((d['delay'], n))
    except Exception: pass
alive.sort()
if not alive:
    print('ALL_DEAD'); raise SystemExit(1)
best = alive[0][1]
try:
    cur = get('/proxies/%s' % enc('主代理')).get('now')
except Exception:
    cur = None
if best:
    print('SWITCH 主代理: %s -> %s (delay=%sms)' % (cur, best, alive[0][0]))
    print('PUT', put('/proxies/%s' % enc('主代理'), {'name': best}))
EOF
)
rc=$?
# 诊断信息只写日志,不输出到 stdout
log "$result"
if [ $rc -eq 0 ]; then
  log "autoswitch done"
fi
exit $rc
