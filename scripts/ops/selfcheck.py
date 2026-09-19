#!/usr/bin/env python3
"""OpenClaw self-check - 22-item production health check.

Usage:
  python3 selfcheck.py              # quick (failures only)
  python3 selfcheck.py --full       # show all
  python3 selfcheck.py --json       # JSON for automation
  python3 selfcheck.py --quick      # fast subset (no docker exec)
  python3 selfcheck.py --write-state  # write selfcheck-state.json for panel

Exit: 0 = all pass, 1 = fail
"""
import json, os, subprocess, sys, time
from pathlib import Path

GW = "openclaw-gateway"
WS = Path("/data/state/workspace")
STATE = Path("/data/state")
OC_JSON = STATE / "openclaw.json"
ENV_F = Path("/data/etc/openclaw/runtime.env")
BACKUP = Path("/data/backups")

def run(cmd, t=10):
    try:
        r = subprocess.run(cmd, shell=True, capture_output=True, text=True, timeout=t)
        return r.returncode, r.stdout.strip()
    except subprocess.TimeoutExpired:
        return -1, "timeout"
    except Exception as e:
        return -1, str(e)

def age(p):
    try: return time.time() - p.stat().st_mtime
    except: return -1

# --- 22 checks ---

def c01():
    """Gateway healthy"""
    c, o = run("openclaw health", t=15)
    return c == 0, o

def c02():
    """Chromium binary present"""
    c, o = run("docker exec " + GW + " which chromium")
    if c != 0: return False, "not found"
    c2, o2 = run("docker exec " + GW + " ldd /usr/lib/chromium/chromium 2>&1 | grep -c \'not found\'")
    if c2 == 0 and o2 != "0": return False, o2 + " missing libs"
    return True, "ok"

def c03():
    """mihomo TUN up"""
    c, o = run("docker exec " + GW + " ip addr show tun0")
    return (c == 0 and "tun0" in o), ("up" if c == 0 else "not found")

def c04():
    """DNS resolves"""
    c, o = run("docker exec " + GW + " getent hosts api.telegram.org")
    return (c == 0 and o != ""), (o.split()[0] if o else "fail")

def c05():
    """Disk < 80%"""
    c, o = run("df / --output=pcent | tail -1")
    if c != 0: return False, "df fail"
    try: pct = int(o.strip().rstrip("%"))
    except: return False, "parse"
    return pct < 80, str(pct) + "%"

def c06():
    """Memory < 90%"""
    c, o = run("free -m | awk \'/Mem:/{print $3/$2*100}\'")
    if c != 0: return False, "free fail"
    try: return float(o) < 90, o
    except: return False, "parse"

def c07():
    """PIDs < 800"""
    c, o = run("docker stats --no-stream --format \'{{.PIDs}}\' " + GW)
    if c != 0: return False, "stats fail"
    try: p = int(o)
    except: return False, "parse: " + o
    s = "CRITICAL" if p >= 800 else "WARN" if p >= 600 else "ok"
    return p < 800, str(p) + " (" + s + ")"

def c08():
    """Zombies < 50"""
    c, o = run("docker exec " + GW + " ps -eo stat --no-headers | grep -c Z || echo 0")
    if c != 0: return False, "ps fail"
    try: z = int(o)
    except: return False, "parse"
    s = "CRITICAL" if z >= 50 else "WARN" if z >= 10 else "ok"
    return z < 50, str(z) + " (" + s + ")"

def c09():
    """openclaw.json valid"""
    if not OC_JSON.exists(): return False, "not found"
    try:
        with open(OC_JSON) as f: json.load(f)
    except json.JSONDecodeError as e:
        return False, str(e)
    return True, "valid"

def c10():
    """openclaw.json perms 600"""
    if not OC_JSON.exists(): return False, "not found"
    m = oct(OC_JSON.stat().st_mode)[-3:]
    return m == "600", "mode=" + m

def c11():
    """Workspace bind-mounted"""
    c, _ = run("ls /workspace/AGENTS.md 2>/dev/null")
    if c == 0: return True, "/workspace/AGENTS.md"
    c, _ = run("ls /data/state/workspace/AGENTS.md 2>/dev/null")
    return c == 0, "ok" if c == 0 else "missing"

def c12():
    """Workspace uid 1000"""
    c, o = run("stat -c \'%u\' /workspace/AGENTS.md 2>/dev/null")
    if c != 0:
        c, o = run("stat -c \'%u\' /data/state/workspace/AGENTS.md 2>/dev/null")
    if c != 0: return False, "cannot determine"
    uid = o.strip()
    return uid.isdigit() and int(uid) > 0, "uid=" + uid

def c13():
    """No stale locks"""
    if not WS.exists(): return False, "ws not found"
    locks = list(WS.glob("*lock.sqlite*"))
    stale = [f for f in locks if f.stat().st_size == 0 and age(f) > 1800]
    return len(stale) == 0, str(len(stale)) + " stale" if stale else str(len(locks)) + " active"

