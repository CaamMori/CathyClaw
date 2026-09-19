#!/usr/bin/env bash
set -euo pipefail
# ============================================================
# cakeclaw 一键部署脚本
# 适用: Ubuntu 24.04 LTS / Debian 12+ (x86_64, 最小 2C/4G/20G)
# 用法: sudo ./scripts/install.sh [--no-phase2] [--no-phase3]
#   --no-phase2  跳过 watchdog/trends/cert-check cron
#   --no-phase3  跳过 audit/kbase cron
# ============================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
fail() { echo -e "${RED}[FAIL]${NC} $*"; exit 1; }
ok()   { echo -e "${GREEN}[OK]${NC} $*"; }
info() { echo -e "${YELLOW}[INFO]${NC} $*"; }
step() { echo ""; echo -e "${GREEN}── ${1} ──${NC}"; }

# 交互输入优先使用 stdin；若 stdin 被管道/重定向占用但当前仍有控制终端，
# 则从 /dev/tty 读取。这样 `curl ... | bash`、`... | tee` 等启动方式仍可提问；
# 真正无终端的 CI 则继续走环境变量自动配置。
INTERACTIVE=false
PROMPT_INPUT="/dev/stdin"
if [ -t 0 ]; then
  INTERACTIVE=true
elif [ -r /dev/tty ] && [ -w /dev/tty ]; then
  INTERACTIVE=true
  PROMPT_INPUT="/dev/tty"
fi

prompt() {
  local message="$1" variable="$2" value=""
  # stdin 本身是 TTY 时直接继承 FD 0；不要重新打开 /dev/stdin，部分移动 SSH
  # 环境会因此显示提示却无法接收键盘输入。仅重定向 stdin 时读取控制终端。
  if [ "${PROMPT_INPUT}" = "/dev/tty" ]; then
    IFS= read -r -p "${message}" value < /dev/tty || value=""
  else
    IFS= read -r -p "${message}" value || value=""
  fi
  printf -v "${variable}" '%s' "${value}"
}

# Codex/ChatGPT Subscription 中转的 /models 列表可能包含当前账号无权调用的模型。
# 在写入 Provider 前做一次最小 Responses 请求；失败时不落盘无效配置。
probe_codex_responses_model() {
  local base_url="$1" api_key="$2" model_id="$3"
  P_URL="${base_url}" P_KEY="${api_key}" P_MODEL="${model_id}" python3 - <<'PYEOF'
import json, os, sys, urllib.error, urllib.request
url = os.environ["P_URL"].rstrip("/") + "/responses"
body = json.dumps({
    "model": os.environ["P_MODEL"],
    # This upstream requires streaming Responses requests with array-form input.
    "stream": True,
    "input": [{
        "role": "user",
        "content": [{"type": "input_text", "text": "Reply exactly OK."}],
    }],
}).encode()
req = urllib.request.Request(url, data=body, method="POST", headers={
    "Authorization": "Bearer " + os.environ["P_KEY"],
    "Content-Type": "application/json",
})
try:
    with urllib.request.urlopen(req, timeout=25) as response:
        if 200 <= response.status < 300:
            sys.exit(0)
except urllib.error.HTTPError as error:
    detail = error.read().decode("utf-8", errors="replace").replace("\n", " ")
    print(f"HTTP {error.code}: {detail[:300]}", file=sys.stderr)
except Exception as error:
    print(f"{type(error).__name__}: {error}", file=sys.stderr)
sys.exit(1)
PYEOF
}

# 等待 Gateway 容器 healthy（与 compose healthcheck 对齐，覆盖 start_period 120s）。
# 不只看容器 Up（Up 可能仍 starting），而看 docker inspect Health.Status；异常则 fail。
verify_control_ui() {
  # OpenClaw 的远程浏览器设备认证要求安全上下文；公网 HTTP 页面即使返回 200，
  # 也无法完成 Control UI WebSocket 认证。因此无域名部署不把 HTTP 当作控制台验收。
  if [ -z "${DOMAIN}" ]; then
    info "未配置 HTTPS 域名：Gateway / Telegram 可正常运行；公网 HTTP Control UI 不受支持"
    info "控制台请使用 SSH 隧道（http://127.0.0.1:${GATEWAY_PORT}/）或 Tailscale Serve"
    return 0
  fi
  local url="https://${DOMAIN}/"
  local status
  status="$(curl -ksS -o /dev/null -w '%{http_code}' --connect-timeout 5 --max-time 15 "${url}" || true)"
  case "${status}" in
    200) ok "HTTPS 控制台可访问 (${url})" ;;
    *) info "HTTPS 控制台验收失败 (${url}, HTTP ${status:-000})；Gateway 部署保留，请检查 DNS、证书与 443 端口" ;;
  esac
}

wait_gateway_ready() {
  info "等待 Gateway 就绪 (max 180s，覆盖 start_period 120s + healthcheck)..."
  local READY=false
  local HS
  for i in $(seq 1 36); do
    sleep 5
    HS=$(docker inspect --format '{{.State.Health.Status}}' cakeclaw-gateway 2>/dev/null || echo "no-health")
    case "${HS}" in
      healthy)
        ok "Gateway 已就绪 (healthy, ${i}x5s)"
        READY=true
        break
        ;;
      unhealthy)
        docker logs cakeclaw-gateway --tail 30 2>&1
        fail "Gateway 健康检查失败 (unhealthy)"
        ;;
      starting|no-health) : ;;
      *)
        docker logs cakeclaw-gateway --tail 30 2>&1
        fail "Gateway 状态异常: ${HS}"
        ;;
    esac
  done
  if [ "${READY}" != true ]; then
    docker logs cakeclaw-gateway --tail 30 2>&1
    fail "Gateway 未在 180s 内变为 healthy"
  fi
}

# ── 0. 参数解析 ──
PHASE2=true; PHASE3=true
CODEX_FIX=false
CODEX_FIX_B=false
OPENCODE_INSTALL=false
HELP=false
NEED_RESTART=false
for arg in "$@"; do
  case "$arg" in
    --no-phase2) PHASE2=false ;;
    --no-phase3) PHASE3=false ;;
    --with-codex-fix) CODEX_FIX=true ;;
    --with-codex-fix-b) CODEX_FIX_B=true ;;
    --help|-h)   HELP=true ;;
    *) fail "未知参数: $arg。支持的参数: --no-phase2 --no-phase3 --with-codex-fix --with-codex-fix-b --help" ;;
  esac
done
if $HELP; then
  echo "用法: sudo ./scripts/install.sh [选项]"
  echo "  --no-phase2         跳过自愈/监控"
  echo "  --no-phase3         跳过审计"
  echo "  --with-codex-fix    启用 Codex 修复（方案 A）"
  echo "  --with-codex-fix-b  启用 Codex 修复（方案 B）"
  echo "  --help              显示此帮助"
  exit 0
fi

# ── 1. 特权检查 ──
if [ "$(id -u)" -ne 0 ]; then fail "请用 sudo 执行"; fi

# ── 2. 加载配置（.env 可选）──
cd "$PROJECT_DIR"
if [ -f .env ]; then
  # 只提取合法 KEY=VALUE 行（允许空值，如 GATEWAY_MEM_LIMIT=），忽略注释/空行/非法行。
  # 逐行 export 而非 `set -a; source`：避免 (1) set -a 把所有变量全局导出污染后续子进程；
  # (2) source 对 .env 里意外出现的 export 语句/多行值/特殊字符产生副作用。
  # 注意：值不做 # 修剪，避免误删合法的 # 字符；注释以行首 # 区分。
  while IFS='=' read -r key value; do
    case "${key}" in
      ''|\#*) continue ;;  # 空键或注释行，跳过
      *[!A-Za-z0-9_]*) continue ;;  # 非法键名，跳过
    esac
    export "${key}=${value}"
  done < <(grep -E '^[A-Za-z_][A-Za-z0-9_]*=' .env)
  info "已加载 .env"
else
  info ".env 未找到，使用默认值。部署后可在 openclaw.json 配置 API Key + URL"
  [ -f .env.example ] && cp .env.example .env 2>/dev/null || true
fi

# 默认值
DOMAIN="${DOMAIN:-}"
# 交互安装时让用户直接提供域名；该值同时用于 Nginx、Let's Encrypt 与 Control UI 来源白名单。
# 非交互环境继续只从 .env / DOMAIN 环境变量读取，避免 CI 卡在输入提示。
if $INTERACTIVE && [ -z "$DOMAIN" ]; then
  echo ""
  echo "  可选：输入已解析到本机的域名以启用 HTTPS（例如 claw.example.com）。"
  echo "  直接回车仍可部署 Gateway、模型和 Telegram，但公网 HTTP 不能完成 Control UI 设备认证。"
  echo "  无域名时请通过 SSH 隧道或 Tailscale 访问控制台。"
  prompt "  控制台域名（可留空）: " DOMAIN
  DOMAIN="$(printf '%s' "$DOMAIN" | tr -d '[:space:]')"
  if [ -n "$DOMAIN" ] && ! printf '%s' "$DOMAIN" | grep -Eq '^[A-Za-z0-9][A-Za-z0-9.-]*[A-Za-z0-9]$'; then
    fail "域名格式无效：请只输入域名，不要带 http://、路径或端口"
  fi
