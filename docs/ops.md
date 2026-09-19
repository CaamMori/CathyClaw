# 运维手册

## 日常检查

```bash
# 快速自检
/usr/local/bin/selfcheck.py --full

# 查看 Gateway 日志
docker logs cakeclaw-gateway --tail 100 -f

# 查看所有容器
docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'
```

## Cron 任务

安装完成后，以下任务由脚本自动写入 `/etc/cron.d/`：

| 任务 | 周期 | 脚本 |
|---|---|---|
| mihomo 节点探活 | 每 5 分钟 | `/usr/local/bin/mihomo-guard.sh` |
| Telegram 保活 | 每 3 分钟 | `/usr/local/bin/ensure-telegram-alive.sh` |
| 浏览器保活 | 每 5 分钟 | `/usr/local/bin/ensure-browser.sh` |
| 沙箱重启钉 | 每 2 分钟 | `/usr/local/bin/pin-sbx-restart.sh` |
| 快速自检 | 每 10 分钟 | `/usr/local/bin/selfcheck-quick-cron.sh` |
| 配置备份 | 每天 04:17 | `/usr/local/bin/nightly-backup.sh` |
| 任务僵死告警 | 每天 17:00 | `/usr/local/bin/stale_alert.sh` |

## 任务引擎

任务存储在 `/data/state/task-engine/`。

```bash
# 运行任务
/usr/local/bin/taskctl.py run --label demo -- python3 -c 'print("ok")'

# 查看任务列表
/usr/local/bin/taskctl.py list

# 强制终止
/usr/local/bin/taskctl.py delete --force <task-id>

# 状态看板
/usr/local/bin/taskboard.py --summary
```

## 备份与恢复

备份默认保留 7 天，位于 `/data/backups/`：

```bash
# 手动全量备份
sudo /usr/local/bin/nightly-backup.sh

# 查看备份
ls -lt /data/backups/nightly-*
```

## 升级

```bash
sudo ./scripts/update.sh
```

## 常见问题

- **Gateway 以 root 运行导致沙箱写失败**：检查 `docker-compose.yml` 中 `user: "1000:1000"`
- **mihomo 启动后仍无法出海**：检查 `/data/etc/mihomo/config.yaml` 中代理节点是否真实可用
- **任务 delete 后进程仍在**：确保 `taskctl.py` 版本支持 process-group kill
