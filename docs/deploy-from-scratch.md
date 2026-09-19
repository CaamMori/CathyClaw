# 从零部署方法论（OpenClaw 一键部署原理）

> 本仓库的 `scripts/install.sh` 已经把下文**全部步骤自动化**。本文档是**原理与手动兜底参考**——
> 当你想理解「为什么这么部署」、或在没有 `install.sh` 的受限环境里手工搭建时，按本手册顺序执行即可。
> 每一步都带「最小验证」，任一步失败即停，禁止跳过或盲目重试。
>
> 来源：CakeClaw 早期《OpenClaw 一键部署手册 v2.2》中**被验证有效**的部分（Greenfield 部署思路）。
> 与本项目不一致或过时的内容（Phase 4 多节点、OpenCode Worker、CakeClaw 旧监控栈）已剔除，见文末附录。

---

## 0. 定位与核心原则

在单机 VPS（Debian / Ubuntu）上部署一个**长期运行**的私人 AI DevOps Agent 平台：

- **OpenClaw** 负责总控调度与推理
- **任务引擎**（`task-engine/`）负责持久化任务、验收与停滞看门狗
- **运维 cron 矩阵**（`scripts/ops/` + `/etc/cron.d/openclaw-ops`）负责自愈
- **mihomo TUN sidecar**（可选）为 Gateway 自身出海提供代理，不暴露在公网

最终状态：Agent 可管理服务器、维护代码、修复 CI、调度任务、记录知识、自主巡检并规范汇报。
目标是**私人 AI DevOps 平台，不是聊天机器人**。

**核心原则（必须遵守）**：

- Gateway **永远只监听 `127.0.0.1`**（对外经 Nginx HTTPS 或 SSH 隧道）；
- 所有密钥**仅 root 可读（权限 `0600`）**；
- 插件**白名单制**，禁止默认全开；
- **固定版本镜像部署**，禁止使用 `latest`；
- 不可逆操作（删数据、改 SSH / 防火墙、force push、开放公网端口）**必须人工确认**；
- 部署完成只在最终汇报中给凭证**文件路径**，**禁止输出 Token 明文**；
- 任一步失败 → 立即【Status】汇报错误并停止，禁止跳过或盲目重试。

### 0.1 全局失败处理规则

每完成一步必须执行该步的「最小验证」，通过才进入下一步。验证失败或命令报错 →
立即输出错误摘要与相关日志前 30～50 行，然后停止。禁止自动跳过失败步骤。
涉及删除数据、改 SSH 端口、改防火墙、force push、生产发布等 → 先说明影响并等待确认。
容器反复重启 → 先停非必要服务并看日志，不允许无脑重试把宿主机打死。

---

## 1. 部署前准备

### 1.1 管理员必须提前准备的材料

| 材料 | 说明 |
|---|---|
| 域名 | 已解析到本机公网 IP 的域名（可选；无域名走 8080 明文或隧道） |
| 模型 API Key | Anthropic / OpenAI / Google / Grok 等对应 Key |
| Gateway 镜像 Tag | **固定版本**，禁止 `latest` |
| 服务器 root 权限 | 能 `sudo` 或直接 root 登录 |
| （可选）Telegram Bot Token | 用于告警推送 |

> 国内服务器拉 `ghcr.io` 可能很慢或失败，可改用 Docker Hub 镜像 `openclaw/openclaw:<tag>` 或配置镜像加速。

### 1.2 变量表（管理员填写后交给部署流程）