fi
GATEWAY_PORT="${GATEWAY_PORT:-18789}"
GATEWAY_IMAGE="${GATEWAY_IMAGE:-ghcr.io/openclaw/openclaw:2026.7.1}"
SSH_PORT="${SSH_PORT:-22}"
BACKUP_RETENTION_DAYS="${BACKUP_RETENTION_DAYS:-7}"
CONN_LIMIT="${CONN_LIMIT:-15}"
SWAP_SIZE="${SWAP_SIZE:-2G}"
# Codex Responses 修复（可选）：见 patches/ 与 README
# 两种方案，二选一（切勿同时启用）：
#   --with-codex-fix  （CODEX_FIX=1）   env 白名单方案，不改 api 判定，需模型 api 已是
#                                     openai-chatgpt-responses / openclaw-openai-responses-transport
#   --with-codex-fix-b（CODEX_FIX_B=1）改 dist 两处（含 api=openai-responses），无需模型 api 特殊值
# 二者都依赖环境变量 OPENCLAW_CODEX_RESPONSES_PROVIDERS 指定 provider 名（不硬编码）。
if [ "${CODEX_FIX:-}" = "1" ]; then CODEX_FIX=true; fi
if [ "${CODEX_FIX_B:-}" = "1" ]; then CODEX_FIX_B=true; fi
if $CODEX_FIX && $CODEX_FIX_B; then fail "--with-codex-fix 与 --with-codex-fix-b 不能同时启用"; fi
CODEX_FIX_PATCH_SRC="${CODEX_FIX_PATCH_SRC:-$PROJECT_DIR/patches/openai-transport-stream-codex-env.js}"
CODEX_FIX_B_PATCH_SRC="${CODEX_FIX_B_PATCH_SRC:-$PROJECT_DIR/patches/openai-transport-stream-codex-openai-responses.js}"
CODEX_FIX_PATCH_DST="${CODEX_FIX_PATCH_DST:-/app/dist/openai-transport-stream-codex.js}"
CODEX_RESPONSES_PROVIDERS="${CODEX_RESPONSES_PROVIDERS:-}"
# Telegram 机器人接入（可选）：见 README
# 交互环境默认询问；非交互环境用 TELEGRAM_BOT_TOKEN / TELEGRAM_ALLOW_FROM 环境变量。
TELEGRAM_TOKEN_DIR="/data/etc/openclaw/telegram"
TELEGRAM_TOKEN_FILE="${TELEGRAM_TOKEN_DIR}/bot-token"
if [ "${OPENCODE_INSTALL:-}" = "1" ]; then OPENCODE_INSTALL=true; fi
TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-}"
TELEGRAM_ALLOW_FROM="${TELEGRAM_ALLOW_FROM:-}"
# 重跑安装脚本会重新渲染 Compose 模板；在覆盖前记录已生效的 Codex 补丁，稍后恢复挂载并跳过交互。
CODEX_PATCH_HOST_PATH="/data/etc/openclaw/patches/$(basename "${CODEX_FIX_PATCH_DST}")"
CODEX_COMPOSE_FILE="/data/etc/openclaw/docker-compose.yml"
CODEX_FIX_PREVIOUSLY_INSTALLED=false
if [ -f "${CODEX_PATCH_HOST_PATH}" ] && [ -f "${CODEX_COMPOSE_FILE}" ] && \
   grep -Fq -- "- ${CODEX_PATCH_HOST_PATH}:${CODEX_FIX_PATCH_DST}" "${CODEX_COMPOSE_FILE}"; then
  CODEX_FIX_PREVIOUSLY_INSTALLED=true
fi

step "0. 系统检测"
echo "OS: $(. /etc/os-release && echo "$PRETTY_NAME")"
echo "CPU: $(nproc) 核 | RAM: $(free -h | awk '/Mem:/{print $2}') | Disk: $(df -h / | awk 'NR==2{print $4}')"
case "$(uname -m)" in x86_64|aarch64) ;; *) fail "不支持 $(uname -m)";; esac

# 发行版识别（决定 Docker 官方仓库路径 ubuntu/debian；Docker 安装段再做最终校验）
OS_ID="$(. /etc/os-release && echo "$ID")"

# 资源档位自动计算
TOTAL_RAM_GB=$(free -g | awk '/Mem:/{print $2}')
TOTAL_VCPU=$(nproc)
GATEWAY_MEM_LIMIT="${GATEWAY_MEM_LIMIT:-$(( TOTAL_RAM_GB > 8 ? TOTAL_RAM_GB / 2 : TOTAL_RAM_GB * 3 / 5 ))g}"
if [ "${GATEWAY_MEM_LIMIT}" = "0g" ]; then GATEWAY_MEM_LIMIT=1g; fi
GATEWAY_CPU_LIMIT="${GATEWAY_CPU_LIMIT:-$(( TOTAL_VCPU > 2 ? TOTAL_VCPU - 1 : 1 ))}"
GATEWAY_PID_LIMIT="${GATEWAY_PID_LIMIT:-1024}"

info "档位: MEM=${GATEWAY_MEM_LIMIT} CPU=${GATEWAY_CPU_LIMIT} PID=${GATEWAY_PID_LIMIT}"

# ── 1. 系统加固 ──
step "1. Swap + 防火墙"
if [ "$(free -g | awk '/Swap:/{print $2}')" -lt 1 ]; then
  # 解析 SWAP_SIZE（支持 2G / 512M / 1.5G 等）为纯 MB 整数。
  # 用纯 bash 算术替代 `bc`（最小化镜像可能无 bc）+ 粗糙 sed（旧逻辑会把 1.5G 的小数点删掉，
  # 变成 15*1024=15360 错 10 倍）。支持大整数/小数的 G 与 M 后缀。
  parse_mb() {
    local raw="$1" num unit mb=0
    unit="${raw: -1}"; num="${raw%?}"
    case "${unit}" in
      G|g) mb=$(awk -v n="${num}" 'BEGIN{printf "%d", n*1024}') ;;
      M|m) mb=$(awk -v n="${num}" 'BEGIN{printf "%d", n}') ;;
      *)   mb=$(awk -v n="${raw}" 'BEGIN{printf "%d", n}') ;;  # 无后缀视为 MB
    esac
    echo "${mb}"
  }
  SWAP_MB=$(parse_mb "${SWAP_SIZE}")
  if ! [[ "${SWAP_MB}" =~ ^[0-9]+$ ]] || [ "${SWAP_MB}" -le 0 ]; then
    SWAP_MB=2048
    info "SWAP_SIZE 值非法（${SWAP_SIZE}），回退到 2048M"
  fi

  # 优先 fallocate（快），失败回退 dd；两者都失败则报错退出（不静默吞掉）。
  if ! fallocate -l "${SWAP_MB}M" /swapfile 2>/dev/null; then
    info "fallocate 失败（可能文件系统不支持/空间不足），回退 dd"
    if ! dd if=/dev/zero of=/swapfile bs=1M count="${SWAP_MB}" 2>/dev/null; then
      rm -f /swapfile
      fail "Swap 创建失败：fallocate 与 dd 均无法分配 ${SWAP_MB}M（请检查 / 分区空间或文件系统类型）"
    fi
  fi
  chmod 600 /swapfile && mkswap /swapfile && swapon /swapfile
  grep -q /swapfile /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
  ok "Swap ${SWAP_MB}M 已创建"
else
  ok "Swap 已存在"
fi

if command -v ufw >/dev/null 2>&1; then
  # 关键安全原则：绝不 `ufw --force reset`（那会清空用户机器上已有的所有规则，
  # 关掉数据库/监控/其他网站等非本项目的服务）。只追加，不重置。
  
  # 探测真实 SSH 端口（优先 sshd_config，回退 .env/默认 22），避免拿不到自定义端口而把自己锁在门外。
  SSH_PORT_REAL="${SSH_PORT}"
  if command -v sshd >/dev/null 2>&1 || [ -f /etc/ssh/sshd_config ]; then
    # grep 无匹配时返回 1，在 set -e + pipefail 下会让命令替换失败而杀死脚本；
    # 故加 `|| true` 使无 {Port} 行时得空串，交由下方回退到默认端口。
    SSH_PORT_REAL=$(grep -E '^\s*Port\s+[0-9]+' /etc/ssh/sshd_config 2>/dev/null | awk '{print $2}' | head -1 || true)
    [ -n "${SSH_PORT_REAL}" ] || SSH_PORT_REAL="${SSH_PORT}"
  fi

  # 幂等追加规则（已存在则跳过），不 reset 不覆盖
  ufw status 2>/dev/null | grep -q "${SSH_PORT_REAL}/tcp" || ufw allow "${SSH_PORT_REAL}/tcp" comment 'SSH' || true
  if [ -n "$DOMAIN" ]; then
    ufw status 2>/dev/null | grep -q '443/tcp' || ufw allow 443/tcp comment 'HTTPS' || true
    ufw status 2>/dev/null | grep -q '80/tcp'   || ufw allow 80/tcp comment 'HTTP' || true
  else
    ufw status 2>/dev/null | grep -q '8080/tcp' || ufw allow 8080/tcp comment 'Gateway-HTTP' || true
  fi

  # 默认策略：只在「尚未启用 ufw」时设置 default deny（对已有启用状态不改策略，避免意外切断现有放行）
  if ! ufw status 2>/dev/null | grep -q 'Status: active'; then
    ufw default deny incoming >/dev/null 2>&1 || true
    ufw default allow outgoing >/dev/null 2>&1 || true
  fi

  # 启用前最后一道防线：确认 SSH 端口已放行，否则绝不 enable
  if ufw status 2>/dev/null | grep -q "${SSH_PORT_REAL}/tcp"; then
    ufw --force enable >/dev/null 2>&1 || true
    ok "防火墙已配置（SSH: ${SSH_PORT_REAL}）"
  else
    info "未找到 SSH 放行规则（端口 ${SSH_PORT_REAL}），跳过 enable 以免锁死自己"
  fi
else
  ok "无 ufw，跳过"
fi

# ── 2. 基础依赖 ──
step "2. 安装依赖"
apt-get update -qq

# Docker
if ! command -v docker >/dev/null 2>&1; then
  # Docker 官方仓库路径按发行版区分：ubuntu vs debian（Debian 的路径不是 /linux/ubuntu，
  # 硬编码会导致 Debian 上拼出不存在的源而装失败）。
  DOCKER_DISTRO=""
  case "${OS_ID}" in
    ubuntu) DOCKER_DISTRO="ubuntu" ;;
    debian) DOCKER_DISTRO="debian" ;;
    *)      fail "不支持在 ${OS_ID} 上自动安装 Docker（仅支持 ubuntu/debian）。请手动安装 Docker 后重跑。" ;;
  esac
  apt-get install -y ca-certificates curl gnupg
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL "https://download.docker.com/linux/${DOCKER_DISTRO}/gpg" -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/${DOCKER_DISTRO} $(. /etc/os-release && echo "$VERSION_CODENAME") stable" > /etc/apt/sources.list.d/docker.list
  apt-get update -qq && apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  systemctl enable --now docker >/dev/null
