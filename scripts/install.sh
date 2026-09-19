#!/usr/bin/env bash
set -euo pipefail
# ============================================================
# OpenClaw 一键部署脚本
# 适用: Ubuntu 24.04 LTS / Debian 12+ (x86_64, 最小 2C/4G/20G)
# 用法: sudo ./scripts/install.sh [--with-mihomo] [--with-task-engine] [--with-sandbox]
# ============================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
fail() { echo -e "${RED}[FAIL]${NC} $*"; exit 1; }
ok()   { echo -e "${GREEN}[OK]${NC} $*"; }
info() { echo -e "${YELLOW}[INFO]${NC} $*"; }
step() { echo ""; echo -e "${GREEN}── ${1} ──${NC}"; }
# warn 此前只被调用、从未定义（16 处调用点全部失效）。因为多数调用位于
# `cmd || warn ...` 这类分支里，set -e 不会中断，脚本照常继续，
# 只在终端留下一行 "warn: command not found"——极易被当成噪声忽略。
# 结果是所有降级/自愈路径都失去了可见性（含挂载类型自愈、沙箱构建失败等）。
warn() { echo -e "${YELLOW}[WARN]${NC} $*" >&2; }

# 交互输入优先使用 stdin；若 stdin 被管道/重定向占用但当前仍有控制终端，
# 则从 /dev/tty 读取。这样 `curl ... | bash`、`... | tee` 等启动方式仍可提问；
# 真正无终端的 CI 则继续走环境变量自动配置。
INTERACTIVE=false
PROMPT_INPUT="/dev/stdin"
if [ -t 0 ]; then
  INTERACTIVE=true
elif [ -r /dev/tty ] && [ -w /dev/tty ] && { true < /dev/tty; } 2>/dev/null; then
  # 注意：setsid / nohup 下 /dev/tty 权限位是通的，但实际打开会失败（无控制终端）。
  # 因此这里必须「实际尝试打开」，只查 -r/-w 会误判为可交互，随后 read 报
  # "/dev/tty: No such device or address"。
  INTERACTIVE=true
  PROMPT_INPUT="/dev/tty"
fi

prompt() {
  local message="$1" variable="$2" value=""
  # stdin 本身是 TTY 时直接继承 FD 0；不要重新打开 /dev/stdin，部分移动 SSH
  # 环境会因此显示提示却无法接收键盘输入。仅重定向 stdin 时读取控制终端。
  # 无 TTY（nohup / setsid / CI 后台运行）时 /dev/tty 不可用，直接取默认值而非报错。
  if [ "${PROMPT_INPUT}" = "/dev/tty" ]; then
    if [ -c /dev/tty ] && { true < /dev/tty; } 2>/dev/null; then
      IFS= read -r -p "${message}" value < /dev/tty || value=""
    else
      value=""
    fi
  else
    IFS= read -r -p "${message}" value 2>/dev/null || value=""
  fi
  printf -v "${variable}" '%s' "${value}"
}


# ── 供应链校验 ──
# 原则：凡是"从网络取回、随后被当作代码执行或以 root 运行"的东西，都要验身份。
# 本项目有三类外部输入：① Docker apt 源签名密钥 ② 沙箱镜像构建文件 ③ 官方安装脚本。
# 能用指纹/校验和的就用，不能的（如 raw.githubusercontent 上的构建文件，官方未提供
# 发布校验和）就做到：固定 git ref（不用可变分支）+ 内容落盘后打印指纹供审计 + 失败即告警。
# 不假装这些检查比它们实际能做到的更严格。

# Docker 官方 apt 仓库签名密钥指纹（长期稳定，跨 ubuntu/debian 一致）。
# 校验它的意义：apt 之后会用它验证每一个 deb 包的签名，
# 所以这一条是整个 Docker 供应链的信任根——被替换则后面全是空谈。
DOCKER_GPG_FPR="9DC8 5822 9FC7 DD38 854A E2D8 8D81 803C 0EBF CD88"

# 验证一个 ASCII-armored PGP 公钥文件的主密钥指纹是否与期望一致。
# 需要 gpg（由调用方保证已安装）。返回 0 表示一致。
verify_gpg_fingerprint() {
  local keyfile="$1" expected="$2"
  local gnupg_home actual
  gnupg_home="$(mktemp -d)"
  # --show-keys 只解析不导入，避免污染宿主 keyring
  actual="$(gpg --homedir "$gnupg_home" --show-keys --with-colons --with-fingerprint "$keyfile" 2>/dev/null \
            | awk -F: '/^fpr:/ {print $10; exit}')"
  rm -rf "$gnupg_home"
  [ -n "$actual" ] || return 1
  # 归一化：去掉空格并大写后比较
  local a_norm e_norm
  a_norm="$(printf '%s' "$actual" | tr -d ' ' | tr '[:lower:]' '[:upper:]')"
  e_norm="$(printf '%s' "$expected" | tr -d ' ' | tr '[:lower:]' '[:upper:]')"
  [ "$a_norm" = "$e_norm" ]
}

# 打印文件的 SHA256 与实际大小，供部署后审计与异地比对。
# 用途：沙箱构建文件来自 raw.githubusercontent（官方未发布校验和），
# 无法"预先固定期望值"，但可以做到"每次都记录下来"，事后可比对是否被改动。
record_file_digest() {
  local f="$1"
  [ -f "$f" ] || return 0
  local digest size
  digest="$(sha256sum "$f" 2>/dev/null | awk '{print $1}')"
  size="$(wc -c < "$f" 2>/dev/null | tr -d ' ')"
  printf '%s  %s  (%s bytes)\n' "${digest:-N/A}" "$(basename "$f")" "${size:-0}"
}


# ── 环境变量体检 ──
# 读 /data/etc/openclaw/runtime.env 与 /data/state/openclaw.json，
# 逐个核对 openclaw.json 里所有 ${VAR} 引用是否真有值（非空、非占位符）。
#
# 分级依据来自实测：测试机上 Gateway healthy、cron 齐备、安装日志全绿，
# 但发消息时报 "Outbound not configured for channel: telegram"——
# 因为 TELEGRAM_BOT_TOKEN 在 openclaw.json 里是 ${TELEGRAM_BOT_TOKEN}，
# 而 runtime.env 里该键为空。健康检查不覆盖业务通道，所以这类缺失不会被发现。
#
# 退出码：0 = 全部就绪；2 = 有严重/重要缺失（功能不可用）；其他 = 体检本身失败。
env_health_check() {
  local rc=0
  python3 - <<'PYEOF_ENVHEALTH' || rc=$?
import json, re, sys

RUNTIME_ENV = "/data/etc/openclaw/runtime.env"
OPENCLAW_JSON = "/data/state/openclaw.json"

# 1) 读取 runtime.env 中已设的变量（非注释、含 = 的行）
env_set = {}
try:
    with open(RUNTIME_ENV) as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            k, v = line.split("=", 1)
            env_set[k.strip()] = v.strip().strip('"').strip("'")
except FileNotFoundError:
    print(f"  [WARN] 找不到 {RUNTIME_ENV}，跳过体检")
    sys.exit(0)

def is_unset(v):
    """空值或占位符都算未就绪。"""
    if not v:
        return True
    return bool(re.search(r"YOUR_[A-Z0-9_]*_?HERE|CHANGEME|REPLACE_ME|PLACEHOLDER|XXX+", v, re.I))

# 2) 收集 openclaw.json 里所有 ${VAR} 引用及其出现位置
refs = {}
try:
    with open(OPENCLAW_JSON) as f:
        data = json.load(f)
except FileNotFoundError:
    print(f"  [WARN] 找不到 {OPENCLAW_JSON}，跳过体检")
    sys.exit(0)
except json.JSONDecodeError as e:
    print(f"  [!!] {OPENCLAW_JSON} 不是合法 JSON: {e}")
    sys.exit(1)

def walk(o, path=""):
    if isinstance(o, dict):
        for k, v in o.items():
            walk(v, f"{path}.{k}" if path else k)
    elif isinstance(o, list):
        for i, v in enumerate(o):
            walk(v, f"{path}[{i}]")
    elif isinstance(o, str):
        for m in re.finditer(r"\$\{([A-Za-z_][A-Za-z0-9_]*)\}", o):
            refs.setdefault(m.group(1), set()).add(path or "(根)")

walk(data)

# 3) 影响分级。写死这四个是因为它们直接决定"核心功能是否哑掉"，
#    其余变量缺失只影响可选能力，不值得让运维紧张。
CRITICAL = {
    "TELEGRAM_BOT_TOKEN": "Telegram 出站消息完全发不出去（Outbound not configured for channel）",
    "TELEGRAM_OWNER_ID":  "Telegram 侧无法识别 owner：allowFrom 与 elevated 工具均失效",
}
IMPORTANT = {
    "TAVILY_API_KEY": "agent 的联网搜索工具不可用",
    "GH_TOKEN":       "sandbox 内访问 GitHub 不可用（git clone/push、gh 命令）",
}

crit, imp, opt = [], [], []
for var in sorted(refs):
    if not is_unset(env_set.get(var, "")):
        continue
    item = (var, sorted(refs[var])[:2])
    if var in CRITICAL:
        crit.append(item)
    elif var in IMPORTANT:
        imp.append(item)
    else:
        opt.append(item)

ready = len(refs) - len(crit) - len(imp) - len(opt)
print(f"  openclaw.json 引用了 {len(refs)} 个环境变量，其中 {ready} 个已就绪。")
print()

if crit:
    print("  【严重】缺这些会让核心功能不可用：")
    for var, uses in crit:
        print(f"    - {var}")
        print(f"        影响: {CRITICAL[var]}")
        print(f"        引用位置: {', '.join(uses)}")
    print()

if imp:
    print("  【重要】缺这些会削弱 agent 能力：")
    for var, uses in imp:
        print(f"    - {var}  → {IMPORTANT[var]}")
    print()

if opt:
    print(f"  【可选】未设置（不影响启动）：{', '.join(v for v, _ in opt)}")
    print()

if crit or imp:
    print("  修复：编辑 /data/etc/openclaw/runtime.env 填入真实值，然后")
    print("        docker compose -f /data/etc/openclaw/docker-compose.yml up -d")
    print("        可单独复检：sudo ./scripts/install.sh --env-check")
    sys.exit(2)

print("  [OK] 所有被引用的环境变量均已就绪")
sys.exit(0)
PYEOF_ENVHEALTH

  case "$rc" in
    0) info "环境变量体检通过" ;;
    2)
      warn "存在未配置的关键环境变量——Gateway 能起来，但部分功能不可用"
      warn "这是配置缺失，不是安装故障；清单见上方。"
      ;;
    *) warn "环境变量体检未能完成（见上方输出）" ;;
  esac
  return "$rc"
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
    HS=$(docker inspect --format '{{.State.Health.Status}}' openclaw-gateway 2>/dev/null || echo "no-health")
    case "${HS}" in
      healthy)
        ok "Gateway 已就绪 (healthy, ${i}x5s)"
        READY=true
        break
        ;;
      unhealthy)
        docker logs openclaw-gateway --tail 30 2>&1
        fail "Gateway 健康检查失败 (unhealthy)"
        ;;
      starting|no-health) : ;;
      *)
        docker logs openclaw-gateway --tail 30 2>&1
        fail "Gateway 状态异常: ${HS}"
        ;;
    esac
  done
  if [ "${READY}" != true ]; then
    docker logs openclaw-gateway --tail 30 2>&1
    fail "Gateway 未在 180s 内变为 healthy"
  fi
}

