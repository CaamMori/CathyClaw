# CakeClaw + openclaw-deploy 整合说明

本仓库把 [CakeClaw](https://github.com/CaamMori/CakeClaw) 的"一键系统初始化 + Web 入口"能力与 [openclaw-deploy](https://github.com/CaamMori/openclaw-deploy) 的"mihomo TUN 代理 + 任务引擎 + 自愈运维"能力合并为一个更完整的 OpenClaw 生产部署方案。

## 整合原则

| 层面 | CakeClaw 提供 | openclaw-deploy 提供 |
|---|---|---|
| 系统初始化 | UFW、Swap、Docker、Nginx、Certbot、logrotate | — |
| Gateway 部署 | OpenClaw 镜像、健康检查、资源限制 | `entrypoint.sh` 锁清理、`user: 1000` |
| 外部入口 | Nginx 反代（HTTP/8080 或 HTTPS/443） | — |
| 出海代理 | — | mihomo TUN sidecar（可选 profile） |
| Telegram | bot token 独立文件、allowlist | 任务引擎告警 `TE_ALERT_TARGET` |
| 任务管理 | — | taskctl.py + taskboard + stale_guard |
| 运维自愈 | watchdog/trends/cert-check/audit cron | selfcheck、mihomo-guard、ensure-browser、recovery-watchdog |

## 目录变化

- `docker-compose.yml`：融合后的 Compose，gateway 默认 bridge + Nginx，可选 `mihomo-tun` / `recovery-watchdog` profiles。
- `scripts/openclaw-deploy/`：从 openclaw-deploy 引入的运维脚本。
- `task-engine/`：任务引擎源码。
- `templates/openclaw.json`：融合 CakeClaw 网关配置与 openclaw-deploy 的 Telegram/多 Agent/模型模板。
- `templates/openclaw-deploy/mihomo-config.yaml`：mihomo 代理模板。

## 快速开始

```bash
git clone https://github.com/CaamMori/OpenClaw-CakeClaw.git
cd OpenClaw-CakeClaw
sudo ./scripts/install.sh --with-mihomo --with-task-engine --with-watchdog --with-sandbox
```

## 可选开关

| 开关 | 含义 |
|---|---|
| `--with-mihomo` | 启用 mihomo TUN sidecar，自动配置代理切换 cron |
| `--with-task-engine` | 安装任务引擎到 `/data/state/workspace/task-engine` |
| `--with-watchdog` | 启用 recovery-watchdog 容器 |
| `--with-sandbox` | 挂载 docker.sock，允许 OpenClaw 创建沙箱容器 |

也可通过 `.env` 启用：

```env
MIHOMO_ENABLE=1
TASK_ENGINE_ENABLE=1
WATCHDOG_ENABLE=1
SANDBOX_ENABLE=1
```

## 网络架构

```
用户 ──► Nginx (80/443/8080) ──► cakeclaw-gateway (bridge, 127.0.0.1:18789)
                                    │
                                    ├── 可选 mihomo-tun (service network)
                                    │       └── TUN 接管 gateway 容器出站流量
                                    └── 可选 recovery-watchdog (host network)
```

## 路径统一

- `/data/state`：Gateway 状态、openclaw.json
- `/data/state/workspace`：工作区（`/data/workspace` 是其软链）
- `/data/etc/openclaw`：运行时配置、Telegram token、docker-compose
- `/data/etc/mihomo`：mihomo 配置
- `/data/backups`：备份目录

## 注意事项

1. `docker.sock` 挂载会提升 Gateway 权限，仅在需要沙箱功能时启用。
2. mihomo TUN 只影响 gateway 容器 netns，不影响宿主机其他流量。
3. 任务引擎告警目标通过 `TE_ALERT_TARGET` 注入，不再硬编码。