fi
docker --version 2>&1 | head -1 && ok "Docker"

# Nginx
apt-get install -y nginx >/dev/null 2>&1
systemctl enable --now nginx >/dev/null 2>&1 || true
nginx -v 2>&1 && ok "Nginx"

# Certbot（有域名才装）
if [ -n "$DOMAIN" ]; then
  apt-get install -y certbot python3-certbot-nginx >/dev/null 2>&1
  certbot --version 2>&1 | head -1 && ok "Certbot"
fi

# 基础工具
apt-get install -y curl wget >/dev/null 2>&1

# logrotate：日志轮转（/data/logs/*.log 会随 watchdog/audit 持续增长，不轮转会无限膨胀）
if ! command -v logrotate >/dev/null 2>&1; then
  apt-get install -y logrotate >/dev/null 2>&1 || info "logrotate 安装失败（跳过，日志可能无限增长）"
fi

# ── 3. 目录结构 ──
step "3. 创建目录"
for d in /data/state /data/workspace /data/backups/openclaw-state /data/logs /data/scripts /data/etc/openclaw; do
  mkdir -p "$d"
done
for d in /data/knowledge/{runbooks,playbooks,templates,changelog,architecture}; do
  mkdir -p "$d"
done
chmod 700 /data/backups /data/state /data/etc/openclaw
chmod 755 /data/workspace /data/logs /data/scripts /data/knowledge
# Gateway 以 UID/GID 1000（node）运行；Telegram Token 专用目录只对该用户开放，
# Compose 仅挂载该目录，不暴露同级的 runtime.env。
install -d -o 1000 -g 1000 -m 700 "${TELEGRAM_TOKEN_DIR}"
ok "目录已创建"

# ── 4. Gateway 配置 ──
step "4. Gateway 配置"
mkdir -p /data/state
# 幂等：仅在 openclaw.json 不存在时写入（首装）。已存在则保留用户手改的 API Key/Model，
# 重跑 install.sh 绝不可覆盖，否则会把用户配好的模型凭证冲掉。
if [ ! -f /data/state/openclaw.json ]; then
  cp "$PROJECT_DIR/templates/openclaw.json" /data/state/openclaw.json 2>/dev/null || cat > /data/state/openclaw.json << 'GWCONF'
{
  "gateway": {
    "mode": "local",
    "port": 18789,
    "bind": "lan"
  }
}
GWCONF
  ok "openclaw.json 已写入（首装）"
else
  ok "openclaw.json 已存在，跳过（保留用户配置）"
fi

# ── 5. 密钥 ──
step "5. 写入密钥"
# 幂等：先在 .env 里查是否已有该 key（避免重跑时重复追加）。
# 优先级：环境变量 > .env 文件 > 新生成。
if [ -z "${OPENCLAW_GATEWAY_TOKEN:-}" ] || [ "$OPENCLAW_GATEWAY_TOKEN" = "***" ]; then
  # 从 .env 读已存在的 token（去重）。grep 无匹配时返回 1，在 set -e + pipefail
  # 下会让命令替换失败而杀死脚本（首次部署 .env 必无从 TOKEN 行），故加 `|| true`。
  EXISTING_TOKEN=$(grep -E '^OPENCLAW_GATEWAY_TOKEN=' "$PROJECT_DIR/.env" 2>/dev/null | tail -1 | cut -d= -f2- || true)
  if [ -n "${EXISTING_TOKEN}" ] && [ "${EXISTING_TOKEN}" != "***" ]; then
    OPENCLAW_GATEWAY_TOKEN="${EXISTING_TOKEN}"
  else
    OPENCLAW_GATEWAY_TOKEN=$(openssl rand -hex 32)
    # 先删掉旧的同类行，再追加新值，保证 .env 里该 key 唯一
    grep -v '^OPENCLAW_GATEWAY_TOKEN=' "$PROJECT_DIR/.env" > "$PROJECT_DIR/.env.tmp" 2>/dev/null || true
    echo "OPENCLAW_GATEWAY_TOKEN=${OPENCLAW_GATEWAY_TOKEN}" >> "$PROJECT_DIR/.env.tmp"
    mv "$PROJECT_DIR/.env.tmp" "$PROJECT_DIR/.env"
  fi
fi
cp "$PROJECT_DIR/.env" /data/etc/openclaw/runtime.env
# Codex Responses 修复（可选）：把 env 白名单写入 runtime.env，让指定 provider 走
# Codex Responses 路径。provider 名由 CODEX_RESPONSES_PROVIDERS 指定（逗号分隔）。
# 两种方案（--with-codex-fix 与 --with-codex-fix-b）都需要这一步。
# 幂等：先删旧行再去重，避免重跑 install.sh 时重复追加。
if $CODEX_FIX || $CODEX_FIX_B; then
  grep -v '^OPENCLAW_CODEX_RESPONSES_PROVIDERS=' /data/etc/openclaw/runtime.env > /data/etc/openclaw/runtime.env.tmp 2>/dev/null || true
  if [ -n "${CODEX_RESPONSES_PROVIDERS}" ]; then
    echo "OPENCLAW_CODEX_RESPONSES_PROVIDERS=${CODEX_RESPONSES_PROVIDERS}" >> /data/etc/openclaw/runtime.env.tmp
    mv /data/etc/openclaw/runtime.env.tmp /data/etc/openclaw/runtime.env
    info "已写入 OPENCLAW_CODEX_RESPONSES_PROVIDERS=${CODEX_RESPONSES_PROVIDERS}"
  else
    mv /data/etc/openclaw/runtime.env.tmp /data/etc/openclaw/runtime.env
    info "未设置 CODEX_RESPONSES_PROVIDERS，稍后在 provider 配置后手动填入"
  fi
fi
chmod 600 /data/etc/openclaw/runtime.env
chown -R 1000:1000 /data/state /data/workspace 2>/dev/null || true
ok "密钥已写入 /data/etc/openclaw/runtime.env"

# ── 6. 拉镜像 & 启动 ──
step "6. 部署 Gateway"
docker pull "${GATEWAY_IMAGE}" 2>&1 | tail -3

# 生成 docker-compose.yml（持久化，避免 /tmp 被清）
export GATEWAY_PORT GATEWAY_IMAGE GATEWAY_MEM_LIMIT GATEWAY_CPU_LIMIT GATEWAY_PID_LIMIT
COMPOSE_FILE="/data/etc/openclaw/docker-compose.yml"
envsubst '$GATEWAY_PORT $GATEWAY_IMAGE $GATEWAY_MEM_LIMIT $GATEWAY_CPU_LIMIT $GATEWAY_PID_LIMIT' \
  < "$PROJECT_DIR/docker-compose.yml" > "${COMPOSE_FILE}"
# 防御：确认模板里的所有 ${VAR} 都已被替换，没有残留占位符。
# 若未来有人在 docker-compose.yml 新增变量却忘了同步 envsubst 列表，
# 残留的 ${XXX} 会变成字面量导致 compose 启动异常，这里提前拦截。
if grep -qE '\$\{[A-Za-z_][A-Za-z0-9_]*\}' "${COMPOSE_FILE}"; then
  fail "docker-compose 生成失败：存在未替换的占位符，请同步 envsubst 变量列表。残留: $(grep -oE '\$\{[A-Za-z_][A-Za-z0-9_]*\}' "${COMPOSE_FILE}" | sort -u | tr '\n' ' ')"
fi
chmod 600 "${COMPOSE_FILE}"

# 保留重跑前已验证生效的 Codex 补丁挂载。模板本身不含该可选挂载，若不恢复会导致
# 重跑安装时先丢失补丁、随后重复弹出交互配置。
if $CODEX_FIX_PREVIOUSLY_INSTALLED; then
  CODEX_MOUNT_SRC="${CODEX_PATCH_HOST_PATH}" CODEX_MOUNT_DST="${CODEX_FIX_PATCH_DST}" \
  python3 - "${COMPOSE_FILE}" << 'PYEOF'
import os, sys
path = sys.argv[1]
entry = "      - " + os.environ["CODEX_MOUNT_SRC"] + ":" + os.environ["CODEX_MOUNT_DST"]
with open(path, encoding="utf-8") as f:
    lines = f.readlines()
if entry + chr(10) not in lines:
    for i, line in enumerate(lines):
        if line.startswith("    env_file:"):
            lines.insert(i, entry + chr(10))
            break
    else:
        raise SystemExit("Codex mount restore failed: env_file section not found")
    with open(path, "w", encoding="utf-8") as f:
        f.writelines(lines)
PYEOF
  NEED_RESTART=true
  info "检测到已安装 Codex Responses 补丁，已保留挂载并跳过后续补丁交互"
fi

# Codex Responses 修复（可选）：把 dist 补丁文件复制到持久化目录并注入 compose 挂载。
# 两个方案选一个（互斥已在上方校验）：
#   --with-codex-fix   → 用 env 白名单产物（不改 api 判定，需模型 api 已是 Codex 专属值）
#   --with-codex-fix-b → 用 openai-responses 产物（额外支持 api=openai-responses）
# 补丁均从官方 dist（2026.7.1）派生，provider 名不硬编码（由环境变量指定）。
# 未启用任何方案时完全不碰 compose，与默认部署完全一致。
if $CODEX_FIX || $CODEX_FIX_B; then
  if $CODEX_FIX_B; then
    CODEX_PATCH_SRC="${CODEX_FIX_B_PATCH_SRC}"
  else
    CODEX_PATCH_SRC="${CODEX_FIX_PATCH_SRC}"
  fi
  [ -f "${CODEX_PATCH_SRC}" ] || fail "Codex 修复补丁文件不存在: ${CODEX_PATCH_SRC}"
  mkdir -p /data/etc/openclaw/patches
  cp "${CODEX_PATCH_SRC}" /data/etc/openclaw/patches/"$(basename "${CODEX_FIX_PATCH_DST}")"
  chmod 644 /data/etc/openclaw/patches/"$(basename "${CODEX_FIX_PATCH_DST}")"
  # 用 python 往 volumes 段末尾插入一行 bind mount（源=宿主机持久化文件，目标=容器 dist 文件）
  CODEX_MOUNT_SRC="/data/etc/openclaw/patches/$(basename "${CODEX_FIX_PATCH_DST}")" \
  CODEX_MOUNT_DST="${CODEX_FIX_PATCH_DST}" \
  python3 - "${COMPOSE_FILE}" << 'PYEOF'
