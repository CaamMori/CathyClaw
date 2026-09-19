# Deployment Guide

> 从零到生产的完整部署流程。

## 前置条件

- Linux 服务器（Ubuntu 20.04+ / Debian 11+）
- Docker Engine 24+ with Compose v2
- Node.js 18+ (for OpenClaw CLI)
- mihomo binary (if using TUN proxy)

## 方式一：一键脚本（推荐）

```bash
git clone https://github.com/CaamMori/openclaw-deploy.git
cd openclaw-deploy
bash scripts/quickstart.sh
```

脚本会自动创建目录结构、复制模板、生成安全 token。

## 方式二：手动部署

### Step 1: 目录结构

```bash
mkdir -p /data/{state/workspace,scripts,etc/openclaw,opt,backups}
```

### Step 2: 配置模板

```bash
# Copy templates
cp templates/docker-compose.gateway.yml /data/scripts/
cp templates/openclaw.json /data/state/
cp templates/runtime.env.example /data/etc/openclaw/runtime.env
cp templates/mihomo-config.yaml /data/etc/mihomo/config.yaml

# Set permissions
chmod 600 /data/state/openclaw.json
chmod 600 /data/etc/openclaw/runtime.env
```

### Step 3: 编辑环境变量

```bash
vim /data/etc/openclaw/runtime.env
```

填入：
- `YOUR_ZAI_API_KEY_HERE` → 你的智谱 API key
- `YOUR_TELEGRAM_BOT_TOKEN_HERE` → BotFather 给的 token
- `YOUR_TELEGRAM_USER_ID_HERE` → @userinfobot 查到的 ID
- 其他 YOUR_ 占位符

### Step 4: 编辑 docker-compose

```bash
vim /data/scripts/docker-compose.gateway.yml
```

修改：
- `YOUR_DOCKER_GROUP_ID` → `stat -c '%g' /var/run/docker.sock`
- `YOUR_OPENCLAW_VERSION_HERE` → 当前版本号
- `YOUR_MIHOMO_VERSION_HERE` → mihomo 版本

### Step 5: 启动

```bash
cd /data/scripts
docker compose -f docker-compose.gateway.yml up -d
```

### Step 6: 验证

```bash
openclaw health     # 健康检查
openclaw doctor     # 配置诊断
```

## 常见问题

### Gateway 启动失败

```bash
# 查看日志
docker logs openclaw-gateway --tail 50

# 常见原因：
# 1. runtime.env 有未替换的 YOUR_ 占位符
# 2. docker-compose 里 YOUR_DOCKER_GROUP_ID 未修改
# 3. openclaw.json 权限不对（应该是 600）
```

### 沙箱无法创建

```bash
# 检查 Docker socket 权限
ls -la /var/run/docker.sock
# 应该是 srw-rw---- root docker

# 检查 docker group
stat -c '%g' /var/run/docker.sock
# 记下这个数字，填到 docker-compose 的 group_add
```

### mihomo 无法启动

```bash
# 检查 TUN 设备
ls -la /dev/net/tun

# 检查 mihomo 日志
docker logs mihomo-tun --tail 30
```
