#!/usr/bin/env python3
"""
selfcheck.py — 基于「健康基线清单」的自检 + 白名单自修引擎

设计要点：
  - 检查项从 /data/etc/openclaw/health-baseline.json 读取，**不写死在代码里**。
    新增组件只需往清单加一条，自检自动覆盖。
  - 两级：--quick 只查 critical 且全绿静默；--full 全查并输出完整报告。
  - 自修仅执行清单里 fix_safe=true 的白名单动作，每步写审计。
  - 绝不执行：重建 gateway、改凭据、删数据。

用法：
  selfcheck.py --quick          关键项快检，异常才输出
  selfcheck.py --full           全量检查，始终输出
  selfcheck.py --json           机器可读
  selfcheck.py --no-fix         只诊断不修
"""
import json
import os
import re
import subprocess
import sys
import time
import shutil

BASE = "/data/etc/openclaw/health-baseline.json"
AUDIT = "/var/log/selfheal/audit.jsonl"
STATE = "/data/state/workspace/selfcheck-state.json"
LOG = "/var/log/selfcheck.log"
COMPOSE = "/data/scripts/docker-compose.gateway.yml"
GW = "openclaw-gateway"


def log(msg):
    line = f"{time.strftime('%Y-%m-%d %H:%M:%S')} {msg}"
    try:
        os.makedirs(os.path.dirname(LOG), exist_ok=True)
        with open(LOG, "a", encoding="utf-8") as f:
            f.write(line + "\n")
    except Exception:
        pass
    return line


def audit(action, check_id, before, after, result):
    try:
        os.makedirs(os.path.dirname(AUDIT), exist_ok=True)
        rec = {
            "ts": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
            "action": action,
            "check": check_id,
            "before": before,
            "after": after,
            "result": result,
        }
        with open(AUDIT, "a", encoding="utf-8") as f:
            f.write(json.dumps(rec, ensure_ascii=False) + "\n")
    except Exception:
        pass


def sh(cmd, timeout=30):
    try:
        p = subprocess.run(cmd, shell=True, capture_output=True, text=True, timeout=timeout)
        return p.returncode, (p.stdout or "").strip(), (p.stderr or "").strip()
    except subprocess.TimeoutExpired:
        return 124, "", "timeout"
    except Exception as e:
        return 1, "", str(e)


def dsh(cmd, timeout=30):
    """在 gateway 容器内执行"""
    return sh(f'docker exec {GW} {cmd}', timeout=timeout)


# ---------------- 各类检查 ----------------

def chk_stale_lock(c):
    """检测陈旧的 sqlite lock 文件（0 字节 + 超龄 + 无人持有）→ 索引静默停更。

    背景：2026-09-16 03:42 产生的 0 字节 reindex-lock 一直留到 09-17，
    导致 `openclaw memory search` 持续报 "another reindex is active"，
    而自检全绿 —— 因为当时没有任何检查项覆盖「锁文件」这一维度。

    判据（四条同时满足才算陈旧）：
      (1) 文件存在且大小 == 0（正常持锁进程会写入 pid 内容）
      (2) mtime 早于 min_age_seconds（默认 1800s，给正常重建留足时间）
      (3) 没有任何活进程持有该 fd
    """
    agents = c.get("agents", ["main", "guest"])
    min_age = int(c.get("min_age_seconds", 1800))

    # 枚举容器内所有可能相关进程的 fd，建立「被持有文件」集合。
    # 不写死 pid：gateway 可能重启导致 pid 变化，reindex 还可能是子进程干的。
    _, fdout, _ = dsh(
        "sh -lc '"
        "for p in /proc/[0-9]*; do"
        "  for f in $p/fd/*; do"
        "    t=$(readlink $f 2>/dev/null) || continue;"
        "    case $t in *lock.sqlite|*.lock) echo $t;; esac;"
        "  done;"
        "done | sort -u'",
        timeout=25,
    )
    held = set(x.strip() for x in (fdout or "").splitlines() if x.strip())

    stale, checked = [], []
    for a in agents:
        d = f"/home/node/.openclaw/agents/{a}/agent"
        # 0 字节的 *lock.sqlite，输出「完整路径 mtime」
        _, out, _ = dsh(
            f"sh -lc 'find {d} -maxdepth 1 -type f -size 0 "
            f"\\( -name \"*lock.sqlite\" -o -name \"*.lock\" \\) "
            f"-printf \"%p %T@\\n\" 2>/dev/null'",
            timeout=20,
        )
        if not out:
            continue
        now = time.time()
        for line in out.splitlines():
            parts = line.split()
            if len(parts) < 2:
                continue
            path = parts[0]
            try:
                mtime = float(parts[1])
            except ValueError:
                continue
            age = now - mtime
            fname = os.path.basename(path)
            if age < min_age:
                continue
            checked.append(f"{a}/{fname}({int(age)}s)")
            # 只有当它既超龄、0 字节，又确实无人持有时，才判定为陈旧
            if path not in held and fname not in held:
                stale.append(f"{a}/{fname}(age={int(age)}s,0B,unheld)")

    if stale:
        return False, "stale-lock: " + ", ".join(stale[:4])
    return True, "no-stale-lock" + (f" (aging={','.join(checked)})" if checked else "")