import sys, os, tempfile
path = sys.argv[1]
mount_src = os.environ["CODEX_MOUNT_SRC"]
mount_dst = os.environ["CODEX_MOUNT_DST"]
with open(path, encoding="utf-8") as f:
    lines = f.readlines()
new_lines = []
injected = False
volumes_key_idx = None
for i, line in enumerate(lines):
    if not injected and line.strip() == "volumes:":
        volumes_key_idx = i
    new_lines.append(line)
# 找到 volumes: 段内最后一个以 "  - " 开头的挂载行，在其后插入新挂载
if volumes_key_idx is not None:
    insert_after = None
    for j in range(volumes_key_idx + 1, len(new_lines)):
        nl = new_lines[j]
        if nl.startswith("    ") and not nl.strip() == "":
            if nl.strip().startswith("-"):
                insert_after = j
            else:
                break
        elif nl.strip() == "":
            break
        else:
            break
    if insert_after is None:
        insert_after = volumes_key_idx
    indent = "      "
    new_lines.insert(insert_after + 1, indent + "- " + mount_src + ":" + mount_dst + "\n")
    injected = True
with open(path, "w", encoding="utf-8") as f:
    f.writelines(new_lines)
print("injected mount" if injected else "ERROR: volumes section not found")
PYEOF
  if $CODEX_FIX_B; then
    ok "Codex 修复 B 已启用（挂载 ${CODEX_FIX_PATCH_DST}，支持 api=openai-responses）"
  else
    ok "Codex 修复已启用（挂载 ${CODEX_FIX_PATCH_DST}）"
  fi
  # 补丁挂载需重启才生效；打标记，由 12.8 收尾统一重启（避免此处与后续配置改动重复重启）
  NEED_RESTART=true
else
  info "未启用 Codex 修复（--with-codex-fix / --with-codex-fix-b 未指定）"
fi

docker compose -f "${COMPOSE_FILE}" up -d 2>&1 || fail "Gateway 启动失败"

# 若无后续配置改动（未启用 Codex 补丁），在此等待 Gateway healthy；
# 若已启用 Codex 补丁（NEED_RESTART=true），则只拉起容器、跳过等待，由 12.8 统一重启并确认 healthy。
if $NEED_RESTART; then
  info "已启用 Codex 补丁，暂不等待 healthy，将由 12.8 收尾统一重启确认"
else
  wait_gateway_ready
fi

# ── 7. Nginx ──
step "7. Nginx"
# 幂等：仅在 nginx 站点配置不存在时写入（首装）。已存在则保留用户手改的追加配置，
# 重跑 install.sh 不覆盖，但会重新检测默认站点并 reload（不应覆盖用户自定义 server 块）。
if [ ! -f /etc/nginx/sites-available/cakeclaw ]; then
if [ -n "$DOMAIN" ]; then
  # 先只启用 HTTP：让 ACME HTTP-01 challenge 能通过，避免引用尚不存在的证书。
  sudo mkdir -p /var/www/certbot
  cat > /etc/nginx/sites-available/cakeclaw << NGINX
map \$http_upgrade \$connection_upgrade { default upgrade; '' close; }
limit_conn_zone \$binary_remote_addr zone=cakeclaw_limit:10m;
server {
  listen 80; server_name ${DOMAIN};
  location ^~ /.well-known/acme-challenge/ { root /var/www/certbot; }
  location / {
    proxy_pass http://127.0.0.1:${GATEWAY_PORT};
    proxy_http_version 1.1;
    proxy_set_header Upgrade \$http_upgrade;
    proxy_set_header Connection \$connection_upgrade;
    proxy_set_header Host \$host;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto \$scheme;
    proxy_read_timeout 86400;
    limit_conn cakeclaw_limit ${CONN_LIMIT};
  }
}
NGINX
  ln -sf /etc/nginx/sites-available/cakeclaw /etc/nginx/sites-enabled/cakeclaw
  rm -f /etc/nginx/sites-enabled/default
  nginx -t || fail "HTTP Nginx 配置校验失败"
  systemctl reload nginx

  if certbot certonly --webroot -w /var/www/certbot -d "${DOMAIN}" --non-interactive --agree-tos -m "admin@${DOMAIN}"; then
    cat > /etc/nginx/sites-available/cakeclaw << NGINX
map \$http_upgrade \$connection_upgrade { default upgrade; '' close; }
limit_conn_zone \$binary_remote_addr zone=cakeclaw_limit:10m;
server {
  listen 80; server_name ${DOMAIN};
  location ^~ /.well-known/acme-challenge/ { root /var/www/certbot; }
  location / { return 301 https://\$host\$request_uri; }
}
server {
  listen 443 ssl http2; server_name ${DOMAIN};
  ssl_certificate     /etc/letsencrypt/live/${DOMAIN}/fullchain.pem;
  ssl_certificate_key /etc/letsencrypt/live/${DOMAIN}/privkey.pem;
  ssl_protocols TLSv1.2 TLSv1.3;
  location / {
    proxy_pass http://127.0.0.1:${GATEWAY_PORT};
    proxy_http_version 1.1;
    proxy_set_header Upgrade \$http_upgrade;
    proxy_set_header Connection \$connection_upgrade;
    proxy_set_header Host \$host;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto \$scheme;
    proxy_read_timeout 86400;
    limit_conn cakeclaw_limit ${CONN_LIMIT};
  }
}
NGINX
    nginx -t || fail "HTTPS Nginx 配置校验失败"
    systemctl reload nginx
    ok "Nginx HTTPS 就位"
  else
    info "证书签发失败，保留 HTTP 控制台；请确认 DNS、80 端口与域名后重跑"
  fi
else
  # 无域名：只用 8080
  cat > /etc/nginx/sites-available/cakeclaw << NGINX
map \$http_upgrade \$connection_upgrade { default upgrade; '' close; }
server {
  listen 8080;
  location / {
    proxy_pass http://127.0.0.1:${GATEWAY_PORT};
    proxy_http_version 1.1;
    proxy_set_header Upgrade \$http_upgrade;
    proxy_set_header Connection \$connection_upgrade;
    proxy_set_header Host \$host;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_read_timeout 86400;
  }
}
NGINX
  ln -sf /etc/nginx/sites-available/cakeclaw /etc/nginx/sites-enabled/cakeclaw
  rm -f /etc/nginx/sites-enabled/default
  nginx -t && systemctl reload nginx
  ok "Nginx (8080, 无 HTTPS) 就位"
fi
else
  # nginx 配置已存在：保留用户自定义，仅确保软链与 reload 到位，不覆盖内容
  ln -sf /etc/nginx/sites-available/cakeclaw /etc/nginx/sites-enabled/cakeclaw 2>/dev/null || true
  nginx -t && systemctl reload nginx 2>/dev/null || true
  ok "Nginx 配置已存在，跳过覆盖（保留用户配置）"
fi

# Control UI 会以浏览器页面的完整 Origin 发起 WebSocket 握手。Gateway 默认拒绝
# 未列入 allowedOrigins 的远程来源；Docker/Nginx 反代部署必须显式写入该来源。
if [ -n "$DOMAIN" ]; then
  if [ -f "/etc/letsencrypt/live/${DOMAIN}/fullchain.pem" ]; then
    CONTROL_UI_ORIGIN="https://${DOMAIN}"
  else
    CONTROL_UI_ORIGIN="http://${DOMAIN}"
  fi
else
  CONTROL_UI_IP="$(curl -4 -fsS --connect-timeout 5 --max-time 10 https://ipinfo.io/ip 2>/dev/null || hostname -I | awk '{print $1}')"
  CONTROL_UI_ORIGIN="http://${CONTROL_UI_IP}:8080"
fi
CONTROL_UI_ORIGIN="$CONTROL_UI_ORIGIN" python3 - /data/state/openclaw.json << 'PYEOF'
import json, os, sys, tempfile
path = sys.argv[1]
with open(path, encoding="utf-8") as f:
    cfg = json.load(f)
gateway = cfg.setdefault("gateway", {})
ui = gateway.setdefault("controlUi", {})
origin = os.environ["CONTROL_UI_ORIGIN"]
origins = ui.setdefault("allowedOrigins", [])
if origin not in origins:
    origins.append(origin)
fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path), suffix=".tmp")
with os.fdopen(fd, "w", encoding="utf-8") as f:
    json.dump(cfg, f, indent=2, ensure_ascii=False)
    f.write("\n")
os.replace(tmp, path)
os.chown(path, 1000, 1000)
os.chmod(path, 0o600)
PYEOF
NEED_RESTART=true
ok "Control UI 来源已允许: ${CONTROL_UI_ORIGIN}"

# ── 8. SOUL + AGENTS ──
step "8. Agent 策略"
cp "$PROJECT_DIR/templates/SOUL.md" /data/workspace/SOUL.md 2>/dev/null || cat > /data/workspace/SOUL.md << 'SOUL'
# Administrator Execution Mode
## Identity
私人高级运维工程师。任务：理解目标 → 分析环境 → 执行操作 → 验证结果 → 交付可用。
## Rules
- 管理员任务最高优先级
- 禁止输出 token / 密钥 / 密码
- 可逆操作直接执行，不可逆必须确认
- 不确定按不可逆处理
SOUL

cp "$PROJECT_DIR/templates/AGENTS.md" /data/workspace/AGENTS.md 2>/dev/null || cat > /data/workspace/AGENTS.md << 'AGENTS'
# Private Dev Agent Policy
## Core
管理员指令最高优先级。
## Secrets
禁止输出 API Key / Token / 密码。汇报只告知文件路径。
## Risk
- 可逆操作：直接执行。
- 不可逆操作：必须确认。
- 不确定的按不可逆处理。
## Execution
- 容器以非 root 运行，host 级操作受 Docker 安全边界限制。
- 所有操作通过 Gateway 审计日志记录。
AGENTS
ok "策略文件已写入"

