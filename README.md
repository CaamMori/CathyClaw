# CathyClaw

OpenClaw 生产部署套件：一键完成系统加固、HTTPS 入口、容器编排、出海代理、任务引擎与自愈运维。

## 能力一览

| 模块 | 说明 |
|---|---|
| **系统初始化** | Swap、UFW、Docker、Nginx、Certbot、logrotate、cron |
| **Web 入口** | 域名 + HTTPS，或纯 IP + 8080 |
| **Gateway** | OpenClaw 核心服务，桥接网络，资源受限 |
| **mihomo TUN** | 出海代理 sidecar。**境内机自动启用**，海外机直连跳过（`--with-mihomo` / `--without-mihomo` 可强制） |
| **任务引擎** | durable task 调度、心跳、僵死检测、Telegram 通知（`--with-task-engine`） |
| **自愈运维** | 13 条 cron 矩阵：沙箱重启钉死、配置防漂移、TG/浏览器保活、10 分钟快检、DNS 防回滚、每夜备份、任务停滞告警、幻觉提交审计 |
| **沙箱** | Docker 沙箱生命周期管理（`--with-sandbox`） |

## 快速开始

```bash
git clone https://github.com/CaamMori/CathyClaw.git
cd CathyClaw
sudo ./scripts/install.sh --with-task-engine
```

无域名时默认通过 `http://<IP>:8080` 访问控制台。

> **境内/海外无需手动选择**：安装脚本会以 6 秒超时探测 GitHub 直连，
> 通则判定为海外机（直连即出口，跳过 mihomo），不通则判定为境内机并自动启用 mihomo。
> 想强制覆盖时再用 `--with-mihomo` / `--without-mihomo`。

## 可选功能

| 功能 | 启用方式 | 默认 |
|---|---|---|
| Telegram 机器人 | 默认询问 / `.env` 自动配置 | 询问 |
| mihomo TUN 代理 | **自动判定**（境内启用）；覆盖用 `--with-mihomo` / `MIHOMO_ENABLE=1` | 自动 |
| 任务引擎 | `--with-task-engine` / `TASK_ENGINE_ENABLE=1` | 关 |
| 沙箱容器 | `--with-sandbox` / `SANDBOX_ENABLE=1` | 关 |

非交互部署可预填 `.env`（见 `.env.example`）。

```bash
sudo ./scripts/install.sh --help
```

## 备份与还原

安装后自动排期，无需手工配置：

| 组件 | 排期 | 作用 |
|---|---|---|
| `nightly-backup.sh` | 每日 04:17 | 打包 `/data/state`、`/data/etc/openclaw` 等关键状态，生成 `.sha256`，保留 7 份 |
| `backup-verify.sh` | 每周日 05:30 | **只读校验**最新备份：可解压、校验和匹配、含核心配置、未过期；异常推 Telegram |
| `openclaw-restore.sh` | 手动执行 | 从归档还原，含校验、还原前快照、权限修复、服务重启与健康确认 |

```bash
sudo openclaw-restore.sh --list              # 列出可用备份（含大小/时间/校验状态）
sudo openclaw-restore.sh --dry-run <备份>    # 只校验与预演，不落盘
sudo openclaw-restore.sh                     # 交互式选择并还原
```

设计要点：**备份存在 ≠ 备份可用**。所以除了日备，还有每周的可用性校验；还原前会先存一份
当前状态快照，校验和不过直接拒绝还原——宁可不动，也不要把系统解包成半毁状态。

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

- [部署设计思路](docs/deploy-design.md)
- [部署指南](docs/deployment.md)
- [运维手册](docs/ops.md)
- [安全模型](docs/security.md)

## License

MIT