# ── 0. 参数解析 ──
HELP=false
NEED_RESTART=false
WITH_MIHOMO=false
MIHOMO_DECIDED=false      # 用户是否显式表态（显式则跳过自动探测）
WITH_TASK_ENGINE=false
WITH_SANDBOX=false
ENV_CHECK_ONLY=false
MIHOMO_AUTO_DETECT="${MIHOMO_AUTO_DETECT:-1}"
for arg in "$@"; do
  case "$arg" in
    --with-mihomo) WITH_MIHOMO=true; MIHOMO_DECIDED=true ;;
    --without-mihomo|--no-mihomo) WITH_MIHOMO=false; MIHOMO_DECIDED=true ;;
    --with-task-engine) WITH_TASK_ENGINE=true ;;
    --with-sandbox) WITH_SANDBOX=true ;;
    --env-check) ENV_CHECK_ONLY=true ;;
    --help|-h)   HELP=true ;;
    *) fail "未知参数: $arg。支持的参数: --with-mihomo --without-mihomo --with-task-engine --with-sandbox --env-check --help" ;;
  esac
done
if $HELP; then
  echo "用法: sudo ./scripts/install.sh [选项]"
  echo "  --with-mihomo       强制启用 mihomo TUN 代理 sidecar（境内机出海）"
  echo "  --without-mihomo    强制禁用 mihomo（海外机直连，默认按实测自动判定）"
  echo "  --with-task-engine  启用任务引擎（taskctl + taskboard + stale guard）"
  echo "  --with-sandbox      启用 docker.sock 挂载（用于 OpenClaw 沙箱）"
  echo "  --env-check         只做环境变量体检后退出（不安装、不改动任何文件）"
  echo "  --help              显示此帮助"
  echo ""
  echo "说明：不传 mihomo 开关时，安装脚本会实测能否直连 GitHub——"
  echo "      能直连（海外机）则跳过 mihomo；不能（境内机）则自动启用。"
  exit 0
fi

# ── 0. 仅体检模式 ──
# 把体检抽成独立入口的价值：装完之后配置是会被改的（轮换 token、临时摘掉某个 key）。
# 只有完整安装才能体检的话，运维不会为了查一个变量去重跑安装。
if $ENV_CHECK_ONLY; then
  step "环境变量体检（--env-check，只读，不做任何改动）"
  env_health_check
  exit $?
fi

# ── 1. 特权检查 ──
if [ "$(id -u)" -ne 0 ]; then fail "请用 sudo 执行"; fi

# ── 2. 加载配置（.env 可选）──
cd "$PROJECT_DIR"
if [ -f .env ]; then
  # 只提取合法 KEY=VALUE 行（允许空值，如 GATEWAY_MEM_LIMIT=），忽略注释/空行/非法行。
  # 逐行 export 而非 `set -a; source`：避免 (1) set -a 把所有变量全局导出污染后续子进程；
  # (2) source 对 .env 里意外出现的 export 语句/多行值/特殊字符产生副作用。
  #
  # 行尾注释：仅在「空白 + #」时剥离。这样 `DOCKER_GROUP_ID=999  # 说明` 会正确取到 999，
  # 而值里自带的 #（如 `PASS=a#b`）不受影响。剥离后两端去空白。
  # 这曾是真实事故：模板里的行尾注释被当成值的一部分传给 docker，报
  #   "unable to find group 999  # stat -c ...: no matching entries in group file"
  while IFS='=' read -r key value; do
    case "${key}" in
      ''|\#*) continue ;;  # 空键或注释行，跳过
      *[!A-Za-z0-9_]*) continue ;;  # 非法键名，跳过
    esac
    # 剥离行尾注释（空白 + # 起），再去掉首尾空白
    value="$(printf '%s' "${value}" | sed -E 's/[[:space:]]+#.*$//' | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')"
    export "${key}=${value}"
  done < <(grep -E '^[A-Za-z_][A-Za-z0-9_]*=' .env)
  info "已加载 .env"
else
  info ".env 未找到，使用默认值。部署后可在 openclaw.json 配置 API Key + URL"
  [ -f .env.example ] && cp .env.example .env 2>/dev/null || true
fi

# 默认值
DOMAIN="${DOMAIN:-}"
GATEWAY_IMAGE="${GATEWAY_IMAGE:-ghcr.io/openclaw/openclaw:2026.9.4}"
MIHOMO_IMAGE="${MIHOMO_IMAGE:-metacubex/mihomo:latest}"
DOCKER_GROUP_ID="${DOCKER_GROUP_ID:-}"
# .env 里显式写 MIHOMO_ENABLE 也算用户表态（0=强制关，1=强制开），跳过自动探测
case "${MIHOMO_ENABLE:-}" in
  1) WITH_MIHOMO=true;  MIHOMO_DECIDED=true ;;
  0) WITH_MIHOMO=false; MIHOMO_DECIDED=true ;;
esac
[ "${TASK_ENGINE_ENABLE:-}" = "1" ] && WITH_TASK_ENGINE=true
[ "${SANDBOX_ENABLE:-}" = "1" ] && WITH_SANDBOX=true

# ── 出口自动判定：境内机才需要 mihomo，海外机直连即可 ──
# mihomo TUN sidecar 的唯一职责是「在无法直连 GitHub / 模型 API 的机器上提供出海出口」。
# 海外 VPS（AWS/GCP/DO 等）本来就能直连，套一层 TUN 只会：多一个容器、多一个故障点
# （netns 失效、节点挂掉）、还平白增加资源开销。所以这里以实测为准自动决策，
# 不让使用者为「自己是境内还是海外」这种机器自己就知道的事做选择。
#
# 判定方式：HEAD 请求探 GitHub（HTTP 层可达即算直连可用），超时 6s。
# 显式传了 --with-mihomo / --without-mihomo 或 .env 里 MIHOMO_ENABLE 时，尊重用户选择。
if [ "${MIHOMO_AUTO_DETECT}" = "1" ] && ! $MIHOMO_DECIDED; then
  if ! curl -fsS -o /dev/null --max-time 6 https://github.com 2>/dev/null; then
    info "直连 GitHub 失败 → 判定为境内机，自动启用 mihomo 出海代理"
    WITH_MIHOMO=true
  else
    info "直连 GitHub 正常 → 判定为海外机，跳过 mihomo（直连即出口）"
  fi
