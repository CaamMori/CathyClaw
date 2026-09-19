# Sandbox Permissions Guide

## Core Rules

1. Container identity must be node (uid 1000)
2. Workspace dirs must be owned by 1000:1000
3. Never use user: root to fix permissions

## Check

### Container identity

```bash
docker exec openclaw-gateway id
# uid=1000(node) gid=1000(node) groups=1000(node),996(docker)
```

### Workspace ownership

```bash
find /data/state/workspace -user root | wc -l
# Should be 0
```

### Write test

```bash
docker exec -u 1000 openclaw-gateway sh -c \
  'touch /workspace/.wtest && rm /workspace/.wtest && echo WRITE_OK'
```

## Common Issues

### EACCES: permission denied

```bash
chown -R 1000:1000 /data/state/workspace
```

### Read works, write fails

```bash
chmod 775 /data/state/workspace
chown -R 1000:1000 /data/state/workspace
```

### user: root contamination

```yaml
# Wrong
services:
  gateway:
    user: root

# Right
services:
  gateway:
    group_add:
      - "996"
```

## Multi-agent workspace

```bash
mkdir -p /data/state/workspace-guest
chown -R 1000:1000 /data/state/workspace-guest
ln -s /data/state/workspace-guest /home/node/.openclaw/workspace-guest
```