| 变量 | 说明 | 示例 / 默认 |
|---|---|---|
| `${DOMAIN}` | 控制台域名（必须已解析；无域名留空） | `agent.example.com` |
| `${SERVER_IP}` | 服务器公网 IP | `YOUR_SERVER_IP` |
| `${SSH_PORT}` | SSH 端口 | `22`（建议改非默认） |
| `${MODEL_PROVIDER}` | 主模型提供商 | `anthropic` / `openai` / `google` / `grok` |
| `${PRIMARY_MODEL}` | 日常主力模型 | `claude-sonnet-4-*` 等 |
| `${FAST_MODEL}` | 轻量快速模型 | 巡检 / 状态类 |
| `${DEEP_MODEL}` | 深度 / 复杂任务模型 | 架构 / 排查类 |
| `${FALLBACK_MODEL}` | 回退模型（可选） | 可留空 |
| `${ANTHROPIC_API_KEY}` … | 各厂商 Key（按需） | `YOUR_API_KEY` |
| `${OPENCLAW_GATEWAY_TOKEN}` | 控制台 Token（留空则自动生成） | `openssl rand -hex 32` |
| `${GATEWAY_IMAGE}` | 固定版本镜像 | `openclaw/openclaw:YOUR_TAG` |
| `${TELEGRAM_BOT_TOKEN}` | Telegram Bot（可选） | 可留空 |
| `${BACKUP_RETENTION_DAYS}` | 备份保留天数 | `7` |
| `${CONN_LIMIT}` | Nginx 单 IP 连接限制 | `15` |
| `${SWAP_SIZE}` | 目标 Swap（先按 §2 计算） | `2G` / `4G` |
| `${GATEWAY_MEM_LIMIT}` | Gateway 内存上限（先计算） | `2.2g` |
| `${GATEWAY_CPU_LIMIT}` | Gateway CPU 上限（先计算） | `1.5` |
| `${GATEWAY_PID_LIMIT}` | Gateway PID 上限（先计算） | `1024` |

任何一项不满足 → 先停下汇报缺口，不得继续盲跑。

### 1.3 前置条件勾选清单

- [ ] 域名已解析到本机：`dig +short ${DOMAIN}` 必须包含 `${SERVER_IP}`（无域名则跳过）
- [ ] Docker 已安装：`docker --version && docker compose version`
- [ ] 镜像已可拉取：`docker pull ${GATEWAY_IMAGE}`
- [ ] 对应模型 API Key 已填好；缺任一项就停止
- [ ] `SSH_PORT` 可远程登录且 ufw 未误封当前会话

---

## 2. 按规格选档位并落地数字

以 `free -g` 实测总内存为主要依据，**禁止用云厂商宣传值**。

```
TOTAL_RAM_GB=$(free -g | awk '/Mem:/ {print $2}')
TOTAL_VCPU=$(nproc)
SWAP_SIZE = max(2G, 总内存)
GATEWAY_MEM_LIMIT = 总内存 × 0.55～0.60
GATEWAY_CPU_LIMIT = min(总vCPU, 总vCPU - 0.5)
GATEWAY_PID_LIMIT = 512 + 256 × floor(总内存GB / 2)
```

| 档位 | 总内存 | Swap | Gateway 内存 | CPU 上限 | PID 上限 | 并行任务 |
|---|---|---|---|---|---|---|
| 微型 | ≤2 GB | max(2G,总) | 总×50–60% | min(vCPU,1.5) | 512–768 | 1 |
| 小型 | 2–4 GB | 2 GB | 总×55–65% | min(vCPU,2) | 768–1024 | 2 |
| 中型 | 4–8 GB | 2–4 GB | 总×50–60% | min(vCPU,3) | 1024–1536 | 3–4 |
| 大型 | ≥8 GB | 4 GB 起 | 压测调整 | 压测调整 | 压测调整 | 视负载 |

完成 §2 后必须在汇报中明确写出最终档位与 `SWAP_SIZE / GATEWAY_MEM_LIMIT / GATEWAY_CPU_LIMIT / GATEWAY_PID_LIMIT` 数值。

---

## 3. 一键部署执行顺序（严格按序号，每步必须验证）

### 3.1 系统加固（Swap + 防火墙）

```bash
SW_AVAIL=$(free -g | awk '/Swap:/ {print $2}')
if [ "${SW_AVAIL:-0}" -lt 1 ]; then
  fallocate -l ${SWAP_SIZE} /swapfile
  chmod 600 /swapfile && mkswap /swapfile && swapon /swapfile
  grep -q '/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
fi
# 防火墙：先放行业务端口再 enable，防止把自己锁在外面
ufw default deny incoming
ufw default allow outgoing
ufw allow ${SSH_PORT}/tcp comment 'SSH'
ufw allow 443/tcp comment 'HTTPS'
ufw allow 80/tcp  comment 'HTTP-for-certbot'
ufw allow 8080/tcp comment 'Gateway-HTTP'   # 仅无域名明文访问时使用
ufw --force enable
```

**最小验证**：`swapon --show` / `ufw status numbered` / `ss -ltnp | grep -E ':22|:443|:80|:8080'`

