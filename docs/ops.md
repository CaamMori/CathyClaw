# 运维手册

> 本文档对齐生产机真实部署（容器 `openclaw-gateway` + `mihomo-tun` + 浏览器沙箱）。

## 日常检查

```bash
# 完整自检（15 项）
/usr/local/bin/selfcheck.py --full

# 查看 Gateway 日志
docker logs openclaw-gateway --tail 100 -f

# 查看所有容器
docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'

# 探针状态
cat /var/log/mihomo-guard.log | tail -20
```

## 启动补丁机制（关键）

Gateway 容器每次启动都先跑 `/data/opt/openclaw-patches/entrypoint.sh`：

1. **孤儿锁清理**（`lock-cleanup.sh`）：清 `/home/node/.openclaw/agents/*/agent` 下 0 字节孤儿锁 +
   工作区属主校正。必须在 openclaw 进程起来前做，否则索引会永久停更且不报错。
2. **工具调用预算补丁**（`apply-maxtoolcalls-patch.sh`）：幂等注入模块到
   `/app/dist/agent-tool-source-execution-guard-*.mjs`，让 `OPENCLAW_MAX_TOOL_CALLS`
   能上调单轮工具调用预算。目标文件名按 glob 探测（openclaw 每次发版哈希会变化）。

补丁目录：`/data/opt/openclaw-patches/`（宿主持久化，compose 以 `rw` 挂载进容器）。
升级 openclaw 后若预算补丁失效：删除 `/app/dist/agent-tool-source-execution-guard-*.mjs.bak-*`
并让 entrypoint 重新注入即可。

## Cron 矩阵（/etc/cron.d/openclaw-ops）

安装时由 `scripts/install.sh` 一次性写入，重跑即覆盖：

| 周期 | 脚本 | 作用 |
|---|---|---|
| */2 | `pin-sbx-restart.sh` | 沙箱容器重启策略钉死 `unless-stopped` |
| */5 | `openclaw-cfg-guard.py` | 沙箱全功能配置（binds+browser）防漂移 |
| */3 | `ensure-telegram-alive.sh` | TG 轮询保活，僵死则重启网关 |
| */5 | `ensure-browser-alive.sh` | chromium 在位 + 浏览器在跑 |
| */10 | `selfcheck-quick-cron.sh` | 关键项快检（全绿静默，异常推 TG） |
| */2 | `mihomo-guard.sh` | 模型 API 出口守护 + 自动切节点 |
| */5 | `fix-gateway-dns.sh` | gateway resolv.conf 防回滚到污染 DNS |
| */30 | `ensure-skill-bins.sh` | skills CLI（tmux/gh/summarize）自愈 |
| 17 4 * | `nightly-backup.sh` | 全量备份，保留 7 天 |
| 30 4 * | `gen-env-snapshot.sh` | 环境快照 → `memory/ENV-SNAPSHOT.md` |
| 17 */6 | `stale_alert.sh` | 任务停滞看门狗（24h+ 去重告警） |

> mihomo 节点候选与选择器名在 `scripts/ops/mihomo-autoswitch.sh` 顶部用环境变量配置：
> `MIHOMO_CANDIDATE_NODES`（空格分隔）、`MIHOMO_SELECTOR_NAME`（默认 `主代理`）。
> 模型 API 探测地址在 `mihomo-guard.sh` 用 `MODEL_API_PROBE_URL` 配置。

## 任务引擎

任务存储在 `/data/state/workspace/task-engine/`（uid 1000 持有）：

```bash
cd /data/state/workspace/task-engine

# 创建任务（带验收命令）
./taskctl.py create "跑测试" "test -s report.txt" --accept-cmd 'python3 run.py'

# 查看任务列表
./taskctl.py list

# 验收（执行验收命令）；或人工裁决直接通过
./taskctl.py verify <task-id>
./taskctl.py verify <task-id> --accept

# 强制终止（进程组级 kill，不会留孤儿）
./taskctl.py delete --force <task-id>

# 状态看板
./taskboard.py --summary

# 声称-证据审计（防 agent 编造"已验证/已推送"）
./claim_audit.py --file session.jsonl
```

## 备份与恢复

备份默认保留 7 天，位于 `/data/backups/`：

```bash
sudo /usr/local/bin/nightly-backup.sh
ls -lt /data/backups/nightly-*
```

## 升级

```bash
sudo ./scripts/update.sh
# 升级后如预算补丁失效，重启网关让其重新注入：
docker restart openclaw-gateway
```

## 常见问题

- **Gateway 以 root 运行导致沙箱写失败**：compose 里**不要**写 `user: root`，
  镜像自带 `USER node`，docker.sock 权限用 `group_add` 解决（取值 `stat -c '%g' /var/run/docker.sock`）。
- **mihomo 启动后仍无法出海**：`/usr/local/etc/mihomo/config.yaml` 里的代理节点须是真实可用节点；
  模板里的 `192.0.2.1` / `YOUR_UUID_HERE` 是占位符，必须替换。
- **任务 delete 后进程仍在**：确认 `taskctl.py` 用 `os.killpg` 做进程组级终止（已含）。
- **索引停止更新且不报错**：多为 0 字节孤儿锁残留，重启网关由 entrypoint 的 `lock-cleanup.sh` 自动清理。
