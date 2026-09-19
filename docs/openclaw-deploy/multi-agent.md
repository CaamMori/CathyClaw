# Multi-Agent Setup Guide

## Concept

- **main**: admin agent, full tools, elevated permissions
- **guest**: visitor agent, limited tools, isolated workspace

## Steps

### 1. Create guest workspace

```bash
mkdir -p /data/state/workspace-guest
cat > /data/state/workspace-guest/AGENTS.md << EOF
# Guest Agent
You are a helpful assistant with limited tools.
EOF
chown -R 1000:1000 /data/state/workspace-guest
```

### 2. Add guest to openclaw.json

```json
{
  "agents": {
    "entries": {
      "guest": {
        "name": "Guest",
        "identity": { "emoji": "🌿" },
        "workspace": "/data/state/workspace-guest"
      }
    }
  }
}
```

### 3. Add routing (bindings)

```json
{
  "channels": {
    "telegram": {
      "bindings": [
        { "agentId": "main", "match": { "peerId": "YOUR_TG_ID" } },
        { "agentId": "guest", "match": { "peerId": "GUEST_TG_ID" } }
      ]
    }
  }
}
```

> **Critical**: main must have explicit binding or default drifts to guest.

### 4. Restart

```bash
docker logs -f openclaw-gateway | grep "config hot reload applied"
```

## Troubleshooting

### Guest seems dumber

Check tool/credential alignment:
1. sandbox.docker.env keys match between agents
2. skills check Ready lists match

### Routing mismatch

Admin conversations using guest sandbox. Check bindings.

### Workspace permissions

Guest workspace must be 1000:1000. See sandbox-permissions.md.