def chk_workspace_ownership(c):
    """工作区属主一致性：宿主 workspace 每个目录都必须可被沙箱(uid 1000)写入。

    背景（2026-09-17 实盘事故）：
      沙箱容器把宿主 /home/node/.openclaw/workspace -> /workspace (RW) 绑进去，
      容器内身份是 uid=1000(node) 且无任何 capability。
      而部分目录是 root 身份创建的（root 跑补丁 / docker cp / 手工 ssh 编辑），
      755 + owner root => 容器内 write/edit = EACCES，git 还会报 dubious ownership。
      症状：agent「连写都写不了」，且会绕远路甚至让用户手工改。
      坑点：宿主机 `ls -l` 看不出问题，必须切到 uid 1000 才暴露。

    判据：对每个目录以 uid 1000 实探 `touch && rm`。
      为什么必须逐目录而非只看父目录：嵌套子目录可以单独是只读的，
      父目录可写完全掩盖子目录不可写 —— 这正是本检查第一版漏报的原因。
      实探同时覆盖 ACL / 不可变属性 / 只读挂载，比看 mode 位可靠。
    """
    paths = c.get("paths") or ["/data/state/workspace"]
    skip = c.get("skip_dirs") or [".git", "node_modules", "__pycache__",
                                  ".venv", "venv", ".cache"]
    maxshow = int(c.get("max_show", 8))
    bad, n_ok = [], 0
    skipped = 0

    for base in paths:
        code, _, _ = sh(f"test -d {base}")
        if code != 0:
            continue
        # 找出 base 下所有目录（含 base 自身），排除 .git 等噪音目录
        conds = " ".join(f'-name {s} -prune -o' for s in skip)
        rc, out, _ = sh(
            f"find {base} {conds} -type d -print 2>/dev/null | head -n 400"
        )
        dirs = [x for x in (out or "").splitlines() if x.strip()]
        if base not in dirs:
            dirs.insert(0, base)

        for d in dirs:
            probe = f"{d}/.__selfcheck_own"
            # 不能被 shell 解释的字符直接跳过（路径里有空格/引号极少但求稳）
            if any(ch in d for ch in "'\"\\$`"):
                skipped += 1
                continue
            rc2, o2, e2 = sh(
                f"setpriv --reuid=1000 --regid=1000 --clear-groups "
                f"sh -c 'touch {probe} && rm -f {probe}' 2>&1"
            )
            if rc2 == 127:
                # 无 setpriv：退化为属主位判断
                _, worn, _ = sh(f"find {d} -maxdepth 0 -not -user 1000 2>/dev/null")
                if worn.strip():
                    bad.append(f"{d} (not-uid1000)")
                else:
                    n_ok += 1
                continue
            if rc2 != 0:
                why = (e2 or o2 or "").strip().splitlines()
                tag = why[0] if why else "write-failed"
                # 压缩成短原因
                if "Permission denied" in tag:
                    tag = "EACCES"
                bad.append(f"{d} ({tag})")
            else:
                n_ok += 1

    if bad:
        head = bad[:maxshow]
        more = f" …(+{len(bad) - len(head)} more)" if len(bad) > len(head) else ""
        return False, (f"workspace-unwritable-by-uid1000: "
                       f"{len(bad)} dirs, e.g. " + "; ".join(head) + more)
    return True, f"workspace-ownership-ok({n_ok} dirs writable)"


def fix_workspace_ownership(c):
    """把宿主 workspace 递归改为 1000:1000，使沙箱可写。

    安全性：仅改属主，不动内容与 mode；workspace 是 agent 的工作目录，
            归 node 本就是设计归属（对照 /workspace/memory 一直是 node:node）。
    """
    paths = c.get("paths") or ["/data/state/workspace"]
    ts = time.strftime("%Y%m%d-%H%M%S")
    notes = []
    for d in paths:
        if not os.path.isdir(d):
            notes.append(f"{d}:missing")
            continue
        _, before, _ = sh(f"find {d} -not -user 1000 2>/dev/null | wc -l")
        cnt = (before or "?").strip()
        if cnt == "0":
            notes.append(f"{d}:already-clean")
            continue
        man = f"/data/backups/selfcheck-wsown/{ts}"
        sh(f"mkdir -p {man}")
        sh(f"find {d} -not -user 1000 -printf '%u:%g %M %p\\n' 2>/dev/null "
           f"> {man}/manifest.txt")
        code, _, err = sh(f"chown -R 1000:1000 {d}")
        if code != 0:
            notes.append(f"{d}:chown-failed({err})")
        else:
            notes.append(f"{d}:fixed-{cnt}-entries(manifest {man}/manifest.txt)")
    return True, "wsown-fix: " + "; ".join(notes)