fi
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
GATEWAY_IMAGE="${GATEWAY_IMAGE:-ghcr.io/openclaw/openclaw:2026.9.4}"
SSH_PORT="${SSH_PORT:-22}"
BACKUP_RETENTION_DAYS="${BACKUP_RETENTION_DAYS:-7}"
CONN_LIMIT="${CONN_LIMIT:-15}"
SWAP_SIZE="${SWAP_SIZE:-2G}"
# Telegram 机器人接入（可选）：见 README
# 交互环境默认询问；非交互环境用 TELEGRAM_BOT_TOKEN / TELEGRAM_ALLOW_FROM 环境变量。
TELEGRAM_TOKEN_DIR="/data/etc/openclaw/telegram"
TELEGRAM_TOKEN_FILE="${TELEGRAM_TOKEN_DIR}/bot-token"
TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-}"
TELEGRAM_ALLOW_FROM="${TELEGRAM_ALLOW_FROM:-}"

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
  # 先落到临时文件，校验指纹通过才启用——避免"先信任后检查"。
  DOCKER_GPG_TMP="$(mktemp)"
  if curl -fsSL "https://download.docker.com/linux/${DOCKER_DISTRO}/gpg" -o "$DOCKER_GPG_TMP"; then
    if verify_gpg_fingerprint "$DOCKER_GPG_TMP" "$DOCKER_GPG_FPR"; then
      install -m 0644 "$DOCKER_GPG_TMP" /etc/apt/keyrings/docker.asc
      ok "Docker 仓库签名密钥指纹校验通过"
    else
      rm -f "$DOCKER_GPG_TMP"
      fail "Docker 仓库签名密钥指纹不匹配！
  期望: ${DOCKER_GPG_FPR}
  可能是网络劫持/MITM，或官方轮换了密钥。
  已中止安装。若确认官方轮换，请更新 install.sh 中的 DOCKER_GPG_FPR 后重跑。"
    fi
  else
    rm -f "$DOCKER_GPG_TMP"
    fail "无法下载 Docker 仓库签名密钥（网络问题？）。拒绝在无签名校验的情况下继续安装 Docker。"
  fi
  rm -f "$DOCKER_GPG_TMP"
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

# logrotate：日志轮转（运维矩阵与网关日志会让 /data/logs/*.log 持续增长）
if ! command -v logrotate >/dev/null 2>&1; then
  apt-get install -y logrotate >/dev/null 2>&1 || info "logrotate 安装失败（跳过，日志可能无限增长）"
fi

# ── 3. 目录结构 ──
step "3. 创建目录"
# 统一 workspace 路径为 /data/state/workspace，同时保留 /data/workspace 软链兼容旧脚本
mkdir -p /data/state/workspace
[ -e /data/workspace ] || ln -sfn /data/state/workspace /data/workspace
for d in /data/backups/openclaw-state /data/backups/nightly /data/logs /data/scripts /data/etc/openclaw /data/etc/mihomo /data/var/lib/openclaw; do
  mkdir -p "$d"
done
chmod 700 /data/backups /data/state /data/etc/openclaw /data/var/lib/openclaw
chmod 755 /data/state/workspace /data/logs /data/scripts
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

# 占位符落值：模板里所有 ${XXX} 都是「运行时由 OpenClaw 自己从 env 展开」的语法，
# 唯独 PRIMARY_MODEL / FALLBACK_MODEL 这两个必须在写盘前定死——它们决定了 agents.defaults.model
# 的结构，若留空会渲染出非法 JSON（fallbacks: [""]）。这里做一遍结构化清洗，
# 而不是用 sed 盲替，避免把别处的字符串误伤。
#
# 清洗规则：
#   1. ${PRIMARY_MODEL} 未配置 → 移除 model.primary（让用户后续在控制台选）
#   2. ${FALLBACK_MODEL} 未配置 → 整个移除 model.fallbacks 数组（不要留空串）
#   3. agents.defaults 顶层若残留 fallbacks（旧模板位置）→ 并入 model.fallbacks 后删除
PRIMARY_MODEL="${PRIMARY_MODEL:-}" FALLBACK_MODEL="${FALLBACK_MODEL:-}" \
  python3 - /data/state/openclaw.json << 'PYEOF_MODEL'
import json, os, sys, tempfile

path = sys.argv[1]
with open(path, encoding="utf-8") as f:
    cfg = json.load(f)

defaults = cfg.get("agents", {}).get("defaults")
if isinstance(defaults, dict):
    model = defaults.get("model")
    if not isinstance(model, dict):
        model = {}
        defaults["model"] = model

    def resolve(val):
        """把 ${VAR} 形式解析成环境变量值；解析不出（未设置）返回 None。"""
        if not isinstance(val, str):
            return None
        v = os.path.expandvars(val).strip()
        # expandvars 对未定义变量会原样保留 ${X}，据此判定未设置
        if not v or ("${" in v):
            return None
        return v

    primary = resolve(model.get("primary"))
    if primary:
        model["primary"] = primary
    else:
        model.pop("primary", None)

    # fallbacks 可能来自 model.fallbacks，也可能是旧版模板残留在 defaults 顶层
    raw_fb = model.get("fallbacks")
    if not isinstance(raw_fb, list):
        raw_fb = []
    legacy_fb = defaults.pop("fallbacks", None)
    if isinstance(legacy_fb, list):
        raw_fb = list(legacy_fb) + list(raw_fb)

    fb = [r for r in (resolve(x) for x in raw_fb) if r]
    if fb:
        model["fallbacks"] = fb
    else:
        model.pop("fallbacks", None)   # 关键：不能留 [""]

    # model 为空对象时删掉，免得 schema 报 model: 需要 primary
    if not model:
        defaults.pop("model", None)

fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path), suffix=".tmp")
with os.fdopen(fd, "w", encoding="utf-8") as f:
    json.dump(cfg, f, indent=2, ensure_ascii=False)
    f.write("\n")
os.replace(tmp, path)
os.chown(path, 1000, 1000)
os.chmod(path, 0o600)
print("[model] primary=%s fallbacks=%s" % (primary or "(unset)", fb or "(none)"))
PYEOF_MODEL
ok "模型占位符已落值（未配置则留待控制台设置）"

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
chmod 600 /data/etc/openclaw/runtime.env
chown -R 1000:1000 /data/state /data/workspace 2>/dev/null || true
ok "密钥已写入 /data/etc/openclaw/runtime.env"

# ── 6. 拉镜像 & 启动 ──
step "6. 部署 Gateway"
docker pull "${GATEWAY_IMAGE}" 2>&1 | tail -3