# ── 9. 备份 ──
step "9. 备份"
cp "$PROJECT_DIR/scripts/backup.sh" /data/scripts/backup.sh 2>/dev/null || true
chmod 700 /data/scripts/backup.sh
bash /data/scripts/backup.sh
# 每天 2:00 自动备份。cron 环境不 source .env，因此用 env 前缀显式传 retention，
# 否则自定义的 BACKUP_RETENTION_DAYS 永远回退到 backup.sh 里的默认值 7。
# 用 /etc/cron.d/ 独立文件：天然幂等（重写同名文件即可）、可 git 版本化、不污染 root crontab。
cat > /etc/cron.d/cakeclaw-backup << CRONEOF
# cakeclaw 自动备份（每天 2:00）
0 2 * * * root BACKUP_RETENTION_DAYS=${BACKUP_RETENTION_DAYS} /data/scripts/backup.sh >> /data/logs/backup.log 2>&1
CRONEOF
chmod 644 /etc/cron.d/cakeclaw-backup
ok "备份就绪（cron.d: 每天 2:00）"

# ── 10. 健康巡检 ──
step "10. 巡检 Cron"
cat > /data/scripts/health-check.sh << 'HC'
#!/usr/bin/env bash
set -euo pipefail
OUT="/data/logs/health-check"
mkdir -p "${OUT}"
TS="$(date -u +%Y%m%dT%H%M%SZ)"
R="${OUT}/${TS}.json"
DISK_PCT=$(df -P / | awk 'NR==2{gsub("%","",$5); print $5}')
MEM_FREE=$(free -g | awk '/Mem:/{print $7}')
SWAP_TOTAL=$(free -g | awk '/Swap:/{print $2}')
GW_STATUS=$(docker ps --filter name=cakeclaw-gateway --format '{{.Status}}' 2>/dev/null || echo not-running)
NGX_CHECK=ok; nginx -t >/dev/null 2>&1 || NGX_CHECK=fail
printf '{"ts":"%s","disk_pct":%s,"mem_free_gb":%s,"swap_gb":%s,"gateway":"%s","nginx":"%s"}\n' "$TS" "$DISK_PCT" "$MEM_FREE" "$SWAP_TOTAL" "$GW_STATUS" "$NGX_CHECK" > "${R}"
echo "[$(date +%H:%M)] disk=${DISK_PCT}% mem=${MEM_FREE}G gw=${GW_STATUS} nginx=${NGX_CHECK}"
HC
chmod 700 /data/scripts/health-check.sh
/data/scripts/health-check.sh
cat > /etc/cron.d/cakeclaw-health-check << 'CRONEOF'
# cakeclaw 健康巡检（每天 3:00）
0 3 * * * root /data/scripts/health-check.sh >> /data/logs/health-check/cron.log 2>&1
CRONEOF
chmod 644 /etc/cron.d/cakeclaw-health-check
ok "巡检 cron 就位（cron.d）"

# 日志轮转：watchdog(每5分钟)/audit(每小时)/health-check(每天) 会让 /data/logs/*.log 无限增长，
# 用 logrotate 以大小+保留份数控制，避免磁盘被日志吃满。
if command -v logrotate >/dev/null 2>&1; then
  cat > /etc/logrotate.d/cakeclaw << 'LR'
/data/logs/*.log /data/logs/health-check/*.log {
    daily
    rotate 7
    size 50M
    missingok
    notifempty
    copytruncate
    compress
    delaycompress
}
LR
  ok "logrotate 已配置（/etc/logrotate.d/cakeclaw）"
else
  info "logrotate 不存在，跳过日志轮转配置"
fi

# ── 10.5 Phase 2: watchdog + trends ──
if $PHASE2; then
  step "10.5 Phase 2: 自愈 + 周报"
  cp "$PROJECT_DIR/scripts/watchdog.sh" /data/scripts/watchdog.sh 2>/dev/null || true
  cp "$PROJECT_DIR/scripts/alert.sh" /data/scripts/alert.sh 2>/dev/null || true
  cp "$PROJECT_DIR/scripts/trends.sh" /data/scripts/trends.sh 2>/dev/null || true
  cp "$PROJECT_DIR/scripts/cert-check.sh" /data/scripts/cert-check.sh 2>/dev/null || true
  chmod 700 /data/scripts/watchdog.sh /data/scripts/alert.sh /data/scripts/trends.sh /data/scripts/cert-check.sh
  cat > /etc/cron.d/cakeclaw-watchdog << 'CRONEOF'
# cakeclaw 自愈（每 5 分钟）
*/5 * * * * root /data/scripts/watchdog.sh >> /data/logs/watchdog.log 2>&1
CRONEOF
  cat > /etc/cron.d/cakeclaw-trends << 'CRONEOF'
# cakeclaw 周报（每周一 9:00）
0 9 * * 1 root /data/scripts/trends.sh >> /data/logs/trends.log 2>&1
CRONEOF
  cat > /etc/cron.d/cakeclaw-cert-check << CRONEOF
# cakeclaw 证书到期提醒（每天 9:00）
0 9 * * * root /data/scripts/cert-check.sh ${DOMAIN} >> /data/logs/cert-check.log 2>&1
CRONEOF
  chmod 644 /etc/cron.d/cakeclaw-watchdog /etc/cron.d/cakeclaw-trends /etc/cron.d/cakeclaw-cert-check
  ok "watchdog + trends + cert-check cron 就位（cron.d）"
else
  info "跳过 Phase 2 (--no-phase2)"
fi

# ── 10.6 Phase 3: audit + kbase ──
if $PHASE3; then
  step "10.6 Phase 3: 审计"
  cp "$PROJECT_DIR/scripts/audit.sh" /data/scripts/audit.sh 2>/dev/null || true
  cp "$PROJECT_DIR/scripts/changelog.sh" /data/scripts/changelog.sh 2>/dev/null || true
  cp "$PROJECT_DIR/scripts/kbase.sh" /data/scripts/kbase.sh 2>/dev/null || true
  chmod 700 /data/scripts/audit.sh /data/scripts/changelog.sh /data/scripts/kbase.sh
  cat > /etc/cron.d/cakeclaw-audit << 'CRONEOF'
# cakeclaw 审计（每小时）
0 * * * * root /data/scripts/audit.sh >> /data/logs/audit.log 2>&1
CRONEOF
  chmod 644 /etc/cron.d/cakeclaw-audit
  ok "audit + changelog cron 就位（cron.d）"
else
  info "跳过 Phase 3 (--no-phase3)"
fi

# ── 11. 凭证摘要 ──
step "11. 凭证"
cat > /root/cakeclaw-credentials.txt << EOF
cakeclaw 凭证 (部署: $(date -u +%Y-%m-%dT%H:%M:%SZ))
=========================================
运行时环境: /data/etc/openclaw/runtime.env
Token 读取:  grep OPENCLAW_GATEWAY_TOKEN /data/etc/openclaw/runtime.env
EOF
chmod 600 /root/cakeclaw-credentials.txt
ok "凭证摘要: /root/cakeclaw-credentials.txt"

# ── 12. 知识库 ──
for f in environment decisions incidents projects; do
  touch "/data/knowledge/${f}.md" 2>/dev/null || true
done

# ── 12.4 Codex Responses 修复（可选）──
# 独立于 provider 配置先询问一次：这样用户即使稍后跳过 provider 配置，或通过控制台配置
# provider，也能在首装时完成补丁挂载。provider 名用于 Responses 路径白名单。
step "12.4 Codex Responses 修复（可选）"
configure_codex_fix_interactive() {
  if $CODEX_FIX_PREVIOUSLY_INSTALLED; then
    info "Codex Responses 补丁已安装且挂载完整，跳过交互配置"
    return 0
  fi
  echo ""
  echo "  是否启用 Codex / ChatGPT Subscription（type=57）兼容补丁？直接回车跳过。"
  echo "  仅当后端只接受 /v1/responses 且拒绝 system prompt 时需要。"
  prompt "  是否启用 (y/N): " DO_CODEX_FIX
  case "${DO_CODEX_FIX}" in
    y|Y|yes|YES) : ;;
    *) info "跳过 Codex Responses 修复"; return 0 ;;
  esac

  echo "    A) 方案 A — 仅 env 白名单，不改 api，需 api 已是 Codex 专属值"
  echo "    B) 方案 B（推荐）— 支持 api=openai-responses，覆盖绝大多数自定义 Codex 中转"
  prompt "  选择补丁方案 (A/B，默认 B): " CODEX_PATCH_CHOICE
  case "${CODEX_PATCH_CHOICE:-B}" in
    a|A|1)
      CODEX_FIX=true
      info "已选择方案 A"
      ;;
    *)
      CODEX_FIX_B=true
      info "已选择方案 B"
      ;;
  esac

  info "Provider 名会在后续模型 Provider 配置中写入白名单；已有 Provider 可通过 CODEX_RESPONSES_PROVIDERS 预设。"
}

if $INTERACTIVE && ! $CODEX_FIX && ! $CODEX_FIX_B; then
  configure_codex_fix_interactive
elif $CODEX_FIX || $CODEX_FIX_B; then
  info "已通过参数或 .env 启用 Codex Responses 修复"
else
  info "非交互环境，未设置 Codex 修复开关，跳过"
fi

