# OpenClaw-CakeClaw

OpenClaw 生产部署套件：一键完成系统加固、HTTPS 入口、容器编排、出海代理、任务引擎与自愈运维。

## 能力一览

| 模块 | 说明 |
|---|---|
| **系统初始化** | Swap、UFW、Docker、Nginx、Certbot、logrotate、cron |
| **Web 入口** | 域名 + HTTPS，或纯 IP + 8080 |
| **Gateway** | OpenClaw 核心服务，桥接网络，资源受限 |
| **mihomo TUN** | 可选 sidecar，为 gateway 提供出海代理（`--with-mihomo`） |
| **任务引擎** |  durable task 调度、心跳、僵死检测、Telegram 通知（`--with-task-engine`） |
| **自愈运维** | mihomo 节点探活、浏览器/telegram 保活、配置备份（`--with-watchdog`） |
| **沙箱** | Docker 沙箱生命周期管理（`--with-sandbox`） |

## 快速开始

```bash
git clone https://github.com/CaamMori/OpenClaw-CakeClaw.git
cd OpenClaw-CakeClaw
sudo ./scripts/install.sh --with-mihomo --with-task-engine --with-watchdog
```

无域名时默认通过 `http://<IP>:8080` 访问控制台。

## 可选功能

| 功能 | 启用方式 |
|---|---|
| Codex Responses 修复 | `--with-codex-fix` / `--with-codex-fix-b` |
| Telegram 机器人 | 默认询问 / `.env` 自动配置 |
| OpenCode 终端代理 | 默认询问 / `OPENCODE_INSTALL=1` |
| mihomo TUN 代理 | `--with-mihomo` / `MIHOMO_ENABLE=1` |
| 任务引擎 | `--with-task-engine` / `TASK_ENGINE_ENABLE=1` |
| recovery-watchdog | `--with-watchdog` / `WATCHDOG_ENABLE=1` |
| 沙箱容器 | `--with-sandbox` / `SANDBOX_ENABLE=1` |

非交互部署可预填 `.env`（见 `.env.example`）。

```bash
sudo ./scripts/install.sh --help
```

## 目录说明

```
.
├── docker-compose.yml      # 主编排文件（含可选 profiles）
├── scripts/
│   ├── install.sh          # 一键安装
│   ├── ops/                # 运维/自愈脚本
│   └── ...
├── task-engine/            # 任务调度与心跳守护
├── templates/              # 配置模板
└── docs/                   # 部署、运维、安全文档
```

## 文档

- [部署指南](docs/deployment.md)
- [运维手册](docs/ops.md)
- [安全模型](docs/security.md)
- [部署排错](docs/deploy-troubleshoot.md)
- [Phase 4 多节点设计](docs/phase4-plan.md)

## License

MIT