# 补丁必须在启动容器【之前】就位：compose 的 entrypoint 指向
# /data/opt/openclaw-patches/entrypoint.sh，容器启动时即执行。
# 若放到 §10.7 再装，容器会以
#   exec: "/data/opt/openclaw-patches/entrypoint.sh": no such file or directory
# 启动失败——这是顺序依赖，不是可选步骤。
mkdir -p /data/opt/openclaw-patches
if compgen -G "$PROJECT_DIR/openclaw-patches/*.sh" > /dev/null; then
  cp "$PROJECT_DIR"/openclaw-patches/*.sh /data/opt/openclaw-patches/
  chmod +x /data/opt/openclaw-patches/*.sh
  ok "启动补丁已就位（/data/opt/openclaw-patches）"
else
  # 兜底：补丁文件缺失时移除 entrypoint 覆盖，用镜像默认入口启动，
  # 至少让 Gateway 可用（代价是失去工具预算补丁与孤儿锁清理，会在收尾告警）。
  warn "缺少 openclaw-patches/*.sh，移除 compose entrypoint 覆盖（将失去启动期补丁）"
  ENTRYPOINT_STRIPPED=true
fi

# docker CLI 包装必须在 compose up 【之前】就位。
#
# 顺序依赖（与 §10.7a 的 task-engine 同类）：compose 把
#   /data/opt/docker-cli/docker -> /usr/local/bin/docker
# 作为 bind mount。若容器创建时该宿主路径【不存在】，Docker 会按其挂载目标
# 的形态自动创建——这里会创建一个【目录】；而 §10.7 随后会把它重写成
# 【文件】（包装脚本）。容器记录的挂载类型就此与宿主永久不一致，之后任何
# 重启都直接失败：
#   error mounting ".../docker" ... not a directory: Are you trying to mount
#   a directory onto a file (or vice-versa)?
# 该错误以 exit 127 退出，读起来像"命令不存在"，完全指不到真实原因；
# 且首次开机时容器是"成功创建"的，不会触发任何启动期自愈。
# 因此必须在 up 之前先把包装文件落位。
install_docker_cli() {
  mkdir -p /data/opt/docker-cli
  local host_docker="" cand
  for cand in "$(command -v docker 2>/dev/null)" /usr/bin/docker /usr/local/bin/docker /bin/docker; do
    [ -n "$cand" ] || continue
    # -f 且 -x：既要是普通文件，又要有执行权限；目录/悬空链接一律跳过
    if [ -f "$cand" ] && [ -x "$cand" ]; then host_docker="$cand"; break; fi
  done
  if [ -z "$host_docker" ]; then
    warn "未找到可执行的宿主 docker（command -v 返回的可能是目录），跳过 docker-cli 包装"
    return 0
  fi
  # 幂等：历史版本可能把这两条路径误建成「目录」（cp 的经典陷阱：目标若是
  # 目录，cp 会拷进去而不是覆盖）。-rf 同时覆盖文件与目录两种历史形态。
  # 关键：必须是【文件】——类型错了容器就再也起不来。
  rm -rf /data/opt/docker-cli/docker /data/opt/docker-cli/docker.real
  cp "$host_docker" /data/opt/docker-cli/docker.real
  # wrapper 必须用【相对自身位置】解析真实二进制，不能写死绝对路径：
  # 同一个文件被 compose 挂到两个视角下的不同路径——
  #   宿主      : /data/opt/docker-cli/docker.real
  #   容器/沙箱 : /usr/local/bin/docker.real
  # 写死任一个都会在另一个视角下找不到可执行文件：
  #   /usr/local/bin/docker: 3: exec: /data/opt/docker-cli/docker.real: not found
  # 用 dirname "$0" 让两条路径自动成立。
  cat > /data/opt/docker-cli/docker <<'DOCKEREOF'
#!/bin/sh
# 沙箱内 docker CLI 包装：默认走宿主 docker.sock。
# 按自身所在目录解析 docker.real，兼容宿主与容器两个挂载视角。
exec "$(dirname "$0")/docker.real" "$@"
DOCKEREOF
  chmod +x /data/opt/docker-cli/docker /data/opt/docker-cli/docker.real
  ok "docker-cli 包装已就位（源: ${host_docker}）"
}
install_docker_cli

# 生成 docker-compose.yml（持久化，避免 /tmp 被清）
# 用 sed 替换模板中的 YOUR_* 占位符（比 envsubst 更直观，占位符即文档）。
COMPOSE_FILE="/data/etc/openclaw/docker-compose.yml"
# 直接用完整镜像名替换（用户可能用任意镜像站，如 ghcr.nju.edu.cn/openclaw/openclaw:tag），
# 不能只取 tag 拼接——那会把仓库名带进去，拼出 .../openclaw:openclaw:tag 这种非法引用。
#
# DOCKER_GROUP_ID 必须是纯数字：Compose 会把它当 GID 解析，非数字会以
#   "unable to find group <值>: no matching entries in group file"
# 直接拒绝启动整个 stack。
#
# 取值优先级：显式配置 > 实测 socket 属组。
# 注意：这里【不能】给一个数字兜底（旧版写 999）。因为下面的一致性检查
# 只看"是不是数字"，一个合法的数字兜底会让实测分支永远不执行——
# 实测 socket 属组在多数发行版上并不是 999（Docker 官方包常见 988/998/
# 其它值），于是容器以错误的附加组启动，沙箱内一调 docker 就：
#   permission denied while trying to connect to the docker API
#   at unix:///var/run/docker.sock
# 所以未显式配置时留空，交由实测决定。
DOCKER_GROUP_ID="$(printf '%s' "${DOCKER_GROUP_ID:-}" | tr -d '[:space:]')"
SOCKET_GID="$(stat -c '%g' /var/run/docker.sock 2>/dev/null || true)"
if ! printf '%s' "${DOCKER_GROUP_ID}" | grep -qE '^[0-9]+$'; then
  [ -n "${DOCKER_GROUP_ID}" ] && warn "DOCKER_GROUP_ID='${DOCKER_GROUP_ID}' 非数字，已回退为实测 socket 属组"
  DOCKER_GROUP_ID="${SOCKET_GID:-999}"
else
  # 显式配置了数字，但与本机 socket 属组不一致时给出提示（不强制覆盖：
  # 用户可能刻意对齐到一个宿主组名，属于高级用法）。
  if [ -n "${SOCKET_GID}" ] && [ "${DOCKER_GROUP_ID}" != "${SOCKET_GID}" ]; then
    warn "DOCKER_GROUP_ID=${DOCKER_GROUP_ID} 与本机 docker.sock 属组 ${SOCKET_GID} 不一致；若沙箱内 docker 报 permission denied，请改为 ${SOCKET_GID}"
  fi
fi
info "docker.sock 属组: ${DOCKER_GROUP_ID}（宿主实测 ${SOCKET_GID:-未知}）"
# Telegram API 死 IP：仅境内机（TUN 模式）需要钉住防 DNS 污染；海外机直连不需要。
TELEGRAM_API_IP=""
if $WITH_MIHOMO; then
  TELEGRAM_API_IP="$(getent hosts api.telegram.org 2>/dev/null | awk '{print $1; exit}')"
  [ -z "$TELEGRAM_API_IP" ] && TELEGRAM_API_IP="149.154.166.110"
fi
# Compose 子网：避开常见冲突段，取一段私有地址。
COMPOSE_SUBNET="${COMPOSE_SUBNET:-192.168.16.0/24}"
sed -e "s|YOUR_GATEWAY_IMAGE|${GATEWAY_IMAGE}|g" \
    -e "s|YOUR_MIHOMO_IMAGE|${MIHOMO_IMAGE}|g" \
    -e "s|YOUR_DOCKER_GROUP_ID|${DOCKER_GROUP_ID}|g" \
    -e "s|YOUR_GATEWAY_MEM_LIMIT|${GATEWAY_MEM_LIMIT}|g" \
    -e "s|YOUR_GATEWAY_CPU_LIMIT|${GATEWAY_CPU_LIMIT}|g" \
    -e "s|YOUR_GATEWAY_PID_LIMIT|${GATEWAY_PID_LIMIT}|g" \
    -e "s|YOUR_COMPOSE_SUBNET|${COMPOSE_SUBNET}|g" \
    "$PROJECT_DIR/docker-compose.yml" > "${COMPOSE_FILE}"
# telegram 死 IP 与 extra_hosts：海外机整段移除（直连即可，钉 IP 反而易失效）
if [ -z "$TELEGRAM_API_IP" ]; then
  python3 - "${COMPOSE_FILE}" << 'PYEOF_TG'
import sys, re
path = sys.argv[1]
text = open(path, encoding="utf-8").read()
text = re.sub(r"\n    extra_hosts:\n(?:      #.*\n|      - \"[^\"]*\"\n)+", "\n", text)
open(path, "w", encoding="utf-8").write(text)
print("extra_hosts removed (direct egress, no TUN)")
PYEOF_TG
else
  sed -i "s|YOUR_TELEGRAM_API_IP|${TELEGRAM_API_IP}|g" "${COMPOSE_FILE}"
fi
# 防御：确认模板里的所有 YOUR_* 占位符都已被替换，没有残留。
# 只检查非注释行：注释里可能提到占位符写法，不应视为渲染失败。
if grep -vE '^\s*#' "${COMPOSE_FILE}" | grep -qE 'YOUR_[A-Z_]+'; then
  fail "docker-compose 生成失败：存在未替换的占位符。残留: $(grep -vE '^\s*#' "${COMPOSE_FILE}" | grep -oE 'YOUR_[A-Z_]+' | sort -u | tr '\n' ' ')"
fi
chmod 600 "${COMPOSE_FILE}"

# 若补丁缺失，剥离 gateway 的 entrypoint 覆盖（见 §6 兜底逻辑）
if [ "${ENTRYPOINT_STRIPPED:-false}" = "true" ]; then
  python3 - "${COMPOSE_FILE}" << 'PYEOF_EP'
import sys, re
path = sys.argv[1]
text = open(path, encoding="utf-8").read()
text = re.sub(r'\n    entrypoint: \["/data/opt/openclaw-patches/entrypoint\.sh"\]', '', text, count=1)
open(path, "w", encoding="utf-8").write(text)
print("entrypoint override stripped (patches missing)")
PYEOF_EP
fi

# 若未启用沙箱，移除 docker.sock 挂载以降低攻击面
if ! $WITH_SANDBOX; then
  python3 - "${COMPOSE_FILE}" << 'PYEOF'
import sys
path = sys.argv[1]
with open(path, encoding="utf-8") as f:
    lines = f.readlines()
filtered = []
in_gateway_volumes = False
for line in lines:
    stripped = line.strip()
    if stripped == "volumes:" and line.startswith("    "):
        in_gateway_volumes = True
        filtered.append(line)
        continue
    if in_gateway_volumes:
        if stripped.startswith("-") and "docker.sock" in line:
            continue
        if stripped == "" or (not line.startswith("      ") and not line.startswith("    volumes:")):
            in_gateway_volumes = False
    filtered.append(line)
with open(path, "w", encoding="utf-8") as f:
    f.writelines(filtered)
print("docker.sock mount removed (--without-sandbox)")
PYEOF
fi

# 若未启用 mihomo，移除 mihomo-tun 服务块（含 profiles: ["mihomo"]）
if ! $WITH_MIHOMO; then
  python3 - "${COMPOSE_FILE}" << 'PYEOF'
import sys, re
path = sys.argv[1]
with open(path, encoding="utf-8") as f:
    text = f.read()
# 删除从 "  # mihomo TUN 代理 sidecar" 注释到下一个顶层 service 之前的内容
text = re.sub(r"\n  # mihomo TUN 代理 sidecar.*?(?=\n  # 可选：gateway 健康兜底|\nnetworks:|\nvolumes:)",
              "\n", text, flags=re.S)
with open(path, "w", encoding="utf-8") as f:
    f.write(text)
print("mihomo-tun service removed (--without-mihomo)")
PYEOF
fi

# 未启用 mihomo（海外机直连）时，模型 provider 走直连出口；Telegram 亦直连。
# 但模板里 channels.telegram.enabled 默认为 true，若用户没配 botToken，
# Gateway 会因空 token 反复重启。这里在启动前统一矫正：没有有效 bot token 就置 enabled=false。
python3 - /data/state/openclaw.json "${TELEGRAM_BOT_TOKEN}" << 'PYEOF_TGDIS'
import json, os, sys, tempfile
path, tg_token = sys.argv[1], (sys.argv[2] if len(sys.argv) > 2 else "")
if not os.path.exists(path):
    sys.exit(0)
with open(path, encoding="utf-8") as f:
    cfg = json.load(f)
tg = cfg.get("channels", {}).get("telegram")
if isinstance(tg, dict):
    # 只有真给了 token（或已存在 tokenFile）才允许 enabled=true
    has_token = bool(tg_token.strip()) or bool(tg.get("tokenFile"))
    if not has_token:
        tg["enabled"] = False
        fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path), suffix=".tmp")
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            json.dump(cfg, f, indent=2, ensure_ascii=False)
            f.write("\n")
        os.replace(tmp, path)
        os.chown(path, 1000, 1000)
        os.chmod(path, 0o600)
        print("[telegram] no bot token configured -> channels.telegram.enabled=false")
    else:
        print("[telegram] bot token present -> channels.telegram enabled")
PYEOF_TGDIS

COMPOSE_PROFILES=""
$WITH_MIHOMO && COMPOSE_PROFILES="${COMPOSE_PROFILES} --profile mihomo"

# 启动 Gateway，并对「挂载类型冲突」做一次自愈重试。
#
# 背景：Docker 在创建容器时会把 bind mount 的类型（文件 vs 目录）固化下来。
# 若宿主侧路径类型后来变了（典型场景：早期版本把 /data/opt/docker-cli/docker
# 误建成目录，后续修复成文件），复用旧容器会在容器初始化阶段直接失败：
#   error mounting ".../docker" ... not a directory: Are you trying to mount
#   a directory onto a file (or vice-versa)?
# 这个错误以 exit 127 退出，读起来像"命令不存在"，完全指不到真实原因。
#
# 两道防线：
#   A. 事前预检（精确）——读取现存容器记录的挂载列表，逐条比对宿主当前类型。
#      Docker inspect 的 .Mounts[].Type 是 bind，但容器创建时固化的
#      "目标是文件还是目录"体现为容器内路径是否存在且为目录。这里用
#      docker exec 探测容器内路径类型；容器已停止时退化为读取
#      HostConfig.Binds 中是否带 /dir 结尾等线索不可靠，
#      因此改用最可靠的信号：宿主路径若是【目录】而容器曾把它挂到
#      bin 目录下的同名路径，几乎必然冲突（docker-cli 是唯一此类挂载）。
#   B. 事后自愈——up 失败且输出含挂载类型冲突签名时，删容器重建。
# 上游修复（§6 提前安装 docker-cli 包装）已让新建机器不再产生该不一致，
# 这里是为存量机器与用户手动改动兜底。
#
# A. 事前预检：若 compose 声明了「宿主文件 -> 容器 bin 路径」的挂载，
#    而宿主侧当前是【目录】，Docker 一定是在首次 up 时把它当目录建出来的，
#    容器记录的类型已错 → 直接删容器，让本次 up 按文件类型重建。
COMPOSE_MOUNT_CONFLICT=false
for bind_src in $(sed -nE 's#^ *- *(/[^:]+):/(usr/local/bin|usr/bin|bin)/[^:]+.*#\1#p' "${COMPOSE_FILE}" 2>/dev/null); do
  if [ -d "$bind_src" ]; then
    COMPOSE_MOUNT_CONFLICT=true
    warn "挂载源应为文件但实为目录: ${bind_src}（Docker 首次创建时自动建立的目录）"
  fi
done
if [ "$COMPOSE_MOUNT_CONFLICT" = "true" ]; then
  warn "删除旧容器，使本次 up 按当前宿主类型重建挂载"
  docker rm -f openclaw-gateway >/dev/null 2>&1 || true
fi

COMPOSE_LOG="$(mktemp)"
docker compose -f "${COMPOSE_FILE}" ${COMPOSE_PROFILES} up -d >"${COMPOSE_LOG}" 2>&1 || true
tail -3 "${COMPOSE_LOG}"

# A. 事后自愈：up 输出里出现挂载类型冲突签名 → 删容器重建
if grep -qE "not a directory|Are you trying to mount" "${COMPOSE_LOG}"; then
  warn "检测到容器挂载类型与宿主不一致，删除旧容器后重建"
  docker rm -f openclaw-gateway >/dev/null 2>&1 || true
  docker compose -f "${COMPOSE_FILE}" ${COMPOSE_PROFILES} up -d 2>&1 | tail -3 \
    || { rm -f "${COMPOSE_LOG}"; fail "Gateway 启动失败"; }
fi
rm -f "${COMPOSE_LOG}"

# 兜底：容器是否存在（Up 或 Restarting 都算存在，health 由后续逻辑判定）
if ! docker inspect openclaw-gateway >/dev/null 2>&1; then
  fail "Gateway 启动失败（容器未创建）"
fi

# 若后续还有需要 Gateway 重启才能生效的改动（如新增 provider、Telegram 接入），
# 由 12.8 收尾统一重启确认 healthy；否则此处直接等待 Gateway ready。
if $NEED_RESTART; then
  info "有待生效的改动，暂不等待 healthy，将由 12.8 收尾统一重启确认"
else
  wait_gateway_ready
fi

# ── 7. Nginx ──
step "7. Nginx"
# 幂等：仅在 nginx 站点配置不存在时写入（首装）。已存在则保留用户手改的追加配置，
# 重跑 install.sh 不覆盖，但会重新检测默认站点并 reload（不应覆盖用户自定义 server 块）。
if [ ! -f /etc/nginx/sites-available/openclaw ]; then
if [ -n "$DOMAIN" ]; then
  # 先只启用 HTTP：让 ACME HTTP-01 challenge 能通过，避免引用尚不存在的证书。
  sudo mkdir -p /var/www/certbot
  cat > /etc/nginx/sites-available/openclaw << NGINX
map \$http_upgrade \$connection_upgrade { default upgrade; '' close; }
limit_conn_zone \$binary_remote_addr zone=openclaw_limit:10m;
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
    limit_conn openclaw_limit ${CONN_LIMIT};
  }
}
NGINX
  ln -sf /etc/nginx/sites-available/openclaw /etc/nginx/sites-enabled/openclaw
  rm -f /etc/nginx/sites-enabled/default
  nginx -t || fail "HTTP Nginx 配置校验失败"
  systemctl reload nginx

  if certbot certonly --webroot -w /var/www/certbot -d "${DOMAIN}" --non-interactive --agree-tos -m "admin@${DOMAIN}"; then
    cat > /etc/nginx/sites-available/openclaw << NGINX
map \$http_upgrade \$connection_upgrade { default upgrade; '' close; }
limit_conn_zone \$binary_remote_addr zone=openclaw_limit:10m;
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
    limit_conn openclaw_limit ${CONN_LIMIT};
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
  cat > /etc/nginx/sites-available/openclaw << NGINX
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
  ln -sf /etc/nginx/sites-available/openclaw /etc/nginx/sites-enabled/openclaw
  rm -f /etc/nginx/sites-enabled/default
  nginx -t && systemctl reload nginx
  ok "Nginx (8080, 无 HTTPS) 就位"
fi
else
  # nginx 配置已存在：保留用户自定义，仅确保软链与 reload 到位，不覆盖内容
  ln -sf /etc/nginx/sites-available/openclaw /etc/nginx/sites-enabled/openclaw 2>/dev/null || true
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
# 【为什么写 /data/state/workspace 而不是 /data/workspace】
# /data/state 是 Gateway 容器的 bind 源（容器内挂为 /home/node/.openclaw），
# 因此容器实际读取的是 /data/state/workspace/AGENTS.md。
# 早期版本写 /data/workspace/AGENTS.md 并依赖 /data/workspace 是软链；
# 但该路径在真实机器上通常已作为【真实目录】存在（含 model_routing.json、README.md 等），
# 于是第 3 步的 [ -e /data/workspace ] 判断为真、软链不会创建——
# 策略文件被写到一个容器根本看不见的地方，而安装照样打印 ok。这是静默失效。
WS_DIR=/data/state/workspace
GW_DIR=/data/state/workspace-guest
mkdir -p "$WS_DIR" "$GW_DIR"

cp "$PROJECT_DIR/templates/SOUL.md" "$WS_DIR/SOUL.md" 2>/dev/null || cat > "$WS_DIR/SOUL.md" << 'SOUL'
# Administrator Execution Mode
## Identity
私人高级运维工程师。任务：理解目标 → 分析环境 → 执行操作 → 验证结果 → 交付可用。
## Rules
- 管理员任务最高优先级
- 禁止输出 token / 密钥 / 密码
- 可逆操作直接执行，不可逆必须确认
- 不确定按不可逆处理
SOUL

# 模板含 {{AGENT_NAME}} / {{OWNER_NAME}} / {{TELEGRAM_OWNER_ID}} 占位符，
# 安装时替换为真实值——公开仓库不留个人身份信息。
fill_identity() {
  sed -e "s|{{AGENT_NAME}}|${AGENT_NAME:-Mori}|g" \
      -e "s|{{AGENT_EMOJI}}|${AGENT_EMOJI:-🌙}|g" \
      -e "s|{{OWNER_NAME}}|${OWNER_NAME:-owner}|g" \
      -e "s|{{TELEGRAM_OWNER_ID}}|${TELEGRAM_OWNER_ID:-}|g" "$1"
}

if [ -f "$PROJECT_DIR/templates/AGENTS.md" ]; then
  fill_identity "$PROJECT_DIR/templates/AGENTS.md" > "$WS_DIR/AGENTS.md"
  ok "main 策略已写入 $WS_DIR/AGENTS.md"
else
  warn "缺少 templates/AGENTS.md"
fi

if [ -f "$PROJECT_DIR/templates/AGENTS.guest.md" ]; then
  fill_identity "$PROJECT_DIR/templates/AGENTS.guest.md" > "$GW_DIR/AGENTS.md"
  ok "guest 策略已写入 $GW_DIR/AGENTS.md"
fi

# ── 8.1 行为 Skill（按需加载，不进常驻上下文）──
# 生产实践：AGENTS.md 只保留常驻行为内核，低频流程拆进 Skill，由 description 路由。
if [ -d "$PROJECT_DIR/templates/skills" ]; then
  for skill_dir in "$PROJECT_DIR"/templates/skills/*/; do
    [ -d "$skill_dir" ] || continue
    sname=$(basename "$skill_dir")
    for side in "$WS_DIR" "$GW_DIR"; do
      mkdir -p "$side/skills/$sname"
      cp "$skill_dir/SKILL.md" "$side/skills/$sname/SKILL.md" 2>/dev/null && \
        ok "skill $sname -> $side/skills/"
    done
  done
