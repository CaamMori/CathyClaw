# cakeclaw

基于 OpenClaw 的自托管 AI 运维工程师系统。一个脚本部署，无域名也能跑。

## 快速开始

```bash
git clone https://github.com/CaamMori/CakeClaw.git cakeclaw
cd cakeclaw
sudo ./scripts/install.sh
```

安装过程交互式引导，直接回车即跳过可选项：模型 provider、Telegram 机器人、OpenCode。

## 可选功能

| 功能 | 启用方式 |
|------|----------|
| Codex Responses 修复 | `--with-codex-fix` / `--with-codex-fix-b` |
| Telegram 机器人 | 默认询问 |
| OpenCode 终端代理 | 默认询问 |

非交互部署可用 `.env` 预填环境变量（见 `.env.example`）。

```bash
sudo ./scripts/install.sh --help   # 查看全部选项
```

## 文档

- [安全模型](docs/security.md)
- [部署与排错](docs/deploy-troubleshoot.md)
- [Phase 4 多节点设计](docs/phase4-plan.md)

## License

MIT