def chk_memory_index(c):
    """校验 memory 索引「完整且新鲜」：Indexed: N/N 必须相等。

    这是 09-16 那 24 小时静默停更的第二道网：
      chk_stale_lock 管「锁没被卡住」，本项管「索引真的建全了」。
    两者互补 —— 用户实际感知到的是后者，而根因在前者。

    判据：`openclaw memory status --agent <a>` 首行 `Indexed: N/N files`
    要求 N == N；若出现 `stale` / `N < N` 则失败。
    """
    agents = c.get("agents", ["main", "guest"])
    bad = []
    for a in agents:
        code, out, err = dsh(f"openclaw memory status --agent {a}", timeout=120)
        if code != 0:
            bad.append(f"{a}:status-failed")
            continue
        low = (out or "").lower()
        m = re.search(r"indexed:\s*(\d+)\s*/\s*(\d+)", low)
        if not m:
            bad.append(f"{a}:no-index-line")
            continue
        got, total = int(m.group(1)), int(m.group(2))
        if "stale" in low:
            bad.append(f"{a}:stale({got}/{total})")
        elif got != total:
            bad.append(f"{a}:incomplete({got}/{total})")
    if bad:
        return False, "memory-index: " + ", ".join(bad)
    return True, "memory-index-ok"


def chk_container_running(c):
    fmt = "{{.State.Running}}"
    code, out, _ = sh(f"docker inspect -f '{fmt}' {c['target']}")
    ok = out == "true"
    return ok, "running" if ok else f"not-running({out or 'missing'})"


def chk_mihomo_netns_fresh(c):
    fmt = "{{.State.StartedAt}}"
    _, gw, _ = sh(f"docker inspect -f '{fmt}' {GW}")
    _, mh, _ = sh(f"docker inspect -f '{fmt}' mihomo-tun")
    if not gw or not mh:
        return False, "missing"
    return mh >= gw, "fresh" if mh >= gw else "stale"


def chk_exec_in_gateway(c):
    _, out, _ = dsh(c["cmd"], timeout=20)
    ok = bool(out) and "no such file" not in out.lower()
    return ok, out[:60] if out else "failed"


def chk_gateway_json_field(c):
    _, out, _ = dsh(c["cmd"], timeout=25)
    try:
        d = json.loads(out)
        val = d.get(c["field"])
        return val == c["expect"], str(val)
    except Exception:
        return False, "unparsable"


def chk_config_check(c):
    code, out, _ = sh(c["script"], timeout=30)
    ok = code == 0
    return ok, "ok" if ok else f"exit={code} {out[-80:]}"


def chk_workspace_fresh(c):
    try:
        a = os.path.getsize(c["real"])
        b = os.path.getsize(c["snap"])
        return a == b, f"real={a} snap={b}"
    except Exception as e:
        return False, f"err:{e}"


def chk_systemd_active(c):
    _, out, _ = sh(f"systemctl is-active {c['unit']}")
    return out == "active", out


def chk_telegram_ok(c):
    _, out, _ = dsh("openclaw health", timeout=40)
    ok = ("Telegram: ok" in out) or ("Telegram: configured" in out)  # 2026.9.4 输出改为 configured
    return ok, "ok" if ok else "not-ok"


def chk_disk_below(c):
    try:
        st = os.statvfs("/")
        pct = int((st.f_blocks - st.f_bfree) * 100 / st.f_blocks)
        return pct < c["threshold"], f"{pct}%"
    except Exception as e:
        return False, str(e)



def chk_pids_below(c):
    """容器 task(进程+线程)总数低于阈值。打满会导致 spawn EAGAIN。"""
    code, out, _ = sh("docker stats --no-stream --format '{{.PIDs}}' " + c["target"])
    try:
        n = int(out.strip().splitlines()[0])
    except Exception:
        return False, "unparsable(%r)" % (out,)
    th = c.get("threshold", 800)
    return n < th, "pids=%d(limit=%d)" % (n, th)


def chk_zombies_below(c):
    """容器内僵尸进程数低于阈值。僵尸堆积会耗尽 pids 名额。"""
    code, out, _ = sh("docker exec " + c["target"] + " sh -c 'ps -eo stat --no-headers 2>/dev/null | grep -c Z'")
    try:
        n = int(out.strip().splitlines()[-1])
    except Exception:
        return False, "unparsable(%r)" % (out,)
    th = c.get("threshold", 50)
    return n < th, "zombies=%d(limit=%d)" % (n, th)