else
  warn "缺少 templates/skills/，行为 Skill 未安装"
fi

# 策略与 Skill 属主必须是 Gateway 运行用户，否则容器读不到。
chown -R 1000:1000 "$WS_DIR" "$GW_DIR" 2>/dev/null || true
ok "策略文件与行为 Skill 已就位"

# ── 9. 备份 ──
step "9. 备份"
# 备份统一由运维矩阵的 nightly-backup.sh 承担（见 10.7 安装 + /etc/cron.d/openclaw-ops 排期），
# 还原由手动执行的 openclaw-restore.sh 承担（还原是有状态破坏性的操作，不排 cron），
# 备份可用性由 backup-verify.sh 每周日校验（只校验不落地）。
# 归档落盘 /data/state/backups/config/，默认保留 7 份（BACKUP_KEEP 可覆盖）。
ok "备份策略：nightly-backup.sh 每日 + backup-verify.sh 每周校验（由运维矩阵排期）"

# ── 10. 巡检与日志轮转 ──
step "10. 巡检与日志轮转"
# 巡检由运维矩阵的 selfcheck.py（每 10 分钟快检，异常推 Telegram）承担，见 10.7。

# 日志轮转：运维矩阵与网关日志会让 /data/logs/*.log 持续增长，
# 用 logrotate 以大小+保留份数控制，避免磁盘被日志吃满。
if command -v logrotate >/dev/null 2>&1; then
  cat > /etc/logrotate.d/openclaw << 'LR'