# ── 12.5 模型 Provider 配置（交互）──
# 引导用户选择哪家 API（OpenAI / Claude / Azure / OpenAI 兼容），按各家预设好 baseUrl 默认值、
# 鉴权方式与 api 适配器字段；填 key 后自动调用各家 /models 端点拉取可用模型列表供用户勾选，
# 最后 merge 进 /data/state/openclaw.json（追加 provider，不覆盖已有字段，保持幂等）。
step "12.5 模型 Provider 配置"
configure_provider() {
  GWJSON="/data/state/openclaw.json"
  [ -f "${GWJSON}" ] || { info "openclaw.json 不存在，跳过 provider 配置"; return 0; }

  echo ""
  echo "  现在配置一个模型 provider？ 直接回车跳过（稍后可在控制台 Config 手动配）"
  prompt "  是否配置 (y/N): " DO_CONF
  case "${DO_CONF}" in
    y|Y|yes|YES) : ;;
    *) info "跳过模型 provider 配置"; return 0 ;;
  esac

  echo ""
  echo "  选择 API 类型："
  echo "    1) OpenAI 官方         api.openai.com"
  echo "    2) Anthropic (Claude)  api.anthropic.com"
  echo "    3) Azure OpenAI        自定义 endpoint"
  echo "    4) OpenAI 兼容格式     自定义 baseUrl（如中转站/vLLM/Ollama）"
  prompt "  请输入 1-4 (默认 4): " P_TYPE
  P_TYPE="${P_TYPE:-4}"

  P_NAME=""; P_URL=""; P_KEY=""; P_API=""; P_MODELS_URL=""; P_AUTH=""
  case "${P_TYPE}" in
    1)
      P_NAME="openai"; P_URL="https://api.openai.com/v1"; P_API="openai-completions"
      P_MODELS_URL="https://api.openai.com/v1/models"; P_AUTH="bearer"
      ;;
    2)
      P_NAME="anthropic"; P_URL="https://api.anthropic.com"; P_API="anthropic-messages"
      P_MODELS_URL="https://api.anthropic.com/v1/models"; P_AUTH="x-api-key"
      ;;
    3)
      P_NAME="azure"; P_URL=""; P_API="azure-openai-responses"; P_AUTH="api-key"
      ;;
    *)
      P_NAME=""; P_URL=""; P_API="openai-completions"; P_AUTH="bearer"
      ;;
  esac

  # Azure 需要手动填 endpoint；兼容格式需要手动填 baseUrl
  if [ "${P_TYPE}" = "3" ] || [ "${P_TYPE}" = "4" ]; then
    prompt "  Base URL（如 https://your-resource.openai.azure.com/openai/v1 或 https://host/v1）: " P_URL
  fi

  prompt "  Provider 名称（回车用默认 '${P_NAME:-my-provider}'）: " P_NAME_IN
  [ -n "${P_NAME_IN}" ] && P_NAME="${P_NAME_IN}"
  [ -n "${P_NAME}" ] || P_NAME="my-provider"

  prompt "  API Key: " P_KEY
  [ -n "${P_KEY}" ] || { info "未填 API Key，取消"; return 0; }

  # Azure 还需 api-version
  P_API_VERSION=""
  if [ "${P_TYPE}" = "3" ]; then
    prompt "  Azure API 版本（如 2024-06-01，回车用默认）: " P_API_VERSION
    P_API_VERSION="${P_API_VERSION:-2024-06-01}"
  fi

  # 类型 4（OpenAI 兼容格式）：判断是否 Codex（type=57）后端（如 ChatGPT Subscription 中转）
  # 如果是，则引导用户选择补丁方案，并自动设置 P_API + 白名单
  CODECX_DETECTED=false
  if [ "${P_TYPE}" = "4" ]; then
    echo ""
    echo "  该后端是否为 ChatGPT Subscription / Codex（type=57）中转？"
    echo "  （特征：只在 /v1/responses 收发，拒绝 system prompt，常见于自定义中转）"
    prompt "  是否为 Codex 后端 (y/N): " DO_CODEX
    case "${DO_CODEX}" in
      y|Y|yes|YES)
        CODECX_DETECTED=true
        if $CODEX_FIX || $CODEX_FIX_B; then
          # 已在 12.4 或通过参数/.env 选择方案；此处仅套用 api 并补当前 provider 白名单。
          if $CODEX_FIX_B; then
            P_API="openai-responses"
            CODECX_PATCH_SRC="${CODEX_FIX_B_PATCH_SRC}"
            info "复用已选择的方案 B：api 设为 openai-responses"
          else
            CODECX_PATCH_SRC="${CODEX_FIX_PATCH_SRC}"
            info "复用已选择的方案 A：仅 env 白名单补丁"
          fi
        else
          echo ""
          echo "  Codex 后端需要补丁修复 system prompt 兼容。已提供两种补丁方案："
          echo "    A) 方案 A — 仅 env 白名单，不改 api，需 api 已是 Codex 专属值"
          echo "    B) 方案 B（推荐）— 改 api 为 openai-responses，覆盖绝大多数自定义 Codex 中转"
          prompt "  选择补丁方案 (A/B，默认 B): " CODECX_PATCH
          CODECX_PATCH="${CODECX_PATCH:-B}"
          case "${CODECX_PATCH}" in
            a|A|1)
              CODECX_PATCH_SRC="${CODEX_FIX_PATCH_SRC}"
              info "已选择方案 A：仅 env 白名单补丁"
              ;;
            *)
              P_API="openai-responses"
              CODECX_PATCH_SRC="${CODEX_FIX_B_PATCH_SRC}"
              info "已选择方案 B：api 设为 openai-responses"
              ;;
          esac
        fi
        # 将当前 provider 名加入白名单
        if [ -n "${P_NAME}" ]; then
          if [ -z "${CODEX_RESPONSES_PROVIDERS}" ]; then
            CODEX_RESPONSES_PROVIDERS="${P_NAME}"
          else
            case ",${CODEX_RESPONSES_PROVIDERS}," in
              *",${P_NAME},"*) : ;;
              *) CODEX_RESPONSES_PROVIDERS="${CODEX_RESPONSES_PROVIDERS},${P_NAME}" ;;
            esac
          fi
        fi
        # 执行补丁挂载：复制 patch 文件 + 注入 compose volumes
        if [ -f "${CODECX_PATCH_SRC}" ]; then
          mkdir -p /data/etc/openclaw/patches
          cp "${CODECX_PATCH_SRC}" /data/etc/openclaw/patches/"$(basename "${CODEX_FIX_PATCH_DST}")"
          chmod 644 /data/etc/openclaw/patches/"$(basename "${CODEX_FIX_PATCH_DST}")"
          CODEX_MOUNT_SRC="/data/etc/openclaw/patches/$(basename "${CODEX_FIX_PATCH_DST}")" \
          CODEX_MOUNT_DST="${CODEX_FIX_PATCH_DST}" \
          python3 - /data/etc/openclaw/docker-compose.yml << 'PYEOF'
import sys, os
path = sys.argv[1]
mount_src = os.environ["CODEX_MOUNT_SRC"]
mount_dst = os.environ["CODEX_MOUNT_DST"]
vol_entry = "      - " + mount_src + ":" + mount_dst
with open(path, encoding="utf-8") as f:
    lines = f.readlines()
# 幂等：如果已有相同的 src:dst 挂载行（可能来自 step 6 的 --with-codex-fix-b），则不再注入。
for line in lines:
    if line.strip() == vol_entry.strip():
        print("exists")
        sys.exit(0)
new_lines = []
volumes_key_idx = None
for i, line in enumerate(lines):
    if not volumes_key_idx and line.strip() == "volumes:":
        volumes_key_idx = i
    new_lines.append(line)
if volumes_key_idx is not None:
    insert_after = None
    for j in range(volumes_key_idx + 1, len(new_lines)):
        nl = new_lines[j]
        if nl.startswith("    ") and nl.strip() != "":
            if nl.strip().startswith("-"):
                insert_after = j
            else:
                break
        elif nl.strip() == "":
            break
        else:
            break
    if insert_after is None:
        insert_after = volumes_key_idx
    new_lines.insert(insert_after + 1, vol_entry + "\n")
with open(path, "w", encoding="utf-8") as f:
    f.writelines(new_lines)
print("injected")
PYEOF
          ok "补丁已挂载到 docker-compose.yml"
        else
          info "补丁文件 ${CODECX_PATCH_SRC} 不存在，跳过挂载（请手动处理）"
        fi
        # 写白名单到 runtime.env
        if [ -n "${CODEX_RESPONSES_PROVIDERS}" ]; then
          grep -v '^OPENCLAW_CODEX_RESPONSES_PROVIDERS=' /data/etc/openclaw/runtime.env > /data/etc/openclaw/runtime.env.tmp 2>/dev/null || true
          echo "OPENCLAW_CODEX_RESPONSES_PROVIDERS=${CODEX_RESPONSES_PROVIDERS}" >> /data/etc/openclaw/runtime.env.tmp
          mv /data/etc/openclaw/runtime.env.tmp /data/etc/openclaw/runtime.env
          chmod 600 /data/etc/openclaw/runtime.env
          info "已写入 CODEX_RESPONSES_PROVIDERS=${CODEX_RESPONSES_PROVIDERS}"
        fi
        ;;
      *) : ;;
    esac
  fi

  # 自动拉取模型列表（非交互环境或拉取失败则退化为手动填一个模型 id）
  echo ""
  info "正在自动拉取可用模型列表..."
  P_TYPE="${P_TYPE}" P_URL="${P_URL}" P_KEY="${P_KEY}" P_AUTH="${P_AUTH}" \
    P_MODELS_URL="${P_MODELS_URL}" P_API_VERSION="${P_API_VERSION}" \
  python3 - << 'PYEOF' > /tmp/cakeclaw-models.txt 2>/dev/null
import json, os, sys, urllib.request
ptype = os.environ.get("P_TYPE", "4")
url = os.environ.get("P_MODELS_URL", "") or os.environ.get("P_URL", "")
key = os.environ.get("P_KEY", "")
auth = os.environ.get("P_AUTH", "bearer")
api_ver = os.environ.get("P_API_VERSION", "")

if ptype == "3":  # Azure: /openai/models?api-version=...
    base = url.rstrip("/")
    url = f"{base}/models?api-version={api_ver}"
elif ptype == "4" and not os.environ.get("P_MODELS_URL", ""):
    # OpenAI 兼容的交互配置收的是 baseUrl（通常以 /v1 结尾），模型列表在 /models。
    # 非交互分支已做此拼接；这里保持一致，避免误请求 baseUrl 根路径。
    base = url.rstrip("/")
    url = base if base.endswith("/models") else f"{base}/models"

if not url:
    sys.exit(0)

req = urllib.request.Request(url)
if auth == "x-api-key":
    req.add_header("x-api-key", key)
    req.add_header("anthropic-version", "2023-06-01")
elif auth == "api-key":
    req.add_header("api-key", key)
else:
    req.add_header("Authorization", f"Bearer {key}")