> 注意：本仓库 `install.sh` 对**已有 ufw 规则采取保守策略**——不会 `ufw --force reset` 清空用户既有规则，
> 只在未放行时增量添加，避免误伤生产机现有防火墙。

### 3.2 创建 /data 目录结构与权限

```bash
mkdir -p /data/{state,workspace,backups/{openclaw-state,nightly},logs,gateway-config,\
scripts,etc/openclaw,etc/mihomo,var/lib/openclaw}
chmod 700 /data/backups /data/state /data/etc/openclaw /data/var/lib/openclaw
chmod 755 /data/workspace /data/logs /data/scripts
chown -R root:root /data
```

**最小验证**：`ls -ld /data/state /data/backups /data/etc/openclaw` 权限正确。

### 3.3 安装基础依赖（Docker / Nginx / Certbot / Node）

```bash
# Docker（未装时）
if ! command -v docker >/dev/null 2>&1; then
  apt-get update && apt-get install -y ca-certificates curl gnupg
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] \
    https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
    > /etc/apt/sources.list.d/docker.list
  apt-get update && apt-get install -y docker-ce docker-ce-cli containerd.io \
    docker-buildx-plugin docker-compose-plugin
  systemctl enable --now docker
fi
# Nginx + Certbot（有域名时）
apt-get install -y nginx certbot python3-certbot-nginx
systemctl enable --now nginx
```

**最小验证**：`docker --version && docker compose version && nginx -v`

### 3.4 写入运行时密钥并生成 Gateway Token

Token 明文只允许存在于下列文件，**禁止输出到聊天 / 日志 / 知识库**。

```bash
[ -z "${OPENCLAW_GATEWAY_TOKEN}" ] && OPENCLAW_GATEWAY_TOKEN=$(openssl rand -hex 32)
cat > /data/etc/openclaw/runtime.env << EOF
MODEL_PROVIDER=${MODEL_PROVIDER}
PRIMARY_MODEL=${PRIMARY_MODEL}
FAST_MODEL=${FAST_MODEL}
DEEP_MODEL=${DEEP_MODEL}
FALLBACK_MODEL=${FALLBACK_MODEL}
ANTHROPIC_API_KEY=${ANTHROPIC_API_KEY}
OPENAI_API_KEY=${OPENAI_API_KEY}
GOOGLE_API_KEY=${GOOGLE_API_KEY}
GROK_API_KEY=${GROK_API_KEY}
OPENCLAW_GATEWAY_TOKEN=${OPENCLAW_GATEWAY_TOKEN}
TELEGRAM_BOT_TOKEN=${TELEGRAM_BOT_TOKEN}
EOF
chmod 600 /data/etc/openclaw/runtime.env
cat > /root/openclaw-credentials.txt << EOF
OpenClaw 部署凭证摘要
Gateway Token 文件: /data/etc/openclaw/runtime.env （变量 OPENCLAW_GATEWAY_TOKEN）
读取命令: grep OPENCLAW_GATEWAY_TOKEN /data/etc/openclaw/runtime.env
控制台地址: ${DOMAIN:+(有域名) https://${DOMAIN} / }(无域名) SSH 隧道 http://127.0.0.1:${GATEWAY_PORT}/
EOF
chmod 600 /root/openclaw-credentials.txt
```

**最小验证**：两个文件存在且权限 `-rw------- (600)`；对应 provider 的 API Key 非空。

### 3.5 部署 Gateway 容器

官方镜像容器内监听端口为 **18789**，宿主机用 `127.0.0.1:${GATEWAY_PORT}` 映射（默认 `18789`）。

```bash
docker pull ${GATEWAY_IMAGE}
cat > /data/scripts/docker-compose.gateway.yml << EOF
services:
  openclaw-gateway:
    image: ${GATEWAY_IMAGE}
    container_name: openclaw-gateway
    restart: unless-stopped
    ports:
      - "127.0.0.1:${GATEWAY_PORT}:18789"
    volumes:
      - /data/workspace:/data/workspace
      - /data/state:/home/node/.openclaw
    env_file:
      - /data/etc/openclaw/runtime.env
    environment:
      - HOME=/home/node
    deploy:
      resources:
        limits:
          memory: ${GATEWAY_MEM_LIMIT}
          cpus: "${GATEWAY_CPU_LIMIT}"
          pids: ${GATEWAY_PID_LIMIT}
    healthcheck:
      test: ["CMD-SHELL", "curl -fsS http://127.0.0.1:18789/ >/dev/null || node dist/docker-healthcheck.js"]
      interval: 30s
      timeout: 10s
      retries: 5
      start_period: 300s
    logging:
      driver: json-file
      options: { max-size: "50m", max-file: "3" }
EOF
cd /data/scripts && docker compose -f docker-compose.gateway.yml up -d
sleep 20 && docker ps --filter name=openclaw-gateway
```