/data/logs/*.log {
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
  ok "logrotate 已配置（/etc/logrotate.d/openclaw）"
else
  info "logrotate 不存在，跳过日志轮转配置"
fi

# ── 10.7a task-engine 文件落盘 ──────────────────────────────────────
# 必须早于 10.7b 的 systemd 启动：te-daemon 的启动分支会检查
# [ -f /data/state/workspace/task-engine/te_daemon_v2.py ]。
# 若把落盘放在启动之后，该检查恒为假 → 单元装上了却从未 enable --now，
# 表现为 systemctl is-active te-daemon = inactive，
# 而安装日志只有"systemd 单元已安装"、没有"已启动"，极易被忽略。
if $WITH_TASK_ENGINE; then
  mkdir -p /data/state/workspace/task-engine
  cp -r "$PROJECT_DIR/task-engine"/* /data/state/workspace/task-engine/ 2>/dev/null
  chmod +x /data/state/workspace/task-engine/*.py /data/state/workspace/task-engine/*.sh 2>/dev/null || true
  # 属主必须是容器内消费者（node = uid/gid 1000），否则 node 读不到 task.json，
  # taskboard 巡检会直接抛 PermissionError（生产机已发生过一次）。
  chown -R 1000:1000 /data/state/workspace/task-engine
  ok "task-engine 组件就位（/data/state/workspace/task-engine）"
fi

# ── 10.7 运维/自愈组件 ──
{
  step "10.7 安装运维/自愈组件"
  mkdir -p /data/scripts /usr/local/bin /var/lib/openclaw /data/opt

  # 1) 全部通用运维脚本落到 /usr/local/bin
  for s in "$PROJECT_DIR"/scripts/ops/*; do
    [ -f "$s" ] || continue
    b=$(basename "$s")
    cp "$s" "/usr/local/bin/$b" && chmod +x "/usr/local/bin/$b" && ok "$b installed"
  done

  # 2) 启动补丁（已在 §6 启动容器前安装；此处幂等刷新，保证重跑/升级后是最新版）
  mkdir -p /data/opt/openclaw-patches
  cp "$PROJECT_DIR"/openclaw-patches/*.sh /data/opt/openclaw-patches/ 2>/dev/null
  chmod +x /data/opt/openclaw-patches/*.sh
  ok "openclaw-patches 已刷新（/data/opt/openclaw-patches）"

  # 2.1) cdp-relay.js 需要被 gateway 容器内调用；同时保留宿主机副本供 systemd 拉起
  if [ -f "$PROJECT_DIR/scripts/ops/cdp-relay.js" ]; then
    cp "$PROJECT_DIR/scripts/ops/cdp-relay.js" /usr/local/bin/cdp-relay.js
    chmod 644 /usr/local/bin/cdp-relay.js
  fi

  # 3) docker CLI 包装（沙箱内需要 docker，但不直接暴露宿主 socket 权限）
  # 已在 §6 compose up 【之前】安装（顺序依赖，见那里注释）；此处幂等刷新，
  # 保证重跑/升级后拿到最新逻辑，同时确保路径类型是【文件】而非目录。
  install_docker_cli
}

# mihomo 配置（渲染到生产机真实路径 /usr/local/etc/mihomo/config.yaml）
if $WITH_MIHOMO; then
  mkdir -p /usr/local/etc/mihomo
  if [ ! -f /usr/local/etc/mihomo/config.yaml ]; then
    cp "$PROJECT_DIR/templates/mihomo-config.yaml" /usr/local/etc/mihomo/config.yaml
    ok "mihomo 配置渲染到 /usr/local/etc/mihomo/config.yaml（请填入你的节点与 secret）"
  else
    info "mihomo 配置已存在，跳过渲染（如需重置请删除后重跑）"
  fi
  # 生成 mihomo secret 若未设置
  if ! grep -qE '^MIHOMO_SECRET=' /data/etc/openclaw/runtime.env 2>/dev/null; then
    MSEC=$(openssl rand -hex 16 2>/dev/null || head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n')
    echo "MIHOMO_SECRET=$MSEC" >> /data/etc/openclaw/runtime.env
  fi
  MSEC=$(grep -E '^MIHOMO_SECRET=' /data/etc/openclaw/runtime.env | cut -d= -f2- || echo "")
  [ -n "$MSEC" ] && sed -i "s/YOUR_MIHOMO_SECRET_HERE/$MSEC/g" /usr/local/etc/mihomo/config.yaml
  # 提示节点为占位符，需人工替换
  if grep -qE '192\.0\.2\.1|YOUR_UUID_HERE' /usr/local/etc/mihomo/config.yaml 2>/dev/null; then
    warn "mihomo 节点仍是模板占位符（192.0.2.1 / YOUR_UUID_HERE），启动前请替换为真实节点，否则无出口。"
  fi
fi

# ── systemd 常驻服务（对齐生产：ocwatch / te-daemon / cdp-relay）──
# 为什么用 systemd 而不是 cron：这三者是「常驻 + 自愈 + 秒级响应」，
# cron 只能做到分钟级轮询且无进程守卫（挂了不自拉起）。cron 矩阵负责周期性巡检，
# systemd 负责常驻守护，两者互补而非替代。
install_systemd_unit() {
  local unit="$1" src="$2"
  [ -f "$src" ] || { warn "缺少 systemd 模板 $unit，跳过"; return 0; }
  cp "$src" "/etc/systemd/system/$unit"
  ok "systemd 单元已安装: $unit"
}

if command -v systemctl >/dev/null 2>&1; then
  install_systemd_unit "ocwatch.service"            "$PROJECT_DIR/templates/systemd/ocwatch.service"
  install_systemd_unit "openclaw-cdp-relay.service" "$PROJECT_DIR/templates/systemd/openclaw-cdp-relay.service"

  # te-daemon 依赖 task-engine 目录，仅在启用 task-engine 时安装
  if $WITH_TASK_ENGINE; then
    install_systemd_unit "te-daemon.service" "$PROJECT_DIR/templates/systemd/te-daemon.service"
  fi

  systemctl daemon-reload >/dev/null 2>&1 || true

  # ocwatch：常驻健康监控（gateway/mihomo/browser/磁盘/内存 + 沙箱路径自愈）
  if [ -f /usr/local/bin/ocwatch.sh ]; then
    chmod +x /usr/local/bin/ocwatch.sh
    systemctl enable --now ocwatch.service >/dev/null 2>&1 \
      && ok "ocwatch.service 已启动（60s 健康监控）" \
      || warn "ocwatch.service 启动失败，请 systemctl status ocwatch 排查"
  fi

  # cdp-relay：浏览器 CDP 回环转发（沙箱 browser 链路，按需拉起）
  if [ -f /usr/local/bin/openclaw-cdp-relay.sh ]; then
    chmod +x /usr/local/bin/openclaw-cdp-relay.sh
    systemctl enable --now openclaw-cdp-relay.service >/dev/null 2>&1 \
      && ok "openclaw-cdp-relay.service 已启动" \
      || warn "openclaw-cdp-relay.service 启动失败（无沙箱浏览器时可忽略）"
  fi

  # te-daemon：任务引擎守护（reconcile + 停滞告警）
  if $WITH_TASK_ENGINE && [ -f /data/state/workspace/task-engine/te_daemon_v2.py ]; then
    systemctl enable --now te-daemon.service >/dev/null 2>&1 \
      && ok "te-daemon.service 已启动（任务引擎守护）" \
      || warn "te-daemon.service 启动失败，请 systemctl status te-daemon 排查"
  fi
else
  warn "未检测到 systemd，跳过常驻服务安装（ocwatch/te-daemon/cdp-relay）"
fi

# 统一 cron 矩阵（cron.d/openclaw-ops），无条件写入（重跑即覆盖）
cat > /etc/cron.d/openclaw-ops << 'CRONEOF'
# OpenClaw 运维矩阵 — 由安装脚本生成，重跑即覆盖
# 沙箱重启策略钉死 unless-stopped
*/2 * * * * root /usr/local/bin/pin-sbx-restart.sh
# 沙箱全功能配置防漂移（binds + browser）
*/5 * * * * root /usr/local/bin/openclaw-cfg-guard.py
# Telegram 入站轮询保活，僵死则重启网关
*/3 * * * * root /usr/local/bin/ensure-telegram-alive.sh
# chromium 在位 + 浏览器在跑
*/5 * * * * root /usr/local/bin/ensure-browser-alive.sh
# 关键项快检（全绿静默，异常推 Telegram）
*/10 * * * * root /usr/local/bin/selfcheck-quick-cron.sh
# mihomo 模型 API 出口守护 + 自动切节点
*/2 * * * * root /usr/local/bin/mihomo-guard.sh
# gateway resolv.conf 防回滚到被污染 DNS
*/5 * * * * root /usr/local/bin/fix-gateway-dns.sh
# skills CLI 自愈
*/30 * * * * root /usr/local/bin/ensure-skill-bins.sh
# 全量备份，保留 7 天（BACKUP_KEEP 可覆盖）
17 4 * * * root /usr/local/bin/nightly-backup.sh
# 还原演练：每周日 05:30 校验最新备份的 sha256 与归档可读性，损坏则告警。
# 刻意【不】真还原——自动还原会在无人值守时把线上状态覆盖掉，风险远大于收益。
# 这条 cron 的意义是：把"备份到底能不能用"从"出事当天才知道"提前到"每周日就知道"。
30 5 * * 0 root /usr/local/bin/backup-verify.sh
# 环境快照
30 4 * * * root /usr/local/bin/gen-env-snapshot.sh
CRONEOF

