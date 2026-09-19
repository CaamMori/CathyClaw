# Backup & Restore Guide

## Auto Backup

### nightly-backup.sh

Daily at 04:17, keeps 7:

```bash
cp scripts/nightly-backup.sh /usr/local/bin/
chmod +x /usr/local/bin/nightly-backup.sh
echo "17 4 * * * root /usr/local/bin/nightly-backup.sh" > /etc/cron.d/nightly-backup
```

### Backup location

```
/data/backups/nightly-YYYYMMDD-HHMMSS/
├── openclaw.json
├── runtime.env
├── docker-compose.gateway.yml
├── mihomo-config.yaml
└── workspace.tar.gz
```

## Manual Backup

```bash
tar czf /data/backups/manual-$(date +%Y%m%d).tar.gz       /data/state /data/etc /data/scripts
```

## Restore

### Restore configs

```bash
cp /data/backups/nightly-*/openclaw.json /data/state/
cp /data/backups/nightly-*/runtime.env /data/etc/openclaw/
cp /data/backups/nightly-*/docker-compose.gateway.yml /data/scripts/
chmod 600 /data/state/openclaw.json /data/etc/openclaw/runtime.env
cd /data/scripts && docker compose -f docker-compose.gateway.yml up -d
```

### Restore workspace

```bash
tar xzf /data/backups/nightly-*/workspace.tar.gz -C /data/state/workspace/
chown -R 1000:1000 /data/state/workspace
```

## Verify Backup

```bash
ls -la /data/backups/nightly-* | head -7
tar tzf /data/backups/nightly-*/workspace.tar.gz | head -20
```