**最小验证**：`docker ps --filter name=openclaw-gateway --format '{{.Status}}'` 含 `healthy`；
`curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:${GATEWAY_PORT}/health`

> 关键：容器**不要写 `user: root`**——镜像自带 `USER node`，docker.sock 权限用 `group_add`（docker gid）最小授权，
> 否则沙箱写入会因属主不符而失败。

### 3.6 Nginx 反向代理（HTTPS + WebSocket，或仅 8080）

有域名时申请证书并反代 443→127.0.0.1:18789（含 WebSocket Upgrade）；
无域名时仅监听 `8080` 明文（建议配合 SSH 隧道，不要长期公网暴露）。

```bash
cat > /etc/nginx/conf.d/openclaw_limit.conf << 'EOF'
map $http_upgrade $connection_upgrade { default upgrade; '' close; }
limit_conn_zone $binary_remote_addr zone=openclaw_connection_limit:10m;
EOF
```

有域名：

```bash
cat > /etc/nginx/sites-available/openclaw << EOF
server { listen 80; server_name ${DOMAIN}; location / { return 301 https://\$host\$request_uri; } }
server {
  listen 443 ssl http2; server_name ${DOMAIN};
  ssl_certificate     /etc/letsencrypt/live/${DOMAIN}/fullchain.pem;
  ssl_certificate_key /etc/letsencrypt/live/${DOMAIN}/privkey.pem;
  ssl_protocols       TLSv1.2 TLSv1.3;
  location / {
    proxy_pass http://127.0.0.1:${GATEWAY_PORT};
    proxy_http_version 1.1;
    proxy_set_header Upgrade \$http_upgrade;
    proxy_set_header Connection \$connection_upgrade;
    proxy_set_header Host \$host;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto \$scheme;
    proxy_read_timeout 86400;
    limit_conn openclaw_connection_limit ${CONN_LIMIT};
  }
}
EOF
ln -sf /etc/nginx/sites-available/openclaw /etc/nginx/sites-enabled/openclaw
rm -f /etc/nginx/sites-enabled/default
certbot --nginx -d ${DOMAIN} --non-interactive --agree-tos -m admin@${DOMAIN}
nginx -t && systemctl reload nginx
```

**最小验证**：`nginx -t`；`curl -I https://${DOMAIN}` 返回 `200`；`ss -ltnp | grep -E ':443|:80|:8080'`

### 3.7 模型供应商与路由（openclaw.json）

模型配置写在 `/data/state/openclaw.json` 的 `models.providers` 与 `agents.defaults.model`，
首次安装由模板 `templates/openclaw.json` 渲染（模型名用 `${PRIMARY_MODEL}` 等占位符，providers 留空待填）。

- **只开白名单 provider**：按实际可用 Key 仅配置一个主 provider，禁止默认全开。
- **三级路由**：`FAST_MODEL`（巡检/状态）/ `PRIMARY_MODEL`（日常）/ `DEEP_MODEL`（架构/排查），
  在 `agents.defaults` 与 `fallbacks` 中体现。
- 具体键名以所用 OpenClaw 版本文档为准。

### 3.8 写入 Agent 自知识体系（`templates/agent/`）

> ⚠️ 早期手册里那套简短的 SOUL/AGENTS 样例**已废弃**——那是初版草稿。
> 本项目采用**生产机现役版本**（`templates/agent/`），是长期演进后的成熟体系，
> 与生产机 `agents/entries/main` 配置保持一致。以下为真实结构：

