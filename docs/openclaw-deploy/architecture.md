# Architecture - OpenClaw Production Deployment

## Topology

```
Host Server (Linux x86_64, 4C/4G/80G)
|
+-- docker compose (/data/scripts/docker-compose.gateway.yml)
|   +-- openclaw-gateway        Main process (session orchestration, model dispatch)
|   |   +-- Config: /data/state/openclaw.json (hot-reload)
|   |   +-- Workspace: /data/state/workspace/ (bind mount, always fresh)
|   |   +-- Memory: managed llama.cpp local embedding (on-demand)
|   |   +-- Browser: Chromium (on-demand)
|   |
|   +-- mihomo-tun              Proxy sidecar (TUN 198.18.0.0/15)
|   |   +-- network_mode: service:gateway (shared netns)
|   |   +-- Control API: 127.0.0.1:9090 (only reachable in gateway netns)
|   |
|   +-- openclaw-recovery-watchdog  Crash recovery (15s heartbeat)
|   |
|   +-- Sandbox containers (auto-rebuilt by configHash)
|       +-- openclaw-sbx-workspace-<hash>       exec/read/write
|       +-- openclaw-sbx-browser-workspace-<hash>  isolated network
|
+-- Host cron (10 watchdog scripts)
+-- systemd: ocwatch / recovery-watchdog / te-daemon
+-- /usr/local/bin/*.sh         Ops scripts
```

## Data Flow

1. User message -> Telegram Bot API -> OpenClaw Gateway
2. Gateway dispatches to sandbox container -> agent processes
3. Agent calls model -> mihomo TUN -> proxy node -> model API
4. Agent calls tools -> exec/read/write in sandbox
5. Reply -> Gateway -> Telegram Bot API -> User

## Key Design Decisions

### Why TUN instead of HTTP proxy
- TUN captures all egress automatically, agent code needs no proxy config
- Trade-off: DNS needs extra handling (fake-ip / DNS hijack)

### Why bind mount workspace (not snapshot)
- Old architecture used one-shot snapshots -> stale files (8-day-old AGENTS.md)
- Bind mount guarantees always-fresh content
- Trade-off: uid management critical (gateway vs sandbox must match)

### Why hot-reload instead of restart
- Restart = container ID changes -> mihomo netns breaks -> all egress dies
- Restart = all sandbox containers rebuilt -> sessions interrupted
- Hot-reload = zero downtime, wait for "config hot reload applied" in logs

## Container Roles

| Container | Purpose | Network |
|---|---|---|
| openclaw-gateway | Main process | host (shared netns) |
| mihomo-tun | Proxy sidecar | service:gateway |
| openclaw-recovery-watchdog | Crash recovery | host |
| openclaw-sbx-workspace-* | exec sandbox | container:gateway |
| openclaw-sbx-browser-workspace-* | browser sandbox | isolated |

## Why Gateway Uses Host Network

- TUN device needs NET_ADMIN + /dev/net/tun
- Host networking shares host netns, mihomo TUN captures all egress
- Trade-off: ports exposed directly, must protect with auth.token + rateLimit

## Network Namespace (netns) Detail

### Why shared netns

mihomo TUN needs NET_ADMIN + /dev/net/tun. Via `network_mode: service:gateway`, mihomo shares the gateway network namespace. TUN device `tun0` takes over all outbound traffic.

### netns breakage symptoms

After gateway rebuild, sandbox containers hold stale netns references:
- Only `lo` interface, no default route
- `getent hosts` all fail
- curl always returns `000`
- Agent sees "all data sources timeout"

### Fix

```bash
docker compose -f docker-compose.gateway.yml up -d --force-recreate mihomo-tun
for c in $(docker ps -a --format '{{.Names}}' | grep -E '^openclaw-sbx-'); do docker restart $c; done
```

## Browser Sandbox Proxy

### Problem

Browser sandbox runs on isolated network 192.168.32.0/20, bypasses mihomo TUN. Direct overseas connections fail.

### Fix

Inject --proxy-server in sandbox image:

```dockerfile
FROM openclaw-sandbox-browser:bookworm-slim
ENV OPENCLAW_BROWSER_PROXY=http://openclaw-gateway:7890
```

> Do not modify SSRF config. Check fake-ip-filter first.

## CDP Relay

Browser sandbox CDP (Chrome DevTools Protocol) bridges via TCP:

```
agent -> gateway:18799 -> browser-sandbox:9222
```

```bash
systemctl enable --now openclaw-cdp-relay
```

> Relay down = sandbox CDP always 000 = "Can't reach the OpenClaw browser control service".