try:
    with urllib.request.urlopen(req, timeout=15) as r:
        data = json.load(r)
    models = []
    if isinstance(data, list):
        raw = data
    elif isinstance(data, dict):
        raw = data.get("data", [])
    else:
        raw = []
    for m in raw:
        if not isinstance(m, dict):
            continue
        mid = m.get("id") or m.get("name") or ""
        if mid:
            models.append(mid)
    for mid in models:
        print(mid)
except Exception:
    sys.exit(0)
PYEOF

  # Codex /models 返回的候选不等于当前 ChatGPT Subscription 账号可调用的模型。
  # 在展示菜单前逐一真实探测，只保留成功响应的模型。
  if [ "${CODECX_DETECTED:-false}" = "true" ] && [ -s /tmp/cakeclaw-models.txt ]; then
    : > /tmp/cakeclaw-codex-models.txt
    while IFS= read -r model_id; do
      [ -n "${model_id}" ] || continue
      info "验证 Codex 模型可用性: ${model_id}"
      if probe_codex_responses_model "${P_URL}" "${P_KEY}" "${model_id}"; then
        printf '%s\n' "${model_id}" >> /tmp/cakeclaw-codex-models.txt
      else
        info "已过滤当前账号不可用的 Codex 模型: ${model_id}"
      fi
    done < /tmp/cakeclaw-models.txt
    mv /tmp/cakeclaw-codex-models.txt /tmp/cakeclaw-models.txt
    [ -s /tmp/cakeclaw-models.txt ] || { info "没有通过当前 Codex 账号验证的模型，取消 provider"; rm -f /tmp/cakeclaw-models.txt; return 0; }
  fi

  # 让用户勾选模型
  if [ -s /tmp/cakeclaw-models.txt ]; then
    echo ""
    echo "  检测到以下模型，直接回车 = 全部加入；输入编号逗号分隔 = 只选部分；输入单个模型 id 也可："
    nl -ba /tmp/cakeclaw-models.txt
    prompt "  选择（回车=全部）: " SEL
    if [ -z "${SEL}" ]; then
      P_MODELS=$(paste -sd'\n' /tmp/cakeclaw-models.txt)
    else
      P_MODELS=""
      for n in $(echo "${SEL}" | tr ',' '\n'); do
        n="$(echo "${n}" | tr -d ' ')"
        [ -z "${n}" ] && continue
        line=$(sed -n "${n}p" /tmp/cakeclaw-models.txt 2>/dev/null)
        if [ -n "${line}" ]; then
          P_MODELS="${P_MODELS}${line}\n"
        else
          info "编号 ${n} 超出范围，已忽略"
        fi
      done
    fi
  else
    prompt "  未能自动拉取模型，请手动输入一个模型 id（如 gpt-4o-mini）: " P_MODELS
  fi
  rm -f /tmp/cakeclaw-models.txt

  [ -n "${P_MODELS}" ] || { info "未选择任何模型，取消 provider"; return 0; }

  # /models 能列出模型不代表 ChatGPT Subscription / Codex 账号有调用权限。
  # 对选中的每一个 Responses 模型实际探测；任一失败均不写入 Provider，避免部署后才报错。
  if [ "${CODECX_DETECTED:-false}" = "true" ]; then
    for model_id in ${P_MODELS}; do
      info "验证 Codex 模型可用性: ${model_id}"
      if ! probe_codex_responses_model "${P_URL}" "${P_KEY}" "${model_id}"; then
        info "Codex 模型 '${model_id}' 被当前账号或后端拒绝；Provider 未写入，请选择后端实际支持的模型后重试"
        return 0
      fi
    done
    ok "所选 Codex 模型均已通过 /v1/responses 实测"
  fi

  P_NAME="${P_NAME}" P_URL="${P_URL}" P_KEY="${P_KEY}" P_API="${P_API}" P_MODELS="${P_MODELS}" \
    P_API_VERSION="${P_API_VERSION}" \
  python3 - "${GWJSON}" << 'PYEOF'
import json, sys, os, tempfile

path = sys.argv[1]
with open(path, encoding="utf-8") as f:
    cfg = json.load(f)

providers = cfg.setdefault("models", {}).setdefault("providers", {})
name = os.environ.get("P_NAME", "").strip()
prov = {"baseUrl": os.environ.get("P_URL", "").strip(), "api": os.environ.get("P_API", "openai-completions").strip()}
key = os.environ.get("P_KEY", "").strip()
if key:
    prov["apiKey"] = key
models = [l for l in os.environ.get("P_MODELS", "").splitlines() if l.strip()]
if models:
    prov["models"] = [{"id": m.strip(), "name": m.strip()} for m in models]
providers[name] = prov

fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path), suffix=".tmp")
with os.fdopen(fd, "w", encoding="utf-8") as f:
    json.dump(cfg, f, indent=2, ensure_ascii=False)
    f.write("\n")
os.replace(tmp, path)
os.chown(path, 1000, 1000)
os.chmod(path, 0o600)
print(f"[configured provider] {name}")
PYEOF
  ok "provider '${P_NAME}' 已写入 openclaw.json（重启 Gateway 生效）"
  NEED_RESTART=true

  # 若本 provider 是 Codex 后端，12.5 内已挂补丁 + 写白名单，需重启才生效。
  # 这里仅打标记，最终由脚本完成段在前（所有配置落地后）统一重启一次。
  if [ "${CODECX_DETECTED:-false}" = "true" ]; then
    NEED_RESTART=true
  fi
}

# 非交互自动配置（CI / 无 TTY / 一键脚本）：通过 CAKECLAW_PROVIDER_* 环境变量（可写在 .env）
# 注入单个 provider，复用与交互流程完全相同的那段 python 原子 merge 逻辑，不覆盖已有字段。
# 若未提供 CAKECLAW_PROVIDER_BASE_URL 则不配置。
configure_provider_noninteractive() {
  GWJSON="/data/state/openclaw.json"
  [ -f "${GWJSON}" ] || { info "openclaw.json 不存在，跳过 provider 配置"; return 0; }

  local P_NAME="${CAKECLAW_PROVIDER_NAME:-}"
  local P_URL="${CAKECLAW_PROVIDER_BASE_URL:-}"
  local P_API="${CAKECLAW_PROVIDER_API:-openai-completions}"
  local P_KEY="${CAKECLAW_PROVIDER_KEY:-}"
  local P_MODELS_IN="${CAKECLAW_PROVIDER_MODELS:-}"

  [ -n "${P_URL}" ] || { info "未设置 CAKECLAW_PROVIDER_BASE_URL，跳过 provider 自动配置"; return 0; }
  [ -n "${P_NAME}" ] || P_NAME="my-provider"

  # 模型：优先用 CAKECLAW_PROVIDER_MODELS（逗号分隔）；为空则尝试自动拉 /models，仍空则跳过 models 字段
  local P_MODELS=""
  if [ -n "${P_MODELS_IN}" ]; then
    P_MODELS="$(echo "${P_MODELS_IN}" | tr ',' '\n' | sed '/^[[:space:]]*$/d')"
  else
    info "尝试自动拉取模型列表（baseUrl: ${P_URL}）..."
    P_URL="${P_URL}" P_KEY="${P_KEY}" python3 - << 'PYEOF' > /tmp/cakeclaw-models.txt 2>/dev/null || true
import json, os, sys, urllib.request
base = os.environ.get("P_URL", "").rstrip("/")
key = os.environ.get("P_KEY", "")
for u in (base + "/models", base.rstrip("/v1") + "/models"):
    try:
        req = urllib.request.Request(u)
        req.add_header("Authorization", f"Bearer {key}")
        with urllib.request.urlopen(req, timeout=15) as r:
            data = json.load(r)
        raw = data if isinstance(data, list) else data.get("data", [])
        for m in raw:
            if isinstance(m, dict) and (m.get("id") or m.get("name")):
                print(m.get("id") or m.get("name"))
        if raw:
            break
    except Exception:
        continue
PYEOF
    if [ -s /tmp/cakeclaw-models.txt ]; then
      P_MODELS="$(cat /tmp/cakeclaw-models.txt)"
      rm -f /tmp/cakeclaw-models.txt
    fi
  fi

  P_NAME="${P_NAME}" P_URL="${P_URL}" P_KEY="${P_KEY}" P_API="${P_API}" P_MODELS="${P_MODELS}" \
  python3 - "${GWJSON}" << 'PYEOF'
import json, sys, os, tempfile
path = sys.argv[1]
with open(path, encoding="utf-8") as f:
    cfg = json.load(f)
providers = cfg.setdefault("models", {}).setdefault("providers", {})
name = os.environ.get("P_NAME", "").strip()
prov = {"baseUrl": os.environ.get("P_URL", "").strip(), "api": os.environ.get("P_API", "openai-completions").strip()}
key = os.environ.get("P_KEY", "").strip()
if key:
    prov["apiKey"] = key
models = [l for l in os.environ.get("P_MODELS", "").splitlines() if l.strip()]
if models:
    prov["models"] = [{"id": m.strip(), "name": m.strip()} for m in models]
providers[name] = prov
fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path), suffix=".tmp")
with os.fdopen(fd, "w", encoding="utf-8") as f:
    json.dump(cfg, f, indent=2, ensure_ascii=False)
    f.write("\n")
os.replace(tmp, path)
os.chown(path, 1000, 1000)
os.chmod(path, 0o600)
print(f"[configured provider] {name}")
PYEOF
  ok "provider '${P_NAME}' 已写入 openclaw.json（重启 Gateway 生效）"
  NEED_RESTART=true
}

# 非交互环境（如 CI / 无 TTY）：有 CAKECLAW_PROVIDER_BASE_URL 则自动配置，否则才跳过
if $INTERACTIVE; then
  configure_provider
else
  if [ -n "${CAKECLAW_PROVIDER_BASE_URL:-}" ]; then
    configure_provider_noninteractive
  else
    info "非交互环境，且未设置 CAKECLAW_PROVIDER_BASE_URL，跳过模型 provider 配置"
  fi
fi

