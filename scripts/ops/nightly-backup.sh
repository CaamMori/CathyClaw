#!/bin/bash
# nightly-backup.sh — CathyClaw 整机关键状态备份
#
# 与旧版的差异（旧版有 5 个真实缺陷，均已修正）：
#   1. 旧版 tar 末尾用 2>/dev/null 吞掉错误 → 路径写错也"备份成功"。
#      实测 /data/scripts/docker-compose.gateway.yml 与
#      /data/scripts/ensure-telegram-alive.sh 这两个路径根本不存在，
#      真正的文件在 /data/etc/openclaw/docker-compose.yml 和
#      /usr/local/bin/ensure-telegram-alive.sh，也就是说旧版长期静默漏备份。
#      现改为：逐路径判定存在性，缺失的明确记录进日志，且不因此整体失败。
#   2. 旧版不生成校验和 → 备份损坏无从得知。现生成 .sha256，还原时校验。
#   3. 旧版只有 set -u → tar 失败仍返回 0，cron 看不出异常。
#      现用 set -euo pipefail + 显式失败退出码。
#   4. 旧版失败静默（只写一行日志）。现失败时经 TE_ALERT_TARGET 告警
#      （未配置则仅记日志——保持无 Telegram 机器可用）。
#   5. 旧版漏备份 /data/etc/openclaw（含 runtime.env 与 telegram token）
#      与 /data/state/credentials —— 全是不可再生的凭证。
#      注：/data/state 已整目录纳入，故 credentials/agents/plugin-skills 随之内含。
#
# 设计取舍：备份"部分成功也好过整体失败"。可选路径缺失只记录不中断，
# 只有【打包 / 校验 / 落盘】这些核心环节出错才判失败——避免因某个路径改名
# 就让整个备份停摆（那比漏一个文件更糟）。
set -euo pipefail

STAMP="$(date +%Y%m%d-%H%M%S)"
# ROOT_PREFIX：把整棵路径树挪到别处，仅用于离线演练/自测
# （演练要能重复跑，不能在真实 /data 上反复删改）。生产留空。
ROOT_PREFIX="${ROOT_PREFIX:-}"
DEST="${ROOT_PREFIX}/data/state/backups/config"
LOG="${ROOT_PREFIX}/var/log/nightly-backup.log"
KEEP="${BACKUP_KEEP:-7}"
# 同一秒内重跑会覆盖上一份归档（时间戳精度到秒），加 PID 后缀避免静默覆盖。
ARCHIVE="${DEST}/config-${STAMP}-$$.tar.gz"

# 告警通道：留空则只记日志（与项目其它组件一致，未配 Telegram 的机器不报错）
ALERT_TARGET="${TE_ALERT_TARGET:-}"

log() { echo "$(date '+%F %T') $*" >> "$LOG"; }

alert() {
  local msg="$1"
  log "ALERT: ${msg}"
  [ -n "$ALERT_TARGET" ] || return 0
  [ -x /usr/local/bin/te_notify.sh ] || return 0
  /usr/local/bin/te_notify.sh "$msg" >/dev/null 2>&1 || true
}

fail() {
  alert "备份失败: $*"
  echo "[FAIL] $*" >&2
  exit 1
}

mkdir -p "$DEST"
chmod 700 "$DEST"

# ── 待备份路径清单 ──
# CORE：缺失即失败（备份的全部意义所在）
CORE_PATHS=(
  /data/state/openclaw.json   # 主配置
  /data/state                 # 状态库：credentials / agents / plugin-skills / workspace
)

# EXTRA：存在则收，缺失只记录（跨机型差异，如 mihomo 仅境内机有）
EXTRA_PATHS=(
  /data/etc/openclaw                 # runtime.env、telegram token、docker-compose.yml
  /usr/local/etc/mihomo/config.yaml  # 仅境内机存在
  /etc/cron.d/openclaw-ops           # 运维排期矩阵
  /etc/systemd/system/te-daemon.service
  /etc/systemd/system/ocwatch.service
  /etc/systemd/system/openclaw-cdp-relay.service
  /usr/local/bin/selfcheck.py
  /usr/local/bin/selfcheck-quick-cron.sh
  /usr/local/bin/selfcheck-full-cron.sh
  /usr/local/bin/mihomo-guard.sh
  /usr/local/bin/mihomo-autoswitch.sh
  /usr/local/bin/fix-gateway-dns.sh
  /usr/local/bin/ensure-browser-alive.sh
  /usr/local/bin/ensure-telegram-alive.sh
  /usr/local/bin/ensure-sandbox-paths.sh
  /usr/local/bin/ensure-skill-bins.sh
  /usr/local/bin/sync-agent-workspace.sh
  /usr/local/bin/pin-sbx-restart.sh
  /usr/local/bin/openclaw-cfg-guard.py
  /usr/local/bin/cdp-relay.js
  /usr/local/bin/openclaw-cdp-relay.sh
  /usr/local/bin/nightly-backup.sh
  /usr/local/bin/openclaw-restore.sh
  /usr/local/bin/backup-verify.sh
  /usr/local/bin/gen-env-snapshot.sh
  /data/etc/openclaw/docker-compose.yml
)