# 任务引擎相关的两条排期只在启用 task-engine 时写入。
# 否则它们指向 /data/state/workspace/task-engine/ 下并不存在的脚本，
# cron 会每轮都记一条 "No such file or directory"，把真正的告警淹掉。
if $WITH_TASK_ENGINE; then
  cat >> /etc/cron.d/openclaw-ops << 'CRONEOF_TE'
# 任务停滞看门狗（24h+ 去重告警）
17 */6 * * * root cd /data/state/workspace/task-engine && ./stale_alert.sh
# 完成声明审计（扫描"宣称完成但无 A 级证据"的消息，去重后告警）
43 7 * * * root /data/state/workspace/task-engine/claim_audit_cron.sh
CRONEOF_TE
fi

cat >> /etc/cron.d/openclaw-ops << 'CRONEOF_TAIL'
# 沙箱 bind mount 源路径自愈（gateway 用容器内视角路径做 Source 会指向错误目录）
*/5 * * * * root /usr/local/bin/ensure-sandbox-paths.sh >/dev/null 2>&1
CRONEOF_TAIL
chmod 644 /etc/cron.d/openclaw-ops
ok "运维 cron 矩阵就位（/etc/cron.d/openclaw-ops）"

# 注：task-engine 文件落盘已提前到 §10.7a（必须早于 te-daemon 的启动检查）。

# ── 10.8 沙箱镜像构建（开启 --with-sandbox 时）──
# 沙箱镜像来自 OpenClaw 官方 scripts/sandbox-setup.sh（非本项目自研），
# 本步骤负责：① 从发行版拉官方构建脚本 ② 构建基础 + 浏览器镜像 ③ 打 skills 增强层。
if $WITH_SANDBOX; then
  step "10.8 构建沙箱镜像"
  SANDBOX_BUILD_DIR="/data/opt/sandbox-build"
  if [ -d "$SANDBOX_BUILD_DIR" ] && [ -f "$SANDBOX_BUILD_DIR/Dockerfile.sandbox" ]; then
    info "沙箱构建目录已存在，跳过拉取"
  else
    mkdir -p "$SANDBOX_BUILD_DIR"
    # 官方构建脚本随 openclaw 源码分发；优先从 GitHub 拉取 scripts/ 下的构建文件。
    # 供应链：官方未对这些文件发布校验和，因此这里做两件能做的事：
    #   ① 固定 ref（默认 main 可被覆盖，但鼓励用 tag/commit 锁定，避免上游静默改动）；
    #   ② 落盘后把所有文件的 SHA256 写入清单，供审计与异地比对。
    # 不假装这等于"已验证"——它只保证"可复现、可追溯"。
    OW_SRC_REF="${OPENCLAW_SRC_REF:-main}"
    if [ "$OW_SRC_REF" = "main" ]; then
      warn "沙箱构建文件使用 main 分支（可被上游静默改动）；如需可复现构建请设 OPENCLAW_SRC_REF=<tag|commit>"
    fi
    OW_BASE="https://raw.githubusercontent.com/openclaw/openclaw/${OW_SRC_REF}"
    _fetch() {
      local rel="$1" dst="$SANDBOX_BUILD_DIR/$1"
      mkdir -p "$(dirname "$dst")"
      # 下到临时文件再 mv：避免半截文件被当成"已存在"而在重跑时被跳过
      local tmp="${dst}.part"
      if curl -fsSL --max-time 30 "${OW_BASE}/${rel}" -o "$tmp" 2>/dev/null && [ -s "$tmp" ]; then
        mv "$tmp" "$dst"
        return 0
      fi
      rm -f "$tmp"
      return 1
    }
    ok_fetch=true
    for f in Dockerfile.sandbox Dockerfile.sandbox-browser Dockerfile.sandbox-common \
             scripts/sandbox-setup.sh scripts/sandbox-browser-setup.sh scripts/sandbox-common-setup.sh; do
      _fetch "$f" || { ok_fetch=false; warn "拉取失败: $f"; }
    done
    if ! $ok_fetch; then
      warn "官方沙箱构建文件拉取不全（可能需要代理）。可稍后手动补齐 $SANDBOX_BUILD_DIR 后重跑。"
    else
      # 记录指纹清单（含 ref），便于事后核对构建输入是否被改动。
      DIGEST_MANIFEST="$SANDBOX_BUILD_DIR/SHA256SUMS.manifest"
      {
        echo "# 来源: ${OW_BASE}/"
        echo "# ref : ${OW_SRC_REF}"
        echo "# 生成: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
        for f in Dockerfile.sandbox Dockerfile.sandbox-browser Dockerfile.sandbox-common \
                 scripts/sandbox-setup.sh scripts/sandbox-browser-setup.sh scripts/sandbox-common-setup.sh; do
          [ -f "$SANDBOX_BUILD_DIR/$f" ] && record_file_digest "$SANDBOX_BUILD_DIR/$f"
        done
      } > "$DIGEST_MANIFEST"
      ok "沙箱构建文件指纹清单: $DIGEST_MANIFEST"
      info "沙箱构建输入来自 ${OW_SRC_REF}；已记录 SHA256 便于审计（非官方签名校验）"
    fi
  fi

  if [ -f "$SANDBOX_BUILD_DIR/scripts/sandbox-setup.sh" ]; then
    # 基础沙箱镜像（sandbox 的缺省 image）
    if ! docker image inspect "openclaw-sandbox:bookworm-slim" >/dev/null 2>&1; then
      ( cd "$SANDBOX_BUILD_DIR" && bash scripts/sandbox-setup.sh ) \
        && ok "基础沙箱镜像构建完成（openclaw-sandbox:bookworm-slim）" \
        || warn "基础沙箱镜像构建失败，沙箱功能将不可用"
    else
      info "基础沙箱镜像已存在"
    fi
  fi

  if [ -f "$SANDBOX_BUILD_DIR/scripts/sandbox-browser-setup.sh" ]; then
    if ! docker image inspect "openclaw-sandbox-browser:bookworm-slim" >/dev/null 2>&1; then
      ( cd "$SANDBOX_BUILD_DIR" && bash scripts/sandbox-browser-setup.sh ) \
        && ok "浏览器沙箱镜像构建完成" \
        || warn "浏览器沙箱镜像构建失败，浏览器工具将不可用"
    else
      info "浏览器沙箱镜像已存在"
    fi
  fi

  # 镜像加速：若配置了 SANDBOX_IMAGE_MIRROR，则重打 tag 指向镜像站
  if [ -n "${SANDBOX_IMAGE_MIRROR:-}" ]; then
    for img in openclaw-sandbox:bookworm-slim openclaw-sandbox-browser:bookworm-slim; do
      docker tag "$img" "${SANDBOX_IMAGE_MIRROR}/${img}" 2>/dev/null || true
    done
    ok "沙箱镜像已打镜像站 tag: ${SANDBOX_IMAGE_MIRROR}"
  fi