def chk_http_ok(c):
    """从容器内 curl 目标 URL。任何 HTTP 状态码(含401)都算通,000/超时算不通。"""
    code, out, _ = sh("docker exec " + c["target"] + " curl -s -o /dev/null -w '%{http_code}' --max-time 8 " + c["url"])
    v = out.strip().splitlines()[-1] if out.strip() else "000"
    ok = v not in ("", "000")
    return ok, "http=%s" % v


def chk_compose_config(c):
    code, _, err = sh(f"docker compose -f {c['file']} config", timeout=30)
    return code == 0, "valid" if code == 0 else err[-80:]


def chk_cdp_relay(c):
    """cdp-relay 链路检查。

    只查 unit active 不够——服务在而链路断(容器重建/端口漂移)正是浏览器不可用的真实形态。
    判据:① unit 必须 active ② 存在 browser 沙箱容器时,至少一条 relay 链路可达
    (http 401 = CDP 鉴权响应,亦算通;000 = 不通)。无 browser 容器时(按需创建)跳过链路检查。
    """
    unit = c.get("unit", "openclaw-cdp-relay")
    _, act, _ = sh("systemctl is-active " + unit)
    if act != "active":
        return False, "unit=" + act

    _, names, _ = sh("docker ps --filter name=openclaw-sbx-browser --format '{{.Names}}'")
    names = [n for n in names.split() if n.strip()]
    if not names:
        return True, "unit=active, 无 browser 沙箱容器(按需创建,跳过链路检查)"

    ok_any = False
    detail = []
    for n in names:
        _, hp, _ = sh("docker port " + n + " 9222/tcp")
        first = (hp.strip().splitlines() or [""])[0]
        hp = first.rsplit(":", 1)[-1] if ":" in first else ""
        if not hp.isdigit():
            detail.append(n[:26] + ":无映射")
            continue
        _, code, _ = sh(
            "docker exec " + GW + " curl -s -o /dev/null -w '%{http_code}' --max-time 5 "
            "http://127.0.0.1:" + hp + "/json/version")
        v = (code.strip().splitlines() or ["000"])[-1]
        if v not in ("", "000"):
            ok_any = True
            detail.append(n[:26] + ":" + hp + "=http" + v)
        else:
            detail.append(n[:26] + ":" + hp + "=不通")
    return ok_any, ("; ".join(detail) if detail else "no-relay")


def _browser_sandbox_names():
    _, names, _ = sh("docker ps --filter name=openclaw-sbx-browser --format '{{.Names}}'")
    return [n for n in names.split() if n.strip()]


def _gateway_sandbox_ip():
    """解析 gateway 在 browser 沙箱网段(192.168.32.0/20)的地址。

    该地址是 mihomo mixed port 的落点。gateway 重启后 IP 可能漂移,
    因此动态取而不用硬编码。
    """
    _, out, _ = sh("docker inspect " + GW + " --format '{{range .NetworkSettings.Networks}}{{.IPAddress}} {{end}}'")
    ips = [i for i in out.split() if i.startswith("192.168.32.")]
    if ips:
        return ips[0]
    return "192.168.32.3"


def chk_browser_egress(c):
    """browser 沙箱出口链路检查(2026-09-15 新增,第 17 项)。

    背景: browser 沙箱位于独立 docker 网络 192.168.32.0/20,默认网关是宿主 bridge,
    不经 mihomo TUN,境外站点直连必然超时——这正是历史上"浏览器莫名其妙用不了"的根因。
    修复: 沙箱镜像内 openclaw-sandbox-browser 注入 --proxy-server 指向 mihomo mixed port。

    判据(存在 browser 容器时):
      ① chromium 进程必须带 --proxy-server(否则说明镜像被回退/补丁丢失)
      ② 从容器内经该代理访问境外探针必须可达(000 = 不通)
    无 browser 容器时(按需创建)跳过,不算故障。
    """
    names = _browser_sandbox_names()
    if not names:
        return True, "无 browser 沙箱容器(按需创建,跳过)"

    probe = c.get("probe", "https://www.google.com")
    proxy = "http://" + _gateway_sandbox_ip() + ":7890"
    ok_codes = ("200", "204", "301", "302", "429")

    detail = []
    ok_all = True
    for n in names:
        _, cnt, _ = sh("docker exec " + n + " sh -c \"ps aux 2>/dev/null | grep '[c]hromium' | grep -c 'proxy-server'\"")
        raw = (cnt.strip().splitlines() or ["0"])[-1].strip()
        has_arg = raw.isdigit() and int(raw) > 0

        code = "000"
        for _ in range(2):
            _, code, _ = sh("docker exec -e http_proxy=" + proxy + " -e https_proxy=" + proxy + " " +
                            n + " curl -s -o /dev/null -w '%{http_code}' --max-time 15 " + probe)
            code = (code.strip().splitlines() or ["000"])[-1].strip()
            if code in ok_codes:
                break

        good = has_arg and code in ok_codes
        if not good:
            ok_all = False
        detail.append(n[-12:] + ":arg=" + ("ok" if has_arg else "MISSING") + ",probe=" + code)

    return ok_all, ("; ".join(detail) if detail else "no-container")