def c14():
    """Memory index clean"""
    c, o = run("openclaw memory status 2>&1")
    if c != 0: return False, "fail"
    return "stale" not in o.lower(), o

def c15():
    """runtime.env exists, perms 600"""
    if not ENV_F.exists(): return False, "not found"
    sz = ENV_F.stat().st_size
    if sz == 0: return False, "empty"
    m = oct(ENV_F.stat().st_mode)[-3:]
    return m == "600", str(sz) + "B perm=" + m

def c16():
    """Gateway container present (host-side docker)"""
    c, o = run("docker ps --format '{{.Names}}' | grep -q openclaw-gateway")
    return c == 0, "ok" if c == 0 else "gateway container not found"

def c17():
    """mihomo running"""
    c, o = run("docker ps --format \'{{.Names}}\' | grep mihomo")
    return (c == 0 and "mihomo" in o), "running" if "mihomo" in o else "not running"

def c18():
    """Browser recovery bundle exists"""
    candidates = [
        Path("/usr/local/lib/openclaw-browser/bundle-full.tar.gz"),
        Path("/data/opt/openclaw-browser/bundle-full.tar.gz"),
        Path("/opt/openclaw-browser/bundle-full.tar.gz"),
    ]
    for b in candidates:
        if b.exists():
            return True, "{:.0f}MB".format(b.stat().st_size / 1024 / 1024)
    return False, "not found"

def c19():
    """No recent crashes in logs"""
    c, o = run("docker logs " + GW + " --since 1h 2>&1 | grep -ci \'crash\\|panic\\|fatal\'")
    if c != 0: return False, "cannot read"
    try: n = int(o)
    except: n = 0
    return n == 0, str(n) + " issues" if n > 0 else "clean"

def c20():
    """Backup within 48h"""
    if not BACKUP.exists(): return False, "no backup dir"
    bs = sorted(BACKUP.glob("nightly-*"), reverse=True)
    if not bs: return False, "no backups"
    a = age(bs[0])
    if a < 0: return False, "stat fail"
    h = a / 3600
    return h < 48, "{:.0f}h ago".format(h)

def c21():
    """Optional tools (gh, tmux)"""
    installed = [b for b in ["gh", "tmux"] if run("which " + b)[0] == 0]
    missing = [b for b in ["gh", "tmux"] if run("which " + b)[0] != 0]
    if not missing: return True, "all installed"
    if installed: return True, "partial: " + ", ".join(installed) + " (missing: " + ", ".join(missing) + ")"
    return True, "none installed (optional)"

def c22():
    """OpenClaw version"""
    c, o = run("openclaw --version 2>/dev/null || openclaw version 2>/dev/null")
    return (c == 0), o if c == 0 else "unknown"

ALL = [
    ("gateway_health", c01), ("chromium", c02),
    ("mihomo_tun", c03), ("dns", c04),
    ("disk", c05), ("memory", c06),
    ("pids", c07), ("zombies", c08),
    ("config_valid", c09), ("config_perms", c10),
    ("workspace_bind", c11), ("workspace_uid", c12),
    ("stale_lock", c13), ("memory_index", c14),
    ("runtime_env", c15), ("docker_socket", c16),
    ("mihomo_running", c17), ("browser_bundle", c18),
    ("crash_logs", c19), ("backup", c20),
    ("skill_bins", c21), ("version", c22),
]

STATE_PATH = Path("/var/lib/openclaw/selfcheck-state.json")

def main():
    full = "--full" in sys.argv
    quick = "--quick" in sys.argv
    as_json = "--json" in sys.argv
    write_state = "--write-state" in sys.argv
    # Quick subset: checks that are fast (no docker exec, no network)
    QUICK_NAMES = {"disk", "memory", "config_valid", "config_perms",
                   "workspace_bind", "workspace_uid", "runtime_env", "backup", "version"}
    results = []
    for name, fn in ALL:
        if quick and name not in QUICK_NAMES:
            continue
        try: ok, detail = fn()
        except Exception as e: ok, detail = False, str(e)
        results.append({"name": name, "ok": ok, "detail": detail})
    passed = sum(1 for r in results if r["ok"])
    failed = len(results) - passed
    if write_state:
        STATE_PATH.parent.mkdir(parents=True, exist_ok=True)
        with open(STATE_PATH, "w") as f:
            json.dump({"timestamp": int(time.time()), "passed": passed,
                       "failed": failed, "total": len(results),
                       "results": results}, f)
    if as_json:
        print(json.dumps({"passed": passed, "failed": failed, "total": len(results), "results": results}, indent=2))
    else:
        for r in results:
            icon = "+" if r["ok"] else "X"
            if full or not r["ok"]:
                print("  [%s] %s: %s" % (icon, r["name"], r["detail"]))
        sym = "+" if failed == 0 else "X"
        print("\n%s %d/%d passed" % (sym, passed, len(results)))
    if write_state:
        print("State written to %s" % STATE_PATH)
    sys.exit(0 if failed == 0 else 1)

if __name__ == "__main__":
    main()