fi

# ── 11. 凭证摘要 ──
step "11. 凭证"
cat > /root/openclaw-credentials.txt << EOF
openclaw 凭证 (部署: $(date -u +%Y-%m-%dT%H:%M:%SZ))
=========================================
运行时环境: /data/etc/openclaw/runtime.env
Token 读取:  grep OPENCLAW_GATEWAY_TOKEN /data/etc/openclaw/runtime.env
EOF
chmod 600 /root/openclaw-credentials.txt
ok "凭证摘要: /root/openclaw-credentials.txt"

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


  # 自动拉取模型列表（非交互环境或拉取失败则退化为手动填一个模型 id）
  echo ""
  info "正在自动拉取可用模型列表..."
  P_TYPE="${P_TYPE}" P_URL="${P_URL}" P_KEY="${P_KEY}" P_AUTH="${P_AUTH}" \
    P_MODELS_URL="${P_MODELS_URL}" P_API_VERSION="${P_API_VERSION}" \
  python3 - << 'PYEOF' > /tmp/openclaw-models.txt 2>/dev/null
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


  # 让用户勾选模型
  if [ -s /tmp/openclaw-models.txt ]; then
    echo ""
    echo "  检测到以下模型，直接回车 = 全部加入；输入编号逗号分隔 = 只选部分；输入单个模型 id 也可："
    nl -ba /tmp/openclaw-models.txt
    prompt "  选择（回车=全部）: " SEL
    if [ -z "${SEL}" ]; then
      P_MODELS=$(paste -sd'\n' /tmp/openclaw-models.txt)
    else
      P_MODELS=""
      for n in $(echo "${SEL}" | tr ',' '\n'); do
        n="$(echo "${n}" | tr -d ' ')"
        [ -z "${n}" ] && continue
        line=$(sed -n "${n}p" /tmp/openclaw-models.txt 2>/dev/null)
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
  rm -f /tmp/openclaw-models.txt

  [ -n "${P_MODELS}" ] || { info "未选择任何模型，取消 provider"; return 0; }


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
}

# 非交互自动配置（CI / 无 TTY / 一键脚本）：通过 OPENCLAW_PROVIDER_* 环境变量（可写在 .env）
# 注入单个 provider，复用与交互流程完全相同的那段 python 原子 merge 逻辑，不覆盖已有字段。
# 若未提供 OPENCLAW_PROVIDER_BASE_URL 则不配置。
configure_provider_noninteractive() {
  GWJSON="/data/state/openclaw.json"
  [ -f "${GWJSON}" ] || { info "openclaw.json 不存在，跳过 provider 配置"; return 0; }

  local P_NAME="${OPENCLAW_PROVIDER_NAME:-}"
  local P_URL="${OPENCLAW_PROVIDER_BASE_URL:-}"
  local P_API="${OPENCLAW_PROVIDER_API:-openai-completions}"
  local P_KEY="${OPENCLAW_PROVIDER_KEY:-}"
  local P_MODELS_IN="${OPENCLAW_PROVIDER_MODELS:-}"

  [ -n "${P_URL}" ] || { info "未设置 OPENCLAW_PROVIDER_BASE_URL，跳过 provider 自动配置"; return 0; }
  [ -n "${P_NAME}" ] || P_NAME="my-provider"

  # 模型：优先用 OPENCLAW_PROVIDER_MODELS（逗号分隔）；为空则尝试自动拉 /models，仍空则跳过 models 字段
  local P_MODELS=""
  if [ -n "${P_MODELS_IN}" ]; then
    P_MODELS="$(echo "${P_MODELS_IN}" | tr ',' '\n' | sed '/^[[:space:]]*$/d')"
  else
    info "尝试自动拉取模型列表（baseUrl: ${P_URL}）..."
    P_URL="${P_URL}" P_KEY="${P_KEY}" python3 - << 'PYEOF' > /tmp/openclaw-models.txt 2>/dev/null || true
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
    if [ -s /tmp/openclaw-models.txt ]; then
      P_MODELS="$(cat /tmp/openclaw-models.txt)"
      rm -f /tmp/openclaw-models.txt
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

# 非交互环境（如 CI / 无 TTY）：有 OPENCLAW_PROVIDER_BASE_URL 则自动配置，否则才跳过
if $INTERACTIVE; then
  configure_provider
else
  if [ -n "${OPENCLAW_PROVIDER_BASE_URL:-}" ]; then
    configure_provider_noninteractive
  else
    info "非交互环境，且未设置 OPENCLAW_PROVIDER_BASE_URL，跳过模型 provider 配置"
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


# ── 12.8 重启生效（收尾） ──
# 若本次安装过程中有任何需要 Gateway 重启才能生效的改动（新增 provider、Telegram 接入），
# 在此处统一执行一次 up -d 并等 healthy。可避免在中间步骤反复重启，也保证跑完即最终态。
if $NEED_RESTART; then
  step "12.8 重启 Gateway 生效"
  info "检测到配置/补丁改动，重启 Gateway 使其生效..."
  COMPOSE_PROFILES=""
  $WITH_MIHOMO && COMPOSE_PROFILES="${COMPOSE_PROFILES} --profile mihomo"
  docker compose -f /data/etc/openclaw/docker-compose.yml ${COMPOSE_PROFILES} up -d 2>&1 || fail "Gateway 重启失败"
  wait_gateway_ready
fi

# ── 12.9 控制台验收 ──
step "12.9 控制台验收"
verify_control_ui

# ── 12.10 环境变量体检 ──
# 为什么需要这一步：模板里有十几个 ${VAR} 引用，但安装过程只保证把文件铺好，
# 不保证这些变量真的有值。缺值时 Gateway 依然 healthy（健康检查不依赖业务通道），
# 直到真的发一条消息才报 "Outbound not configured for channel: telegram"。
# 也就是说，安装"成功"了，功能却是哑的，而安装日志里一个字都没提。
# 因此收尾时统一做一次体检，把"哪些能力因为缺配置而不可用"明确讲出来。
step "12.10 环境变量体检"
env_health_check || true

# ── 完成 ──

# ── 完成 ──
echo ""
echo "========================================"
echo -e "${GREEN}  openclaw 部署完成${NC}"
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
echo "  3. 重启 Gateway 生效: docker restart openclaw-gateway"
echo "========================================"