def _sandbox_containers():
    """返回以 container:<gateway-id> 方式共享 gateway netns 的沙箱容器名。"""
    _, out, _ = sh("docker ps --filter name=openclaw-sbx- --format '{{.Names}}'")
    names = [n for n in out.split() if n.strip() and "browser" not in n]
    return names


def _netns_id(container):
    _, pid, _ = sh("docker inspect " + container + " --format '{{.State.Pid}}'")
    pid = pid.strip()
    if not pid.isdigit():
        return ""
    _, out, _ = sh("readlink /proc/" + pid + "/ns/net 2>/dev/null")
    return out.strip()


def chk_sandbox_netns(c):
    """沙箱 netns 一致性 + 出网检查(2026-09-15 新增,第 18 项)。

    背景: workspace 沙箱以 container:<gateway-id> 方式共享 gateway netns。
    一旦 gateway 重建而沙箱未随之重建,沙箱会被遗留在孤儿 netns 里(只剩 lo,
    无 eth0/eth1/Meta、无默认路由),表现为"DNS 解析失败 / 所有数据源 TLS 超时"
    —— agent 会误判成"网络断了/没权限"并放弃任务。这是 2026-09-15 的重大根因。

    判据: ① 沙箱 netns id 必须与 gateway 一致 ② 沙箱内出网探测必须成功
    无沙箱容器时(按需创建)跳过,不算故障。
    """
    names = _sandbox_containers()
    if not names:
        return True, "无 workspace 沙箱容器(按需创建,跳过)"

    gw_ns = _netns_id(GW)
    probe = c.get("probe", "https://news.ycombinator.com")
    ok_codes = ("200", "204", "301", "302", "429")

    detail = []
    ok_all = True
    for n in names:
        ns = _netns_id(n)
        same = bool(gw_ns) and ns == gw_ns

        code = "000"
        for _ in range(2):
            _, code, _ = sh("docker exec " + n +
                            " curl -s -o /dev/null -w '%{http_code}' --max-time 15 " + probe)
            code = (code.strip().splitlines() or ["000"])[-1].strip()
            if code in ok_codes:
                break

        good = same and code in ok_codes
        if not good:
            ok_all = False
        detail.append(n[-12:] + ":netns=" + ("same" if same else "ORPHAN") + ",probe=" + code)

    return ok_all, ("; ".join(detail) if detail else "no-container")


def _norm_skill(s):
    """归一化 skill 名: 去掉行首 emoji/符号前缀。

    实测同一 skill 在不同 agent 下输出可能带不同 emoji(如 "🔍 tavily" vs "tavily"),
    直接字符串比对会误报「一端缺 skill」,必须先归一化。
    """
    import re
    return re.sub(r"^\W+", "", s).strip()


def _skills_ready(agent):
    """解析 `openclaw skills check --agent <id>` 的 Ready 段。"""
    _, out, _ = sh("docker exec " + GW + " openclaw skills check --agent " + agent, timeout=120)
    names = set()
    in_sec = False
    for ln in out.splitlines():
        if "Ready and visible to model:" in ln:
            in_sec = True
            continue
        if not in_sec:
            continue
        s = ln.strip()
        if not s:
            continue
        if not ln.startswith(" "):
            break
        names.add(_norm_skill(s))
    return names


def _agent_env_keys(agent):
    """读取该 agent 沙箱注入的环境变量 key 集合。"""
    try:
        d = json.load(open("/data/state/openclaw.json", encoding="utf-8"))
        envs = d.get("agents", {}).get("entries", {}).get(agent, {})
        envs = envs.get("sandbox", {}).get("docker", {}).get("env", {}) or {}
        return set(envs.keys())
    except Exception:
        return set()