# ── 组装实际存在的路径 ──
# ROOT_PREFIX 非空时（仅演练用），把每个绝对路径前缀上沙盘根。
# 归档内仍保存【不带前缀】的相对路径，这样归档结构与生产完全一致，
# 演练产出的归档可以直接用于生产的 openclaw-restore.sh。
PRESENT=()
MISSING=()
for p in "${CORE_PATHS[@]}"; do
  if [ -e "${ROOT_PREFIX}${p}" ]; then PRESENT+=("$p"); else fail "核心路径缺失: $p"; fi
done
for p in "${EXTRA_PATHS[@]}"; do
  if [ -e "${ROOT_PREFIX}${p}" ]; then PRESENT+=("$p"); else MISSING+=("$p"); fi
done

# ── 打包 ──
# 刻意不用 2>/dev/null —— 那正是旧版静默漏备份的成因。
# 有可读性告警（如 docker.sock 这类特殊文件被跳过）记入日志，但不判失败；
# 只有 tar 非零退出才算失败。
#
# 【必须排除 backups 目录】这是本项目踩过的一个真坑：
# /data/state 被整目录纳入备份，而备份归档自己就写在 /data/state/backups/config/ 下。
# 不排除的话，每一份归档都会把上一份归档整包套进来（自引用），后果有二：
#   1. 归档体积滚雪球（第 N 份含 N-1 份，指数级浪费空间）；
#   2. 还原时 `tar -xzf` 会命中归档内的 `data/state/backups/...` 条目，
#      把正在读取的归档自身覆盖截断为 0 字节——实测确凿发生。
# 排除方式用 --exclude，而不是只传子路径（/data/state 是 CORE 项，必须整树备份）。
TAR_WARN="$(mktemp)"
REL_PATHS=()
for p in "${PRESENT[@]}"; do REL_PATHS+=("${p#/}"); done

if ! tar -czf "$ARCHIVE" \
      --exclude='data/state/backups' \
      --exclude='data/state/backups/*' \
      -C "${ROOT_PREFIX}/" "${REL_PATHS[@]}" 2>"$TAR_WARN"; then
  rm -f "$TAR_WARN"
  fail "打包失败 (tar 返回非零): ${ARCHIVE}"
fi

if [ -s "$TAR_WARN" ]; then
  log "打包告警: $(tr '\n' ';' < "$TAR_WARN" | cut -c1-400)"
fi
rm -f "$TAR_WARN"

# ── 完整性校验 ──
# 1) 非空：演练中遇到过归档被写成 0 字节但 tar 仍返回 0 的情况
#    （归档目录自身在被快照范围内时，边写边读会把文件截断）。
if [ ! -s "$ARCHIVE" ]; then
  rm -f "$ARCHIVE"
  fail "归档为空（0 字节）——打包过程被干扰，拒绝当作成功"
fi
# 2) 可读性
if ! tar -tzf "$ARCHIVE" >/dev/null 2>&1; then
  rm -f "$ARCHIVE"
  fail "归档无法读取（可能已损坏）: ${ARCHIVE}"
fi
# 3) 条目数下限：正常备份至少含 openclaw.json + state 目录树，远多于 10 项。
#    条目过少说明 tar 只打进去零星文件（路径全写错的典型症状）。
ENTRY_COUNT="$(tar -tzf "$ARCHIVE" 2>/dev/null | wc -l | tr -d ' ')"
if [ "$ENTRY_COUNT" -lt 10 ]; then
  rm -f "$ARCHIVE"
  fail "归档条目过少（${ENTRY_COUNT} 项）——备份内容疑似不完整"
fi
# 4) 核心内容抽查
# 【坑】不能写 `tar -tzf ... | grep -q ...`：脚本开了 pipefail，而 grep -q 命中即退出，
# tar 会收到 SIGPIPE 而以非零退出，整条管道因此判为失败 → 明明存在却报"不存在"。
# 实测正是这个坑让备份在本机全部误判失败。改为先落变量再匹配，避免 SIGPIPE。
ARCHIVE_LIST="$(tar -tzf "$ARCHIVE" 2>/dev/null || true)"
case "$ARCHIVE_LIST" in
  *$'\n'"data/state/openclaw.json"$'\n'*|"data/state/openclaw.json"$'\n'*)
    : ;;
  *)
    rm -f "$ARCHIVE"
    fail "归档内不含 data/state/openclaw.json——主配置未进入备份"
    ;;
esac
if ! sha256sum "$ARCHIVE" > "${ARCHIVE}.sha256" 2>/dev/null; then
  rm -f "$ARCHIVE" "${ARCHIVE}.sha256"
  fail "无法生成校验和: ${ARCHIVE}"
fi
chmod 600 "$ARCHIVE" "${ARCHIVE}.sha256"

# ── 轮转：只保留最近 KEEP 份（连同 .sha256）──
ls -1t "$DEST"/config-*.tar.gz 2>/dev/null | tail -n +$((KEEP + 1)) | while read -r old; do
  rm -f "$old" "${old}.sha256"
done

SIZE="$(du -h "$ARCHIVE" 2>/dev/null | cut -f1)"
FILES="$(tar -tzf "$ARCHIVE" 2>/dev/null | wc -l)"
log "backup ok: $(basename "$ARCHIVE") (${SIZE}, ${FILES} 项, 缺失 ${#MISSING[@]} 项)"
[ "${#MISSING[@]}" -gt 0 ] && log "缺失路径(跳过): ${MISSING[*]}"

exit 0
