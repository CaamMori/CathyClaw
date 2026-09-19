# OpenClaw-CakeClaw

基于 [CakeClaw](https://github.com/CaamMori/CakeClaw) 与 [openclaw-deploy](https://github.com/CaamMori/openclaw-deploy) 整合的 OpenClaw 生产部署方案。

保留 CakeClaw 的"一键系统初始化 + Web 入口"能力，同时引入 openclaw-deploy 的 **mihomo TUN 代理**、**任务引擎**、**自愈运维脚本** 与 **多 Agent 配置经验**。

## 快速开始

```bash
git clone https://github.com/CaamMori/OpenClaw-CakeClaw.git
cd OpenClaw-CakeClaw
sudo ./scripts/install.sh --with-mihomo --with-task-engine --with-watchdog --with-sandbox
```

无域名也能跑，默认通过 `http://<IP>:8080` 访问控制台。

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

## 文档

- [整合说明](docs/integration.md)
- [安全模型](docs/security.md)
- [部署与排错](docs/deploy-troubleshoot.md)
- [踩坑记录](docs/openclaw-deploy/gotchas.md)
- [运维手册](docs/openclaw-deploy/operations.md)
- [Phase 4 多节点设计](docs/phase4-plan.md)

## License

MIT