| 文件 | 作用 | 加载时机 |
|---|---|---|
| `SOUL.md` | 人格底色（有主见、不客套、尊重隐私边界） | 每会话 |
| `IDENTITY.md` | 身份标识（名字 / emoji / 服务对象），与 `openclaw.json` 的 `identity.emoji` 对齐 | 每会话 |
| `USER.md` | 用户模型（所有者身份、权限来源、交互偏好） | 每会话 |
| `AGENTS.md` | **硬不变量**：证据分级（A/B/C）、破坏性操作确认、失败分类、防空转、自身组件红线 | **每轮必读** |
| `SELF.md` | 自我部署说明书：架构、守护矩阵、已知故障模式、诚实边界、排障速查 | 运维/排障时 |
| `AGENT-ROADMAP.md` | 能力演进路线与进度（半可信） | 需要时 |
| `runbooks/*.md` | 分领域手册：数据完整性、交付验收、exec 安全、穷尽渠道、自供给、任务引擎 | 按需 |

**`AGENTS.md` 的核心设计（务必保留）**：

- **证据分级**：A 级（外部实时查询 `git ls-remote` / `curl` / `ssh` / API）才能证明「已推送 / 已部署」；
  B 级（本地 `git status`、缓存指针）只能证明「我做了什么」；C 级（记忆与推断）不得作为结论依据。
  **禁止把 B 级当 A 级用**。
- **破坏性操作先问**：删数据、清容器、改防火墙、重建 gateway、改 `openclaw.json` 权限/模型/凭据。
- **失败先分类**：结构性拒绝（原样重试结果不变）→ 立刻换手段；临时性 → 可重试，均上限 2 次。
- **绝不空转**：同一动作重复 ≥3 次且状态无变化 = 死循环，立即停并报告。
- **自身组件红线**：禁止对 `openclaw-gateway` / sidecar 容器执行 stop/rm/kill/restart。
- **别在本文件堆细节**：AGENTS 每轮都进上下文，堆细节会稀释关键规则的注意力——细节放 `runbooks/`。

**脱敏说明**：模板里的 `${AGENT_NAME}` / `${OWNER_NAME}` / `${OWNER_TELEGRAM_ID}` / `${SERVER_IP}` 等
占位符由 `install.sh` 第 8 节渲染为实际值。**请勿把真实个人数据提交回仓库。**

### 3.9 备份脚本（nightly-backup）

由 `scripts/ops/nightly-backup.sh` 提供，默认每天 `17 4 *` 全量备份 `/data/state`/`/data/etc`/`/data/workspace`，
保留 `${BACKUP_RETENTION_DAYS}`（默认 7）天，落到 `/data/backups/nightly-*`。

```bash
sudo /usr/local/bin/nightly-backup.sh
ls -lt /data/backups/nightly-*
```

### 3.10 健康巡检（selfcheck.py）

由 `scripts/ops/selfcheck.py`（安装到 `/usr/local/bin/selfcheck.py`）提供，含 `*/10` 关键项快检 cron。

```bash
/usr/local/bin/selfcheck.py --full      # 完整自检
/usr/local/bin/selfcheck.py             # 关键项快检（异常推 TG）
```

### 3.11 部署完成凭证交付（必须执行）

全部步骤成功后，最终汇报必须包含：

- 凭证摘要文件：`/root/openclaw-credentials.txt`
- 运行时环境文件：`/data/etc/openclaw/runtime.env`
- 读取 Token 命令：`grep OPENCLAW_GATEWAY_TOKEN /data/etc/openclaw/runtime.env`
- 控制台地址：有域名 `https://${DOMAIN}` / 无域名 `SSH 隧道 http://127.0.0.1:${GATEWAY_PORT}/`
- 最终档位与资源限制：`SWAP_SIZE / GATEWAY_MEM_LIMIT / GATEWAY_CPU_LIMIT / GATEWAY_PID_LIMIT`

**禁止在聊天中输出 Token 明文。**

### 3.12 失败后怎么办

- 任何一步失败 → 立即停止，保留日志，用【Status】汇报，不得盲目重试。
- certbot 失败 → 先查 `dig +short ${DOMAIN}` 是否指向 `${SERVER_IP}`，再查 80/443 是否被占用。
- 容器反复重启 → 先看 `docker logs --tail 50 openclaw-gateway`，排查 API Key、端口冲突、state 路径。
- 内存不足 → 先停非必要服务再继续；不允许无脑重试把宿主机打死。

---

## 4. 部署后验证清单（必须全部通过）

