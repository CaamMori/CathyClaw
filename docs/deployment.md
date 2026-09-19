# 部署指南

## 环境要求

- Ubuntu 22.04/24.04 LTS（推荐）
-  root 或 sudo 权限
-  至少 2GB RAM，建议 4GB+
-  可选：一个域名并解析到本机

## 最小安装

```bash
git clone https://github.com/CaamMori/OpenClaw-CakeClaw.git
cd OpenClaw-CakeClaw
sudo ./scripts/install.sh
```

无域名时通过 `http://<IP>:8080` 访问；有域名时自动申请 HTTPS 证书。

## 启用完整能力

```bash
sudo ./scripts/install.sh \
  --with-mihomo \
  --with-task-engine \
  --with-sandbox
```

| 开关 | 说明 |
|---|---|
| `--with-mihomo` | mihomo TUN sidecar，为 gateway 提供出海代理 |
| `--with-task-engine` | durable task 引擎 + stale 检测 |
| `--with-sandbox` | 挂载 docker.sock，允许 gateway 管理沙箱容器 |

## 非交互部署

复制 `.env.example` 为 `.env` 并填写，然后执行：

```bash
sudo ./scripts/install.sh
```

安装脚本优先读取 `.env`，未配置项再交互询问。

## 安装后检查

```bash
docker ps
docker logs openclaw-gateway --tail 50
/usr/local/bin/selfcheck.py --full
```