def chk_agent_parity(c):
    """多 agent 工具面对齐检查(2026-09-15 新增,第 19 项)。

    背景(R16): TAVILY_API_KEY 只注入 main、tavily plugin 又未启用,
    导致 guest 在实时信息类任务上「12 个渠道全败、交零价格」——
    外表是「guest 能力差/不够努力」,实为**少一条腿**。agent 自己查不出来。

    判据: 以第一个 agent(默认 main)为基准,
      ① 其余 agent 的 skills Ready 集合不得缺失(差集须在白名单内)
      ② 其余 agent 的 sandbox.docker.env key 集合不得缺失(差集须在白名单内)
    白名单用于承载**有意**的不对称(如 GH_TOKEN 属个人凭据,不应给朋友侧 guest)。

    不自动修复: 补齐凭据/启用 plugin 涉及安全边界,必须人工决定。
    """
    agents = c.get("agents", ["main", "guest"])
    allow_skill = set(c.get("allow_skill_diff", []))
    allow_env = set(c.get("allow_env_diff", []))
    if len(agents) < 2:
        return True, "仅一个 agent,无需比对"

    base = agents[0]
    issues = []

    try:
        ready = {a: _skills_ready(a) for a in agents}
    except Exception as e:
        return False, "skills 采集失败:" + str(e)[:120]

    base_ready = ready.get(base, set())
    for a in agents[1:]:
        missing = (base_ready - ready.get(a, set())) - allow_skill
        for m in sorted(missing):
            issues.append(a + "缺skill:" + m)

    envs = {a: _agent_env_keys(a) for a in agents}
    base_env = envs.get(base, set())
    for a in agents[1:]:
        missing_env = (base_env - envs.get(a, set())) - allow_env
        for k in sorted(missing_env):
            issues.append(a + "缺env:" + k)

    # 第三层: 必需项绝对判据。
    # 只做双端比对有盲点——若基准 agent 自己也没了(tavily plugin 被整体关掉),
    # 两端「一样缺」反而检测不出来。故再按绝对清单逐 agent 校验。
    require_skills = set(c.get("require_skills", []))
    require_env = set(c.get("require_env", []))
    for a in agents:
        for m in sorted(require_skills - ready.get(a, set())):
            issues.append(a + "缺必需skill:" + m)
        for k in sorted(require_env - envs.get(a, set())):
            issues.append(a + "缺必需env:" + k)

    if issues:
        return False, "; ".join(issues)

    return True, ("skills 对齐(" + str(len(base_ready)) + " 项); 必需项齐备; env 差异仅白名单[" +
                  (",".join(sorted(allow_env)) or "无") + "]")


def fix_stale_lock(c):
    """安全清除「已被 chk_stale_lock 三重证明」的陈旧锁，然后后台触发一次重建。

    安全性论证：进入本函数的前提是 chk_stale_lock 已判定 False，
    即满足 (0 字节) + (超龄 >= min_age) + (无任何进程持有 fd)。
    正常持锁进程必然写入 pid 且持有 fd，因此这三条同时成立时不可能是"在用"的锁。
    删除前仍逐个备份到 /data/backups/selfcheck-lock/，保留现场可回溯。
    """
    agents = c.get("agents", ["main", "guest"])
    min_age = int(c.get("min_age_seconds", 1800))
    ts = time.strftime("%Y%m%d-%H%M%S")
    bkdir = f"/data/backups/selfcheck-lock/{ts}"
    if sh(f"mkdir -p {bkdir}")[0] != 0:
        return False

    _, fdout, _ = dsh(
        "sh -lc '"
        "for p in /proc/[0-9]*; do"
        "  for f in $p/fd/*; do"
        "    t=$(readlink $f 2>/dev/null) || continue;"
        "    case $t in *lock.sqlite|*.lock) echo $t;; esac;"
        "  done;"
        "done | sort -u'",
        timeout=25,
    )
    held = set(x.strip() for x in (fdout or "").splitlines() if x.strip())

    removed = []
    now = time.time()
    for a in agents:
        d = f"/home/node/.openclaw/agents/{a}/agent"
        _, out, _ = dsh(
            f"sh -lc 'find {d} -maxdepth 1 -type f -size 0 "
            f"\\( -name \"*lock.sqlite\" -o -name \"*.lock\" \\) "
            f"-printf \"%p %T@\\n\" 2>/dev/null'",
            timeout=20,
        )
        for line in (out or "").splitlines():
            parts = line.split()
            if len(parts) < 2:
                continue
            path, raw = parts[0], parts[1]
            try:
                age = now - float(raw)
            except ValueError:
                continue
            fname = os.path.basename(path)
            if age < min_age or path in held or fname in held:
                continue
            # 备份后再删（备份在宿主机侧，需从容器 cp 出来）
            dsh(f"sh -lc 'cat {path} >/dev/null 2>&1; true'", timeout=10)
            if sh(f"docker cp {GW}:{path} {bkdir}/{a}-{fname}")[0] != 0:
                log(f"备份失败，放弃删除 {path}")
                continue
            if dsh(f"rm -f {path}", timeout=10)[0] == 0:
                removed.append(f"{a}/{fname}")
                log(f"已清除陈旧锁 {path} (age={int(age)}s) → 备份 {bkdir}")

    if not removed:
        return False

    # 触发重建：用 status --index 自愈两个 agent
    for a in agents:
        dsh(f"openclaw memory status --index --agent {a}", timeout=900)
    log(f"陈旧锁清除完成 {removed}，已触发重建")
    return chk_stale_lock(c)[0]