- [ ] `docker compose version` / `docker pull ${GATEWAY_IMAGE}` / `docker compose config` 无误
- [ ] 域名解析：`dig +short ${DOMAIN}` 返回 `${SERVER_IP}`（无域名跳过）
- [ ] 容器健康、重启次数低；Gateway 监听 `127.0.0.1:${GATEWAY_PORT}` → `18789`
- [ ] 模型 API Key 已写入 `runtime.env`；三级模型各完成一次最小推理
- [ ] Nginx `limit_conn_zone` 已生效、`nginx -t` 无报错；`curl -I https://${DOMAIN}` 返回 `200`（有域名）
- [ ] 公网 WebSocket Upgrade 返回 `101`；浏览器控制台能连接（需粘贴 Token）
- [ ] `ufw status` 只放行 SSH / 80 / 443 /（8080 仅无域名时）
- [ ] 手动运行 `nightly-backup.sh` 产生新快照
- [ ] `selfcheck.py --full` 全绿
- [ ] 凭证文件存在且权限 `600`：`/root/openclaw-credentials.txt` 与 `/data/etc/openclaw/runtime.env`

任一项失败 → 不要宣布部署完成，继续排查或向管理员汇报。

---

## 5. 已知坑与规避

| 坑 | 规避 |
|---|---|
| 端口映射错成 8080 / 其他 | 必须映射到容器内 **18789**，宿主机用 `127.0.0.1:${GATEWAY_PORT}` |
| 没写模型 API Key | Gateway 无法推理，容器会反复重启；先验证 Key 再 up |
| certbot 前域名未解析 | 先 `dig +short ${DOMAIN}` 确认指向本机 |
| Nginx `limit_conn` 未定义 zone | 必须先定义 `limit_conn_zone` 与 `map` |
| 默认插件过多 | 部署时直接白名单，禁止默认全开 |
| 短 timeout 误杀长任务 | 长任务用后台执行 |
| Worker 未隔离耗尽资源 | 必须设内存 / CPU / PID 限制 |
| 知识库写明文密钥 | 禁止；密钥只在 `runtime.env`（600） |
| 不可逆操作无确认 | 必须人工确认 |
| 国内拉 `ghcr.io` 失败 | 改用 Docker Hub 镜像或配置加速 |

---

## 6. 与 install.sh 的自动化对应关系

`scripts/install.sh` 已把上述步骤自动化，重跑即幂等覆盖。对应关系：

| 手册步骤 | install.sh 实现 |
|---|---|
| §3.1 Swap + 防火墙 | `step "1. Swap + 防火墙"`（保守 ufw，不清空既有规则） |
| §3.2 /data 目录 | `step "3. 创建目录"` |
| §3.3 依赖 | `step "2. 安装依赖"`（Docker / Nginx / Certbot / Node） |
| §3.4 runtime.env | `step "4. Gateway 配置"` 写入密钥与 Token |
| §3.5 Gateway 容器 | `step "5. 启动 Gateway"` + `wait_for_gateway` |
| §3.6 Nginx 反代 | `step "6. Nginx" / "7. 证书"`（有域名 443 / 无域名 8080） |
| §3.7 模型路由 | `templates/openclaw.json` → `/data/state/openclaw.json` |
| §3.8 Agent 自知识体系 | `step "8. Agent 策略"`（`templates/agent/` → `/data/state/workspace/`） |
| §3.9 备份 | `scripts/ops/nightly-backup.sh` + cron |
| §3.10 巡检 | `scripts/ops/selfcheck.py` + cron |
| mihomo 出海（可选） | `--with-mihomo` → `mihomo-tun` sidecar + `mihomo-guard.sh` |

---

## 附录：已从本项目移除 / 清理的项

- **OpenCode Worker**（终端代理 / 代码执行 Worker）：依项目决策删除，本项目不再包含；代码执行需求由任务引擎 + 沙箱承担。
- **CakeClaw 旧设计稿**：Phase 4 多节点（`worker-register` / `master-discover` / `failover` / `sync`，依赖 OpenClaw 不存在的 `/api/workers/*` 接口）、
  旧监控栈（`watchdog` / `alert` / `trends` / `cert-check` / `audit` / `kbase` / `changelog` / `backup`）—— 均为过期内容，已从仓库清理。
  当前唯一自愈体系是 `scripts/ops/` + `/etc/cron.d/openclaw-ops` 的 10 项 cron 矩阵。
