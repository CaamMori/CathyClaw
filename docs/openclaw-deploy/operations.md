# Operations Guide - Daily Maintenance

## Health Monitoring

### Automated Checks (host cron)

| Interval | Script | Purpose |
|---|---|---|
| */2 min | pin-sbx-restart.sh | Sandbox restart policy drift prevention |
| */2 min | mihomo-guard.sh | Probe model API, auto-switch node, TG alert if all dead 6min |
| */3 min | ensure-telegram-alive.sh | Telegram polling keepalive |
| */5 min | ensure-browser.sh | Chromium presence + bundle self-heal |
| */10 min | selfcheck-quick-cron.sh | Quick check (silent if green, alert if abnormal) |
| 04:17 daily | nightly-backup.sh | Full config backup, keep 7 |
| 17 */6 * * * | stale_alert.sh | Task stale guard (24h+ alert, deduplicated) |

> 注：`openclaw-cfg-guard.py`、`fix-gateway-dns.sh`、`ensure-skill-bins.sh`、`gen-env-snapshot.sh` 当前仓库尚未提供，部署前请确认文件存在或从其他来源补齐。

### Systemd Services

| Service | Purpose |
|---|---|
| ocwatch | 60s health monitoring, TG alerts |
| openclaw-recovery-watchdog | Gateway liveness watchdog (15s) |
| te-daemon | Task engine daemon |
| taskboard | Web dashboard (http://172.16.0.90:8080/board/) |

## Configuration Changes

### Model config (hot-reload, no restart)

```bash
vim /data/state/openclaw.json
openclaw config validate
docker logs -f openclaw-gateway | grep "config hot reload applied"
openclaw config get
```

### Gateway restart (last resort, breaks mihomo netns)

```bash
cd /data/scripts
docker compose -f docker-compose.gateway.yml up -d --force-recreate openclaw-gateway
docker compose -f docker-compose.gateway.yml up -d --force-recreate mihomo-tun
docker restart $(docker ps -q --filter "name=openclaw-sbx")
```

## Backup and Restore

```bash
# Manual backup
tar czf /data/backups/manual-$(date +%Y%m%d).tar.gz /data/state /data/etc /data/scripts

# Restore config
cp /data/backups/nightly-*/openclaw.json /data/state/

# Restore workspace
cp -a /data/backups/nightly-*/workspace/* /data/state/workspace/
```

## Key Metrics

- Self-check: 22/22 green
- Cache hit rate: target >70%
- Zombie count: should be 0
- PIDs: keep >200 headroom
- Disk: keep >20% free