# ── 12.6 Telegram 机器人接入（可选）──
# 引导用户输入 Telegram bot token（来自 @BotFather）和一个或多个账号 ID，然后 merge 进
# openclaw.json 的 channels.telegram 段（幂等，不覆盖已有字段）。token 不写明文进 json，
# 而是写到一个仅供 Gateway 读取的专用文件（${TELEGRAM_TOKEN_FILE}），json 里用 tokenFile 引用。
step "12.6 Telegram 机器人接入"
configure_telegram() {
  GWJSON="/data/state/openclaw.json"
  [ -f "${GWJSON}" ] || { info "openclaw.json 不存在，跳过 Telegram 配置"; return 0; }

  echo ""
  echo "  配置 Telegram 机器人？ 直接回车跳过（稍后可在控制台 Config 手动配）"
  prompt "  是否配置 (y/N): " DO_TG
  case "${DO_TG}" in
    y|Y|yes|YES) : ;;
    *) info "跳过 Telegram 配置"; return 0 ;;
  esac

  echo ""
  echo "  提示：先在同 Telegram 里找 @BotFather → /newbot 创建机器人，拿到 token。"
  prompt "  Bot Token（形如 123456:ABC...）: " TG_TOKEN
  [ -n "${TG_TOKEN}" ] || { info "未填 Bot Token，跳过"; return 0; }

  # 账号 ID（allowFrom）：可单个或多个（逗号分隔/空格分隔）
  prompt "  允许访问的 Telegram 账号 ID（多个用逗号分隔，见 README 查 ID 方法）: " TG_ALLOW
  TG_ALLOW="$(echo "${TG_ALLOW}" | tr ',' ' ')"
  # 规整为逗号分隔的 id 列表
  TG_ALLOW_JSON=$(echo "${TG_ALLOW}" | tr ' ' '\n' | sed '/^[[:space:]]*$/d' | paste -sd',' -)

  # 写 token 到独立文件（不进 json），并 merge channels.telegram 段
  install -d -o 1000 -g 1000 -m 700 "${TELEGRAM_TOKEN_DIR}"
  printf '%s' "${TG_TOKEN}" > "${TELEGRAM_TOKEN_FILE}"
  chown 1000:1000 "${TELEGRAM_TOKEN_FILE}"
  chmod 600 "${TELEGRAM_TOKEN_FILE}"

  TG_ALLOW_JSON="${TG_ALLOW_JSON}" TELEGRAM_TOKEN_FILE="${TELEGRAM_TOKEN_FILE}" python3 - "${GWJSON}" << 'PYEOF'
import json, sys, os, tempfile
path = sys.argv[1]
with open(path, encoding="utf-8") as f:
    cfg = json.load(f)
ch = cfg.setdefault("channels", {})
tg = ch.setdefault("telegram", {})
tg["enabled"] = True
tg["tokenFile"] = os.environ["TELEGRAM_TOKEN_FILE"]
# dmPolicy：未显式配置时默认 allowlist（安全）；有 allowFrom 则 allowlist
allow = os.environ.get("TG_ALLOW_JSON", "").strip()
if allow:
    ids = [x.strip() for x in allow.split(",") if x.strip()]
    tg["allowFrom"] = ids
    tg["dmPolicy"] = "allowlist"
else:
    # 未填 ID：仍启用但用 pairing（首次 DM 需 approve），更安全
    tg["dmPolicy"] = "pairing"
fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path), suffix=".tmp")
with os.fdopen(fd, "w", encoding="utf-8") as f:
    json.dump(cfg, f, indent=2, ensure_ascii=False)
    f.write("\n")
os.replace(tmp, path)
os.chown(path, 1000, 1000)
os.chmod(path, 0o600)
print("[configured telegram]")
PYEOF
  ok "Telegram 机器人已写入 openclaw.json（重启 Gateway 生效）"
  info "Bot Token 已保存到 ${TELEGRAM_TOKEN_FILE}（权限 600，不写入 openclaw.json）"
  NEED_RESTART=true
}

# 非交互自动配置：通过 TELEGRAM_BOT_TOKEN / TELEGRAM_ALLOW_FROM 环境变量（可写在 .env）注入。
configure_telegram_noninteractive() {
  GWJSON="/data/state/openclaw.json"
  [ -f "${GWJSON}" ] || { info "openclaw.json 不存在，跳过 Telegram 配置"; return 0; }
  local TG_TOKEN="${TELEGRAM_BOT_TOKEN:-}"
  [ -n "${TG_TOKEN}" ] || { info "未设置 TELEGRAM_BOT_TOKEN，跳过 Telegram 自动配置"; return 0; }

  install -d -o 1000 -g 1000 -m 700 "${TELEGRAM_TOKEN_DIR}"
  printf '%s' "${TG_TOKEN}" > "${TELEGRAM_TOKEN_FILE}"
  chown 1000:1000 "${TELEGRAM_TOKEN_FILE}"
  chmod 600 "${TELEGRAM_TOKEN_FILE}"

  TG_ALLOW_JSON="${TELEGRAM_ALLOW_FROM:-}" TELEGRAM_TOKEN_FILE="${TELEGRAM_TOKEN_FILE}" python3 - "${GWJSON}" << 'PYEOF'
import json, sys, os, tempfile
path = sys.argv[1]
with open(path, encoding="utf-8") as f:
    cfg = json.load(f)
ch = cfg.setdefault("channels", {})
tg = ch.setdefault("telegram", {})
tg["enabled"] = True
tg["tokenFile"] = os.environ["TELEGRAM_TOKEN_FILE"]
allow = os.environ.get("TG_ALLOW_JSON", "").strip()
allow = allow.replace(" ", ",")  # 兼容空格分隔
if allow:
    ids = [x.strip() for x in allow.split(",") if x.strip()]
    tg["allowFrom"] = ids
    tg["dmPolicy"] = "allowlist"
else:
    tg["dmPolicy"] = "pairing"
fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path), suffix=".tmp")
with os.fdopen(fd, "w", encoding="utf-8") as f:
    json.dump(cfg, f, indent=2, ensure_ascii=False)
    f.write("\n")
os.replace(tmp, path)
os.chown(path, 1000, 1000)
os.chmod(path, 0o600)
print("[configured telegram]")
PYEOF
  ok "Telegram 机器人已写入 openclaw.json（重启 Gateway 生效）"
  info "Bot Token 已保存到 ${TELEGRAM_TOKEN_FILE}（权限 600，不写入 openclaw.json）"
  NEED_RESTART=true
}

# 默认交互询问；非交互环境则用环境变量自动配置。
if $INTERACTIVE; then
  configure_telegram
else
  if [ -n "${TELEGRAM_BOT_TOKEN:-}" ]; then
    configure_telegram_noninteractive
  else
    info "非交互环境，且未设置 TELEGRAM_BOT_TOKEN，跳过 Telegram 自动配置"
  fi
fi

# ── 12.7 OpenCode 安装（可选）──
# 交互式引导是否安装 OpenCode（终端 AI 编程代理，opencode.ai）。
# 安装方式：curl -fsSL https://opencode.ai/install | bash（官方推荐）。
# 非交互环境通过 OPENCODE_INSTALL=1 环境变量触发。
step "12.7 OpenCode 安装"
configure_opencode() {
  echo ""
  echo "  OpenCode 是开源的终端 AI 编程代理（opencode.ai），可直接在终端里与 AI 协作编码。"
  echo "  安装后输入 opencode 进入 TUI（终端交互界面），自带模型配置引导。"
  prompt "  是否安装 OpenCode (y/N): " DO_OC
  case "${DO_OC}" in
    y|Y|yes|YES)
      info "正在安装 OpenCode（官方 curl 安装）..."
      curl -fsSL https://opencode.ai/install | bash 2>&1 | tail -5
      ok "OpenCode 安装完成（输入 opencode 启动）"
      ;;
    *) info "跳过 OpenCode 安装"; return 0 ;;
  esac
}

# 默认交互询问；非交互环境则用 OPENCODE_INSTALL=1 环境变量触发。
if $INTERACTIVE; then
  configure_opencode
else
  if $OPENCODE_INSTALL; then
    info "非交互环境，OPENCODE_INSTALL=1，正在安装 OpenCode..."
    curl -fsSL https://opencode.ai/install | bash 2>&1 | tail -5
    ok "OpenCode 安装完成"
  else
    info "非交互环境，且未设置 OPENCODE_INSTALL=1，跳过 OpenCode 安装"
  fi
fi

# ── 12.8 重启生效（收尾） ──
# 若本次安装过程中有任何需要 Gateway 重启才能生效的改动（Codex 补丁、新增 provider、Telegram 接入），
# 在此处统一执行一次 up -d 并等 healthy。可避免在中间步骤反复重启，也保证跑完即最终态。
if $NEED_RESTART; then
  step "12.8 重启 Gateway 生效"
  info "检测到配置/补丁改动，重启 Gateway 使其生效..."
  docker compose -f /data/etc/openclaw/docker-compose.yml up -d 2>&1 || fail "Gateway 重启失败"
  wait_gateway_ready
fi

# ── 12.9 控制台验收 ──
step "12.9 控制台验收"
verify_control_ui

# ── 完成 ──
echo ""
echo "========================================"
echo -e "${GREEN}  cakeclaw 部署完成${NC}"
echo "========================================"
echo "  Gateway : 127.0.0.1:${GATEWAY_PORT}"
if [ -n "$DOMAIN" ]; then
  echo "  HTTPS 控制台 : https://${DOMAIN}"
else
  echo "  公网 Control UI : 未启用（远程 HTTP 无法完成设备认证）"
  echo "  本地控制台     : SSH 隧道后打开 http://127.0.0.1:${GATEWAY_PORT}/"
fi
echo ""
echo "  下一步："
echo "  1. 打开控制台 → Config 标签"
echo "  2. 若上面跳过了模型配置，可在 openclaw.json 手动添加 provider："
echo "     {"
echo "       \"models\": {"
echo "         \"providers\": {"
echo "           \"my-provider\": {"
echo "             \"baseUrl\": \"https://api.openai.com/v1\","
echo "             \"apiKey\": \"sk-xxx\""
echo "           }"
echo "         }"
echo "       }"
echo "     }"
echo "  3. 重启 Gateway 生效: docker restart cakeclaw-gateway"
echo "========================================"