def fix_agent_parity(c):
    """只记录不动作: 工具面对齐涉及安全边界,交由人工处理。
    fix_safe=false,selfcheck 不会自动执行;保留此函数是为了让告警有明确归属
    与审计痕迹,而不是被当成「没有修复手段」。
    """
    log("agent_parity 差异需人工处理: 补齐 env/启用 plugin 后须 docker rm -f 沙箱重建")
    return False


CHECKERS = {
    "stale_lock": chk_stale_lock,
    "workspace_ownership": chk_workspace_ownership,
    "memory_index": chk_memory_index,
    "container_running": chk_container_running,
    "mihomo_netns_fresh": chk_mihomo_netns_fresh,
    "exec_in_gateway": chk_exec_in_gateway,
    "gateway_json_field": chk_gateway_json_field,
    "config_check": chk_config_check,
    "workspace_fresh": chk_workspace_fresh,
    "systemd_active": chk_systemd_active,
    "telegram_ok": chk_telegram_ok,
    "disk_below": chk_disk_below,
    "compose_config": chk_compose_config,
    "pids_below": chk_pids_below,
    "zombies_below": chk_zombies_below,
    "http_ok": chk_http_ok,
    "cdp_relay": chk_cdp_relay,
    "browser_egress": chk_browser_egress,
    "sandbox_netns": chk_sandbox_netns,
    "agent_parity": chk_agent_parity,
}


# ---------------- 白名单自修 ----------------

def fix_compose_up_gateway(c):
    return sh(f"docker compose -f {COMPOSE} up -d openclaw-gateway", timeout=120)[0] == 0


def fix_compose_up_mihomo(c):
    return sh(f"docker compose -f {COMPOSE} up -d mihomo-tun", timeout=120)[0] == 0


def fix_compose_recreate_mihomo(c):
    return sh(f"docker compose -f {COMPOSE} up -d --force-recreate mihomo-tun", timeout=120)[0] == 0


def fix_ensure_browser(c):
    return sh("/usr/local/bin/ensure-browser.sh", timeout=600)[0] == 0


def fix_browser_start(c):
    dsh("openclaw browser start", timeout=90)
    time.sleep(5)
    return chk_gateway_json_field({"cmd": "openclaw browser status --json",
                                   "field": "running", "expect": True})[0]


def fix_cfg_guard(c):
    return sh("/usr/local/bin/openclaw-cfg-guard.py", timeout=30)[0] in (0, 2)


def fix_sync_workspace(c):
    return sh("/usr/local/bin/sync-agent-workspace.sh", timeout=120)[0] == 0


def fix_systemctl_restart_te_daemon(c):
    return sh("systemctl restart te-daemon", timeout=60)[0] == 0


def fix_systemctl_restart_ocwatch(c):
    return sh("systemctl restart ocwatch", timeout=60)[0] == 0



def fix_compose_recreate_gateway(c):
    """重建 gateway 容器,清空僵尸与 pids 占用(netns 会随之更新)。"""
    code, _, _ = sh("docker compose -f " + COMPOSE + " up -d --force-recreate openclaw-gateway", timeout=300)
    if code != 0:
        return False
    time.sleep(10)
    return True



def fix_mihomo_autoswitch(c):
    """模型 API 不通时:测各节点延迟并切换主代理到最快活节点(与 mihomo-guard 同逻辑)。"""
    import subprocess
    code = subprocess.call(["/usr/local/bin/mihomo-autoswitch.sh"])
    time.sleep(3)
    return code == 0


def fix_cdp_relay(c):
    """重启 cdp-relay 守护。守护每 30s 遍历 browser 容器重建 relay,故需等一轮再复验。"""
    unit = c.get("unit", "openclaw-cdp-relay")
    sh("systemctl restart " + unit, timeout=60)
    time.sleep(35)
    return chk_cdp_relay(c)[0]


def fix_browser_egress(c):
    """销毁 browser 沙箱容器并用 ensure-browser 重建。

    沙箱是只读根文件系统,不能就地改;openclaw 又是按需创建,所以"删掉让它重建"最干净,
    重建时自然使用当前镜像(已含出口代理注入)。
    """
    for n in _browser_sandbox_names():
        sh("docker rm -f " + n, timeout=60)
    time.sleep(3)
    sh("/usr/local/bin/ensure-browser.sh", timeout=600)
    time.sleep(10)
    return chk_browser_egress(c)[0]


def fix_sandbox_netns(c):
    """销毁孤儿 netns 里的 workspace 沙箱,让 openclaw 按需重建。

    重建后沙箱会重新绑定到 gateway 当前 netns,网络随之恢复。
    沙箱无持久状态(工作区在 bind mount 上),删除是安全的。
    """
    for n in _sandbox_containers():
        sh("docker rm -f " + n, timeout=60)
    time.sleep(3)
    return True


