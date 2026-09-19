#!/bin/bash
# backup-verify.sh — 每周校验备份「可用」，而不是只校验「存在」
#
# 为什么需要它：nightly-backup.sh 每天 04:17 生成归档，但如果没人打开过它，
# 「有 7 个 .tar.gz」和「有 7 个能用的 .tar.gz」是两件事。真实世界里最常见的
# 事故不是没备份，而是出事当天才发现备份早就损坏/为空/路径全错。
# 这条 cron 把「备份能不能用」从「出事当天」提前到「每周日 05:30」。
#
# 刻意【不】做真实还原：无人值守的自动还原会在出问题时覆盖线上状态，
# 风险远大于收益。校验只读，绝不写业务路径。
#
# 校验项：
#   1. 备份目录存在且非空
#   2. 最新归档存在、非空、可解压列出（tar -tzf）
#   3. .sha256 校验和匹配；缺失视为警告（旧版备份无校验和）
#   4. 归档内含核心路径 /data/state/openclaw.json —— 空归档/错归档的典型特征
#   5. 归档新鲜度：最新一份不超过 STALE_HOURS（默认 48h）
#
# 用法：
#   sudo backup-verify.sh          # 校验并输出报告
#   sudo backup-verify.sh --quiet  # 全绿静默（供 cron 用，异常才输出+告警）
set -uo pipefail

DEST="${BACKUP_DIR:-${ROOT_PREFIX:-}/data/state/backups/config}"
LOG="${ROOT_PREFIX:-}/var/log/backup-verify.log"
STALE_HOURS="${BACKUP_STALE_HOURS:-48}"
ALERT_TARGET="${TE_ALERT_TARGET:-}"
QUIET=false
[ "${1:-}" = "--quiet" ] && QUIET=true

log() { echo "$(date '+%F %T') $*" >> "$LOG"; }

alert() {
  local msg="$1"
  log "ALERT: ${msg}"
  [ -n "$ALERT_TARGET" ] || return 0
  [ -x /usr/local/bin/te_notify.sh ] || return 0
  /usr/local/bin/te_notify.sh "$msg" >/dev/null 2>&1 || true
}

PROBLEMS=()
WARNINGS=()
say() { $QUIET || echo "$*"; }

# ── 1) 备份目录 ──
if [ ! -d "$DEST" ]; then
  alert "备份校验失败：备份目录不存在 $DEST"
  echo "[FAIL] 备份目录不存在: $DEST" >&2
  exit 1
fi

LATEST="$(ls -1t "$DEST"/config-*.tar.gz 2>/dev/null | head -1 || true)"
COUNT="$(ls -1 "$DEST"/config-*.tar.gz 2>/dev/null | wc -l | tr -d ' ')"

if [ -z "$LATEST" ]; then
  alert "备份校验失败：$DEST 下没有任何 config-*.tar.gz"
  echo "[FAIL] 无任何备份: $DEST" >&2
  exit 1
fi

say "备份目录: $DEST"
say "归档数量: ${COUNT} 份"
say "最新归档: $(basename "$LATEST")"
say ""

# ── 2) 非空且可解压 ──
if [ ! -s "$LATEST" ]; then
  PROBLEMS+=("最新归档为空文件（0 字节）")
else
  if tar -tzf "$LATEST" >/dev/null 2>&1; then
    ENTRIES="$(tar -tzf "$LATEST" 2>/dev/null | wc -l | tr -d ' ')"
    say "[OK]   归档可解压，共 ${ENTRIES} 项"
    [ "$ENTRIES" -lt 10 ] && PROBLEMS+=("归档条目过少（${ENTRIES} 项），疑似打包不完整")
  else
    PROBLEMS+=("归档无法解压读取（已损坏）")
  fi
fi

# ── 3) 校验和 ──
if [ -f "${LATEST}.sha256" ]; then
  if (cd "$(dirname "$LATEST")" && sha256sum -c --status "$(basename "${LATEST}.sha256")" 2>/dev/null); then
    say "[OK]   SHA256 校验通过"
  else
    PROBLEMS+=("SHA256 校验失败——归档已损坏或被篡改")
  fi
else
  WARNINGS+=("最新归档缺少 .sha256（旧版 nightly-backup.sh 生成的）")
  say "[WARN] 缺少 .sha256 校验和"
fi

# ── 4) 内容抽查：核心路径必须在 ──
# 这是最容易漏、也最致命的一类问题：归档能解开，但里面根本没有主配置。
# 注意：只有前面的可解压检查通过才做内容抽查，否则 tar 会对已有问题重复报错，
# 把真正的根因（归档损坏）淹没在噪声里。
if [ -s "$LATEST" ] && tar -tzf "$LATEST" >/dev/null 2>&1; then
  # 先落变量再匹配：`tar -tzf | grep -q` 在 pipefail 下会因 SIGPIPE 误判（见 nightly-backup.sh 注释）
  ENTRIES_LIST="$(tar -tzf "$LATEST" 2>/dev/null || true)"
  case "$ENTRIES_LIST" in
    *$'\n'"data/state/openclaw.json"$'\n'*|"data/state/openclaw.json"$'\n'*)
      say "[OK]   归档含核心配置 data/state/openclaw.json" ;;
    *)
      PROBLEMS+=("归档内不含 data/state/openclaw.json——备份内容不完整（路径可能已改名）") ;;
  esac
else
  say "[SKIP] 归档不可读，跳过内容抽查（根因见上）"
fi

# ── 5) 新鲜度 ──
AGE_H="$(python3 - "$LATEST" << 'PY' 2>/dev/null || echo "?"
import os, sys, time
print(int((time.time() - os.path.getmtime(sys.argv[1])) / 3600))
PY
)"
if [ "$AGE_H" != "?" ] && [ "$AGE_H" -gt "$STALE_HOURS" ]; then
  PROBLEMS+=("最新备份已过期：${AGE_H}h 前（阈值 ${STALE_HOURS}h），可能 cron 未执行")
  say "[FAIL] 最新备份 ${AGE_H}h 前（阈值 ${STALE_HOURS}h）"
else
  say "[OK]   备份新鲜（${AGE_H}h 前）"
fi

# ── 汇总 ──
say ""
if [ "${#PROBLEMS[@]}" -gt 0 ]; then
  msg="备份校验发现问题（$DEST）:"
  for p in "${PROBLEMS[@]}"; do msg="${msg}
- ${p}"; done
  alert "$msg"
  echo "[FAIL] 备份校验未通过：" >&2
  for p in "${PROBLEMS[@]}"; do echo "  - $p" >&2; done
  for w in "${WARNINGS[@]:-}"; do [ -n "$w" ] && echo "  - [WARN] $w" >&2; done
  log "verify FAIL: ${PROBLEMS[*]}"
  exit 1
fi

for w in "${WARNINGS[@]:-}"; do
  [ -n "$w" ] && { say "[WARN] $w"; log "verify warn: $w"; }
done

say "[OK] 备份校验通过（最新 $(basename "$LATEST")）"
log "verify ok: $(basename "$LATEST") entries=${ENTRIES:-0} age=${AGE_H}h missing_checksum=$([ -f "${LATEST}.sha256" ] && echo no || echo yes)"
exit 0
