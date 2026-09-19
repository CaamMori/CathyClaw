#!/usr/bin/env python3
"""加固：把"沙箱全功能"配置纳入持续守护，防漂移。

每 2 分钟由 cron 调用，幂等。检查项：
  1. sandbox.docker.binds 含 live 任务引擎挂载 -> /opt/task-engine
  2. sandbox.docker.network == container:openclaw-gateway（浏览器桥接需共享回环）
  3. sandbox.docker.dangerouslyAllowExternalBindSources / ReservedContainerTargets / ContainerNamespaceJoin 均为 true
  4. sandbox.browser.enabled 且 network=openclaw-sandbox-browser
  5. tools.sandbox.tools.allow 含 browser，deny 不含 browser
  6. agents.defaults.verboseDefault == off（否则每步工具调用都发独立消息，导致 Telegram 刷屏）
任一缺失则修复并记日志。
"""
import json, sys, time, shutil

P = "/data/state/openclaw.json"
LOG = "/var/log/openclaw-cfg-guard.log"
BIND = "/data/state/workspace/task-engine:/opt/task-engine:rw"
STALE_BINDS = {"/data/state/workspace/task-engine:/workspace/task-engine:rw"}
TS = time.strftime("%Y-%m-%d %H:%M:%S")


def log(msg):
    line = f"{TS} {msg}"
    print(line)
    try:
        with open(LOG, "a", encoding="utf-8") as f:
            f.write(line + "\n")
    except Exception:
        pass


def main():
    try:
        with open(P, encoding="utf-8") as f:
            cfg = json.load(f)
    except Exception as e:
        log(f"ERR cannot read config: {e}")
        return 1

    fixed = []
    d = cfg.setdefault("agents", {}).setdefault("defaults", {})
    sbx = d.setdefault("sandbox", {})
    docker = sbx.setdefault("docker", {})

    # 1) 引擎挂载（清理早期遗留路径）
    binds = docker.setdefault("binds", [])
    before = list(binds)
    binds[:] = [b for b in binds if b not in STALE_BINDS]
    if BIND not in binds:
        binds.append(BIND)
    if binds != before:
        fixed.append("binds")
        docker["dangerouslyAllowExternalBindSources"] = True

    # 2) 沙箱共享网关网络命名空间（浏览器 bridge 只监听 127.0.0.1）
    if docker.get("network") != "container:openclaw-gateway":
        docker["network"] = "container:openclaw-gateway"
        fixed.append("docker.network")

    # 3) 危险开关
    for k in ("dangerouslyAllowExternalBindSources",
              "dangerouslyAllowReservedContainerTargets",
              "dangerouslyAllowContainerNamespaceJoin"):
        if docker.get(k) is not True:
            docker[k] = True
            fixed.append(k)

    # 4) 浏览器
    br = sbx.setdefault("browser", {})
    if br.get("enabled") is not True:
        br["enabled"] = True
        fixed.append("browser.enabled")
    if br.get("network") != "openclaw-sandbox-browser":
        br["network"] = "openclaw-sandbox-browser"
        fixed.append("browser.network")
    if br.get("cdpPort") != 9222:
        br["cdpPort"] = 9222
        fixed.append("browser.cdpPort")

    # 6) 关闭 verbose：verboseLevel=on 会让 shouldEmitToolResult() 恒真，
    #    每次工具调用都 emitToolSummary -> 独立消息，Telegram 里刷屏。
    if d.get("verboseDefault") != "off":
        d["verboseDefault"] = "off"
        fixed.append("verboseDefault")

    # 5) 工具策略
    st = cfg.setdefault("tools", {}).setdefault("sandbox", {}).setdefault("tools", {})
    allow = st.setdefault("allow", [])
    if "browser" not in allow:
        allow.append("browser")
        fixed.append("allow.browser")
    deny = st.setdefault("deny", [])
    if "browser" in deny:
        deny.remove("browser")
        fixed.append("deny.browser-removed")

    if fixed:
        shutil.copy2(P, P + ".bak-guard-" + time.strftime("%Y%m%d-%H%M%S"))
        with open(P, "w", encoding="utf-8") as f:
            json.dump(cfg, f, indent=2, ensure_ascii=False)
            f.write("\n")
        log("FIXED: " + ", ".join(fixed))
        return 2
    log("SUMMARY ok")
    return 0


if __name__ == "__main__":
    sys.exit(main())
