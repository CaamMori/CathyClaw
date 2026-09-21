# CathyClaw

OpenClaw 生产部署套件。覆盖容器编排、出海代理、任务调度和日常运维,目标是一台裸机跑起来之后不用再管。

## 安装

```bash
git clone https://github.com/CaamMori/CathyClaw.git
cd CathyClaw
sudo ./scripts/install.sh
```

没有域名时通过 `http://<IP>:8080` 访问。有域名加 `--domain example.com` 走 HTTPS。

脚本会自动探测机器在境内还是海外:能直连 GitHub 就判定海外(跳过代理),否则自动启用 mihomo TUN。想手动控制用 `--with-mihomo` / `--without-mihomo`。

## 功能模块

| 模块 | 说明 | 默认 |
|------|------|------|
| Gateway | OpenClaw 核心服务,桥接网络 | 开 |
| mihomo TUN | 出海代理 sidecar,共享 Gateway 网络命名空间 | 境内自动开 |
| Telegram | 接入 Telegram Bot,交互式对话 | 可选 |
| Task Engine | 后台任务调度、心跳、僵死检测 | 可选 |
| Sandbox | Docker 沙箱,隔离 agent 执行环境 | 可选 |

全部可通过命令行 flag 或 `.env` 变量控制。非交互部署见 `.env.example`。

## 运维

安装后自动配置以下运维能力,无需手动排期:

| 能力 | 频率 | 作用 |
|------|------|------|
| 快检 | 10 分钟 | 12 项核心指标巡检,全绿静默,异常推 Telegram |
| 配置防漂移 | 5 分钟 | 沙箱 bind、browser 配置漂移时自动修复 |
| 代理守护 | 2 分钟 | 模型 API 出口不可用时自动切节点 |
| Telegram 保活 | 3 分钟 | 轮询僵死时重启 |
| 夜间备份 | 每日 04:17 | 打包关键状态,生成 sha256,保留 7 份 |
| 每日摘要 | 每日 08:00 | 读取既有状态,推送一次健康概要 |

备份还原:

```bash
openclaw-restore.sh --list              # 列出可用备份
openclaw-restore.sh --dry-run <备份>    # 校验不落盘
openclaw-restore.sh                     # 交互还原
```

## 目录结构

```
├── docker-compose.yml          # 主编排文件(模板)
├── scripts/
│   ├── install.sh              # 一键安装
│   └── ops/                    # 运维脚本(27 个)
├── openclaw-patches/           # 启动时幂等注入的补丁
├── templates/                  # 配置模板(compose、AGENTS、Skill、cron)
├── task-engine/                # 任务调度与心跳守护
└── docs/                       # 部署、运维、安全文档
```

## 文档

- [部署设计](docs/deploy-design.md)
- [运维手册](docs/ops.md)
- [安全模型](docs/security.md)

## License

MIT