FIXERS = {
    "stale_lock_purge": fix_stale_lock,
    "workspace_ownership_fix": fix_workspace_ownership,
    "compose_up_gateway": fix_compose_up_gateway,
    "compose_up_mihomo": fix_compose_up_mihomo,
    "compose_recreate_mihomo": fix_compose_recreate_mihomo,
    "ensure_browser": fix_ensure_browser,
    "browser_start": fix_browser_start,
    "cfg_guard": fix_cfg_guard,
    "sync_workspace": fix_sync_workspace,
    "systemctl_restart_te_daemon": fix_systemctl_restart_te_daemon,
    "systemctl_restart_ocwatch": fix_systemctl_restart_ocwatch,
    "compose_recreate_gateway": fix_compose_recreate_gateway,
    "mihomo_autoswitch": fix_mihomo_autoswitch,
    "cdp_relay_restart": fix_cdp_relay,
    "browser_egress_recreate": fix_browser_egress,
    "sandbox_netns_recreate": fix_sandbox_netns,
    "agent_parity_report": fix_agent_parity,
}


def main():
    argv = sys.argv[1:]
    quick = "--quick" in argv
    as_json = "--json" in argv
    no_fix = "--no-fix" in argv
    write_state = "--write-state" in argv

    try:
        cfg = json.load(open(BASE, encoding="utf-8"))
    except Exception as e:
        print(f"❌ 无法读取基线清单 {BASE}: {e}")
        return 3

    checks = cfg.get("checks", [])
    if quick:
        checks = [c for c in checks if c.get("critical")]

    results = []
    for c in checks:
        fn = CHECKERS.get(c["type"])
        if not fn:
            results.append((c, False, "no-checker"))
            continue
        try:
            ok, detail = fn(c)
        except Exception as e:
            ok, detail = False, f"err:{e}"

        fixed = None
        if not ok and not no_fix and c.get("fix") and c.get("fix_safe"):
            fixer = FIXERS.get(c["fix"])
            if fixer:
                log(f"FIX-TRY {c['id']} ({c['fix']}) before={detail}")
                try:
                    fok = fixer(c)
                except Exception as e:
                    fok = False
                    detail += f" fixerr:{e}"
                time.sleep(2)
                try:
                    ok2, detail2 = fn(c)
                except Exception:
                    ok2, detail2 = False, "recheck-failed"
                audit(c["fix"], c["id"], detail, detail2, "fixed" if ok2 else "failed")
                log(f"FIX-DONE {c['id']} result={'fixed' if ok2 else 'failed'} after={detail2}")
                fixed = "fixed" if ok2 else "failed"
                if ok2:
                    ok, detail = True, detail2 + " (已自修)"

        results.append((c, ok, detail))

    bad = [r for r in results if not r[1]]

    payload = {
        "ts": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
        "mode": "quick" if quick else "full",
        "total": len(results),
        "ok": len(results) - len(bad),
        "failed": len(bad),
        "items": [{"id": c["id"], "name": c["name"], "ok": ok, "detail": d}
                  for c, ok, d in results],
        "source": "selfcheck.py",
    }

    # --write-state：把结果落盘为机读产物，供 gen_status.py 等消费方读取，
    # 避免消费方各自重新触发全量自检（频率放大）。
    if write_state:
        try:
            os.makedirs(os.path.dirname(STATE), exist_ok=True)
            tmp = STATE + ".tmp"
            with open(tmp, "w", encoding="utf-8") as f:
                json.dump(payload, f, ensure_ascii=False, indent=2)
            os.replace(tmp, STATE)
            try:
                os.chown(STATE, 1000, 1000)
            except Exception:
                pass
        except Exception as e:
            log(f"WRITE-STATE 失败: {e}")

    if as_json:
        print(json.dumps(payload, ensure_ascii=False, indent=2))
    else:
        if quick and not bad:
            return 0
        lines = [f"🩺 自检 {'快检' if quick else '全量'} " + time.strftime("%m-%d %H:%M")]
        if not bad:
            lines.append(f"✅ 全部正常（{len(results)}/{len(results)}）")
        else:
            lines.append(f"⚠️ {len(bad)}/{len(results)} 项异常：")
            for c, _, d in bad:
                lines.append(f"  • {c['name']}: {d}")
            fixedn = [c for c, ok, _ in results if ok and "已自修" in _]
            if fixedn:
                lines.append(f"  （其中 {len(fixedn)} 项已自动修复）")
        print("\n".join(lines))

    log(f"SUMMARY mode={'quick' if quick else 'full'} total={len(results)} failed={len(bad)}")
    return 0 if not bad else 1




if __name__ == "__main__":
    sys.exit(main())
