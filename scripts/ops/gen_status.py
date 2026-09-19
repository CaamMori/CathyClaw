#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
gen_status.py —— V5 系统状态可视化面板生成器

读取 selfcheck --json + docker ps + 出口探测 + 健康基线版本，
渲染成单文件、零外部依赖的 status.html（红绿灯面板），写入 /workspace。

配套 cron：*/5 * * * * /usr/local/bin/gen_status.py
铁律 1 配套：本面板就是 selfcheck 的"人眼可见"形态——注入故障后对应灯必变红。
"""
import json
import subprocess
import os
import time

WS = "/data/state/workspace"
OUT_HTML = os.path.join(WS, "status.html")
OUT_JSON = os.path.join(WS, "status.json")
BASE = "/data/etc/openclaw/health-baseline.json"
SC = "/usr/local/bin/selfcheck.py"
STATE = os.path.join(WS, "selfcheck-state.json")


def run(cmd, timeout=30):
    try:
        return subprocess.run(cmd, shell=True, capture_output=True, text=True, timeout=timeout)
    except Exception as e:
        class R:
            stdout = ""
            stderr = str(e)
            returncode = -1
        return R()


def read_state():
    """读取 selfcheck 落盘的机读产物（不自行触发自检，避免频率放大）。

    架构：宿主 cron `selfcheck-quick-cron.sh`（每 10min）负责跑自检并用
    `--write-state` 落盘；本面板只消费产物。产物过期则如实标注，不静默用旧值。
    """
    try:
        with open(STATE, encoding="utf-8") as f:
            data = json.load(f)
    except Exception as e:
        return {"ts": time.strftime("%Y-%m-%dT%H:%M:%S%z"), "total": 0,
                "ok": 0, "failed": 0, "items": [],
                "error": f"自检产物不可读（{STATE}）: {e}"}

    # 陈旧度检查：超过 30 分钟说明自检链路可能已停
    try:
        t = time.mktime(time.strptime(data["ts"], "%Y-%m-%dT%H:%M:%S%z"))
        age = time.time() - t
        data["age_seconds"] = int(age)
        if age > 1800:
            data["error"] = f"自检产物已过期 {int(age / 60)} 分钟（超过 30 分钟阈值）"
    except Exception:
        data["age_seconds"] = None
    return data


def main():
    # 1) selfcheck —— 读落盘产物，不再自行执行
    sc_data = read_state()

    # 2) 容器
    cps = run("docker ps -a --format '{{.Names}}|{{.Status}}'").stdout.strip().splitlines()
    oc = []
    for line in cps:
        parts = line.split("|")
        if len(parts) >= 2 and (parts[0].startswith("openclaw") or "mihomo" in parts[0]):
            oc.append({"name": parts[0], "status": parts[1]})

    # 3) 出口探测（从 gateway 容器走 mihomo TUN）
    eg = run("docker exec openclaw-gateway sh -c 'curl -s -o /dev/null -w \"%{http_code}\" --max-time 8 https://www.google.com 2>&1'", timeout=15)
    egress_code = eg.stdout.strip()
    egress_ok = egress_code in ("200", "301", "302", "304")

    # 4) 基线版本
    try:
        base = json.load(open(BASE))
        base_ver, base_upd = base.get("version"), base.get("updated")
    except Exception:
        base_ver = base_upd = None

    data = {
        "generated": time.strftime("%Y-%m-%d %H:%M:%S %Z"),
        "selfcheck": sc_data,
        "containers": oc,
        "egress": {"code": egress_code, "ok": egress_ok},
        "baseline": {"version": base_ver, "updated": base_upd},
    }
    json.dump(data, open(OUT_JSON, "w"), ensure_ascii=False, indent=2)

    html = TEMPLATE.replace("__DATA_JSON__", json.dumps(data, ensure_ascii=False))
    open(OUT_HTML, "w", encoding="utf-8").write(html)
    # 面板需可被 agent / 用户读取；保持 1000:1000 与其他 workspace 文件一致
    for p in (OUT_HTML, OUT_JSON):
        try:
            os.chown(p, 1000, 1000)
        except Exception:
            pass
    print(f"status.html generated: {len(html)} bytes, selfcheck {sc_data.get('ok')}/{sc_data.get('total')}")


TEMPLATE = r"""<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta http-equiv="refresh" content="60">
<title>OpenClaw 系统状态面板</title>
<style>
  :root{ --bg:#0d1117; --card:#161b22; --line:#30363d; --ok:#2ea043; --fail:#f85149; --txt:#e6edf3; --muted:#8b949e; }
  *{box-sizing:border-box}
  body{margin:0;background:var(--bg);color:var(--txt);font:15px/1.6 -apple-system,"Segoe UI",Roboto,"PingFang SC","Microsoft YaHei",sans-serif;padding:24px}
  h1{font-size:22px;margin:0 0 4px}
  .sub{color:var(--muted);font-size:13px;margin-bottom:20px}
  .banner{border-radius:10px;padding:14px 18px;font-size:18px;font-weight:600;margin-bottom:22px;border:1px solid var(--line)}
  .banner.ok{background:rgba(46,160,67,.12);border-color:var(--ok);color:#7ee2a8}
  .banner.fail{background:rgba(248,81,73,.12);border-color:var(--fail);color:#ff9d96}
  .grid{display:grid;gap:18px;grid-template-columns:1fr;max-width:1100px}
  .panel{background:var(--card);border:1px solid var(--line);border-radius:10px;padding:16px 18px}
  .panel h2{font-size:15px;margin:0 0 12px;color:var(--muted);font-weight:600;letter-spacing:.5px;text-transform:uppercase}
  .row{display:flex;align-items:center;gap:10px;padding:5px 0;border-bottom:1px dashed rgba(48,54,61,.5)}
  .row:last-child{border-bottom:0}
  .dot{font-size:15px;width:18px;text-align:center;flex:0 0 18px}
  .nm{flex:1}
  .dt{color:var(--muted);font-size:13px;font-family:ui-monospace,SFMono-Regular,Menlo,monospace;max-width:46%;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
  .cards{display:grid;gap:10px;grid-template-columns:repeat(auto-fill,minmax(260px,1fr))}
  .card{background:#0d1117;border:1px solid var(--line);border-radius:8px;padding:10px 12px}
  .card b{display:block;font-size:13px;word-break:break-all;margin:2px 0}
  .muted{color:var(--muted);font-size:12px}
  .stat{display:flex;gap:24px;flex-wrap:wrap;margin-bottom:6px}
  .stat div{font-size:13px;color:var(--muted)}
  .stat b{color:var(--txt);font-size:20px;display:block}
  a{color:#58a6ff}
</style>
</head>
<body>
<h1>OpenClaw 系统状态面板</h1>
<div class="sub" id="gen"></div>
<div id="banner" class="banner"></div>
<div class="grid">
  <div class="panel">
    <h2>自检总览（selfcheck 19 项）</h2>
    <div class="stat" id="stat"></div>
    <div id="items"></div>
  </div>
  <div class="panel">
    <h2>容器状态</h2>
    <div class="cards" id="conts"></div>
  </div>
  <div class="panel">
    <h2>出口链路（HTTPS 经 mihomo TUN）</h2>
    <div id="egress" class="card"></div>
  </div>
  <div class="panel">
    <h2>健康基线</h2>
    <div class="muted" id="base"></div>
  </div>
</div>
<script>
const DATA = __DATA_JSON__;
document.getElementById('gen').textContent = '生成时间：' + DATA.generated + ' ｜ 每 60 秒自动刷新（由 cron 重新生成）';
const sc = DATA.selfcheck;
const allOk = (sc.failed||0) === 0;
const banner = document.getElementById('banner');
banner.className = 'banner ' + (allOk ? 'ok' : 'fail');
banner.textContent = allOk ? '🟢 全部正常（' + sc.ok + '/' + sc.total + '）' : '🔴 ' + sc.failed + ' 项异常（' + sc.ok + '/' + sc.total + '）';
document.getElementById('stat').innerHTML =
  '<div><b>' + sc.ok + '</b>通过</div><div><b>' + sc.failed + '</b>异常</div><div><b>' + sc.total + '</b>总数</div>' +
  (sc.ts ? '<div><b style="font-size:13px">' + sc.ts + '</b>自检时刻</div>' : '');
document.getElementById('items').innerHTML = (sc.items||[]).map(function(it){
  const cls = it.ok ? '🟢' : '🔴';
  const dt = (it.detail==null?'':(''+it.detail));
  return '<div class="row"><span class="dot">'+cls+'</span><span class="nm">'+it.name+'</span><span class="dt" title="'+dt.replace(/"/g,'')+'">'+dt+'</span></div>';
}).join('');
document.getElementById('conts').innerHTML = (DATA.containers||[]).map(function(c){
  const up = c.status.indexOf('Up')===0;
  return '<div class="card"><span class="dot">'+(up?'🟢':'🔴')+'</span><b>'+c.name+'</b><div class="muted">'+c.status+'</div></div>';
}).join('');
const eg = DATA.egress;
document.getElementById('egress').innerHTML = '<span class="dot">'+(eg.ok?'🟢':'🔴')+'</span> <b>'+ (eg.ok ? '出口可达' : '出口异常') + '</b><div class="muted">HTTP '+(eg.code||'无')+' ｜ 经 mihomo TUN 出网</div>';
const b = DATA.baseline||{};
document.getElementById('base').textContent = '版本 v' + (b.version||'?') + ' ｜ 更新于 ' + (b.updated||'未知') + ' ｜ 检查项 ' + (sc.total||0) + ' 条';
</script>
</body>
</html>
"""

if __name__ == "__main__":
    main()
