#!/bin/bash
# openclaw-restore.sh — 从 nightly-backup.sh 的归档还原 CathyClaw 状态
#
# 为什么需要它：备份存在不等于能还原。旧版只有 nightly-backup.sh，
# 出事后没有任何还原路径，只能手工解包 + 猜权限 + 猜该重启哪些服务。
#
# 用法：
#   sudo openclaw-restore.sh              # 交互式：列出备份供选择
#   sudo openclaw-restore.sh <备份文件>   # 直接还原指定归档（可只给文件名）
#   sudo openclaw-restore.sh --list       # 仅列出
#   sudo openclaw-restore.sh --dry-run <备份文件>   # 只校验与预演，不落盘
#
# 环境变量：
#   ROOT_PREFIX   把整棵路径树挪到别处，仅用于离线演练/自测；
#                 置空即生产行为（默认）。演练时会跳过 Gateway/systemd 启停。
#
# 流程：列备份 → 校验 sha256 → 停止服务 → 存还原前快照 → 解包 → 修权限
#       → 重启服务 → 验证健康。
set -euo pipefail

# ROOT_PREFIX：把整棵路径树挪到别处，仅用于离线演练/自测（生产留空）。
# 注意 ROOT_PREFIX 只影响"往哪里写/读文件系统"，不影响归档内部的相对路径，
# 因此演练产出的归档与生产归档结构一致。
ROOT_PREFIX="${ROOT_PREFIX:-}"
DEST="${BACKUP_DIR:-${ROOT_PREFIX}/data/state/backups/config}"
SNAP_DIR="${ROOT_PREFIX}/data/state/backups/pre-restore"
LOG="${ROOT_PREFIX}/var/log/openclaw-restore.log"
COMPOSE_FILE="${ROOT_PREFIX}/data/etc/openclaw/docker-compose.yml"
GATEWAY="openclaw-gateway"

DRY_RUN=false
TARGET=""

log() { echo "$(date '+%F %T') $*" >> "$LOG"; }
info() { echo -e "\033[1;33m[INFO]\033[0m $*"; }
ok()   { echo -e "\033[0;32m[OK]\033[0m $*"; }
warn() { echo -e "\033[1;33m[WARN]\033[0m $*" >&2; }
fail() { echo -e "\033[0;31m[FAIL]\033[0m $*" >&2; log "FAIL: $*"; exit 1; }

# ── 参数解析 ──
while [ $# -gt 0 ]; do
  case "$1" in
    --list|-l) TARGET="__LIST__"; shift ;;
    --dry-run|-n) DRY_RUN=true; shift ;;
    -h|--help)
      sed -n '2,24p' "$0" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    -*) fail "未知参数: $1（用 --help 查看用法）" ;;
    *) TARGET="$1"; shift ;;
  esac
done

[ "$(id -u)" -eq 0 ] || fail "需要 root（还原要写 /data 与重启 systemd 服务）"
[ -d "$DEST" ] || fail "备份目录不存在: $DEST"

# ── 列出可用备份 ──
list_backups() {
  local f
  ls -1t "$DEST"/config-*.tar.gz 2>/dev/null || true
}

if [ "$TARGET" = "__LIST__" ]; then
  echo "备份目录: $DEST"
  echo ""
  if [ -z "$(list_backups)" ]; then
    echo "  （无备份）"
  else
    printf "  %-34s %-10s %-20s %s\n" "文件" "大小" "时间" "校验"
    printf "  %s\n" "--------------------------------------------------------------------------"
    while read -r f; do
      [ -n "$f" ] || continue
      # 注意：这里不是函数体，且循环体经管道进入子 shell，
      # 不能用 local（SC2168，dash 下直接报错）。
      sz=""; ts=""; ck=""
      sz="$(du -h "$f" 2>/dev/null | cut -f1)"
      ts="$(date -r "$f" '+%F %T' 2>/dev/null)"
      if [ -f "${f}.sha256" ]; then
        if (cd "$(dirname "$f")" && sha256sum -c --status "$(basename "${f}.sha256")" 2>/dev/null); then
          ck="OK"
        else
          ck="损坏"
        fi
      else
        ck="无校验和"
      fi
      printf "  %-34s %-10s %-20s %s\n" "$(basename "$f")" "$sz" "$ts" "$ck"
    done < <(list_backups)
  fi
  exit 0
fi

# ── 选定备份 ──
ARCHIVE=""
if [ -n "$TARGET" ]; then
  if [ -f "$TARGET" ]; then
    ARCHIVE="$TARGET"
  elif [ -f "$DEST/$TARGET" ]; then
    ARCHIVE="$DEST/$TARGET"
  else
    fail "找不到备份文件: $TARGET（用 --list 查看可用备份）"
  fi
else
  # 交互式选择
  mapfile -t CANDIDATES < <(list_backups)
  [ "${#CANDIDATES[@]}" -gt 0 ] || fail "备份目录为空: $DEST"
  echo "可用备份（新→旧）："
  echo ""
  i=1
  for f in "${CANDIDATES[@]}"; do
    printf "  %2d) %-34s %-10s %s\n" "$i" "$(basename "$f")" \
      "$(du -h "$f" 2>/dev/null | cut -f1)" "$(date -r "$f" '+%F %T' 2>/dev/null)"
    i=$((i + 1))
  done
  echo ""
  read -r -p "选择要还原的编号 [1]: " pick
  pick="${pick:-1}"
  case "$pick" in
    ''|*[!0-9]*) fail "无效编号: $pick" ;;
  esac
  [ "$pick" -ge 1 ] && [ "$pick" -le "${#CANDIDATES[@]}" ] || fail "编号超范围: $pick"
  ARCHIVE="${CANDIDATES[$((pick - 1))]}"
fi

echo ""
info "目标备份: $(basename "$ARCHIVE")"

# ── 1) 校验完整性 ──
# 这是还原流程的守门人：坏归档解包到一半会留下半毁状态，比不还原更糟。
if [ -f "${ARCHIVE}.sha256" ]; then
  if (cd "$(dirname "$ARCHIVE")" && sha256sum -c --status "$(basename "${ARCHIVE}.sha256")"); then
    ok "SHA256 校验通过"
  else
    fail "SHA256 校验失败——备份已损坏，拒绝还原（换一个备份或从异地副本恢复）"
  fi
else
  warn "该备份没有 .sha256 校验和（可能是旧版 nightly-backup.sh 生成的）"
  warn "将仅做归档可读性检查，无法证明内容未被篡改/损坏"
fi

tar -tzf "$ARCHIVE" >/dev/null 2>&1 || fail "归档不可读: $ARCHIVE"
ok "归档可读，共 $(tar -tzf "$ARCHIVE" | wc -l) 项"

if $DRY_RUN; then
  echo ""
  ok "--dry-run：校验与预演完成，未做任何改动"
  echo ""
  echo "将还原的顶层路径："
  tar -tzf "$ARCHIVE" | awk -F/ '{print $1"/"$2}' | sort -u | sed 's/^/  - \//' | head -20
  exit 0
fi

# ── 2) 还原前快照 ──
# 万一还原到一半发现备份选错了，还能退回去。
#
# 【关键】快照必须覆盖与备份相同的范围，否则"回退"只是幻觉：
# 旧版只快照 openclaw.json + /data/etc/openclaw，若还原前这些文件恰好不在
# （正是最常见的还原场景），快照会直接失败，等于没有回退能力。
# 现在改为：整体快照 /data/state 与 /data/etc/openclaw，存在的路径才纳入，
# 且至少要有内容才写出快照。
#
# 【关键】快照文件写在 /data/state/backups/pre-restore/ 下，而 /data/state 是要快照的内容，
# 直接 tar 会形成自包含递归（tar 边写边读自己）。因此先写到 /tmp 再 mv 过去，
# 并显式排除 backups 子树。
mkdir -p "$SNAP_DIR"
chmod 700 "$SNAP_DIR"
SNAP="$SNAP_DIR/pre-restore-$(date +%Y%m%d-%H%M%S).tar.gz"
info "保存还原前快照: $(basename "$SNAP")"
TMP_SNAP="$(mktemp /tmp/openclaw-snapshot-XXXXXX.tar.gz)"
# 收集当前存在的待快照路径（与 nightly-backup.sh 的 CORE/EXTRA 同源口径）
SNAP_PATHS=()
for p in data/state data/etc/openclaw data/state/openclaw.json; do
  [ -e "${ROOT_PREFIX}/${p}" ] && SNAP_PATHS+=("$p")
done
if [ "${#SNAP_PATHS[@]}" -eq 0 ]; then
  rm -f "$TMP_SNAP"
  warn "还原前系统已无 /data/state 与 /data/etc/openclaw，无可快照内容（继续还原）"
elif tar -czf "$TMP_SNAP" -C "${ROOT_PREFIX}/" \
      --exclude='data/state/backups' --exclude='data/state/backups/*' \
      "${SNAP_PATHS[@]}" 2>/dev/null \
   && [ -s "$TMP_SNAP" ] && tar -tzf "$TMP_SNAP" >/dev/null 2>&1; then
  mv "$TMP_SNAP" "$SNAP"
  chmod 600 "$SNAP"
  ok "快照已保存（$(du -h "$SNAP" | cut -f1)，含 ${#SNAP_PATHS[@]} 个顶层路径）"
  # 快照只保留最近 3 份
  ls -1t "$SNAP_DIR"/pre-restore-*.tar.gz 2>/dev/null | tail -n +4 | xargs -r rm -f
else
  rm -f "$TMP_SNAP"
  warn "快照保存失败（继续还原，但失去回退能力）"
fi

# ── 3) 停止服务 ──
info "停止 Gateway 与常驻服务..."
if [ -f "$COMPOSE_FILE" ]; then
  docker compose -f "$COMPOSE_FILE" stop 2>&1 | tail -3 || warn "compose stop 未成功，继续"
else
  warn "找不到 compose 文件: $COMPOSE_FILE"
fi
for u in te-daemon openclaw-cdp-relay; do
  systemctl is-active --quiet "$u" 2>/dev/null && systemctl stop "$u" 2>/dev/null && ok "已停止 $u" || true
done

# ── 4) 解包还原 ──
# 【关键】归档含 data/state，而归档自己就躺在 data/state/backups/config/ 下。
# 旧版直接 `tar -xzf "$ARCHIVE" -C /` 会有两个后果（实测确凿）：
#   a) 解包会命中归档内的 data/state/backups/... 条目，
#      把正在读取的归档自身覆盖截断为 0 字节；
#   b) 即使先复制到 /tmp 再解包，归档内那份"旧备份"仍会被写回 backups 目录。
# 因此解包时【必须排除 backups 子树】——备份归档不该被还原流程改写。
info "解包还原到 ${ROOT_PREFIX}/ ..."
WORK_ARCHIVE="$(mktemp /tmp/openclaw-restore-XXXXXX.tar.gz)"
trap 'rm -f "$WORK_ARCHIVE"' EXIT
if ! cp "$ARCHIVE" "$WORK_ARCHIVE"; then
  fail "无法复制归档到临时区（磁盘空间不足？）"
fi
# 复制后重新校验一次：把"边读边被覆盖"这类问题在落盘前拦住。
if [ -f "${ARCHIVE}.sha256" ]; then
  if ! sha256sum "$WORK_ARCHIVE" | awk '{print $1}' | diff -q - <(awk '{print $1}' "${ARCHIVE}.sha256") >/dev/null 2>&1; then
    fail "归档在复制过程中发生变化——拒绝还原（可能被并发备份覆盖）"
  fi
fi
if ! tar -xzf "$WORK_ARCHIVE" -C "${ROOT_PREFIX}/" \
      --exclude='data/state/backups' --exclude='data/state/backups/*'; then
  fail "解包失败——系统可能处于半还原状态，请用快照 $SNAP 回退"
fi
ok "文件已还原"

# ── 5) 修复权限 ──
# 容器内 node 用户是 uid/gid 1000，属主不对会读不到任务库（生产机踩过）。
info "修复权限..."
[ -d "${ROOT_PREFIX}/data/state" ] && chown -R 1000:1000 "${ROOT_PREFIX}/data/state" 2>/dev/null || true
[ -d "${ROOT_PREFIX}/data/workspace" ] && chown -R 1000:1000 "${ROOT_PREFIX}/data/workspace" 2>/dev/null || true
if [ -d "${ROOT_PREFIX}/data/etc/openclaw" ]; then
  chmod 700 "${ROOT_PREFIX}/data/etc/openclaw"
  chmod 600 "${ROOT_PREFIX}"/data/etc/openclaw/* 2>/dev/null || true
fi
if [ -f "${ROOT_PREFIX}/data/state/openclaw.json" ]; then
  chown 1000:1000 "${ROOT_PREFIX}/data/state/openclaw.json"
  chmod 600 "${ROOT_PREFIX}/data/state/openclaw.json"
fi
# 运维脚本必须可执行（tar 保留模式，但跨文件系统或旧归档可能丢）
for s in selfcheck.py mihomo-guard.sh nightly-backup.sh openclaw-restore.sh; do
  [ -f "${ROOT_PREFIX}/usr/local/bin/$s" ] && chmod +x "${ROOT_PREFIX}/usr/local/bin/$s" 2>/dev/null || true
done
[ -d "${ROOT_PREFIX}/data/state/workspace/task-engine" ] && chown -R 1000:1000 "${ROOT_PREFIX}/data/state/workspace/task-engine" 2>/dev/null || true
ok "权限已修复"

# ── 6) 重启服务 ──
# ROOT_PREFIX 非空 = 演练模式，不碰真实服务。
if [ -n "$ROOT_PREFIX" ]; then
  info "演练模式（ROOT_PREFIX 非空）：跳过 Gateway/systemd 启停"
else
  info "重启服务..."
  if [ -f "$COMPOSE_FILE" ]; then
    docker compose -f "$COMPOSE_FILE" up -d 2>&1 | tail -3 || fail "Gateway 启动失败"
  fi
  for u in te-daemon openclaw-cdp-relay; do
    systemctl start "$u" 2>/dev/null && ok "已启动 $u" || true
  done
fi

# ── 7) 验证健康 ──
ready="skipped"
if [ -z "$ROOT_PREFIX" ]; then
  info "等待 Gateway 就绪（最多 180s）..."
  ready=false
  for _ in $(seq 1 36); do
    st="$(docker ps --format '{{.Status}}' --filter "name=^${GATEWAY}$" 2>/dev/null || true)"
    case "$st" in
      *healthy*) ready=true; break ;;
    esac
    sleep 5
  done

  echo ""
  if $ready; then
    ok "Gateway 已就绪 (healthy)"
  else
    warn "Gateway 未在 180s 内变为 healthy"
    warn "排查: docker logs --tail 50 $GATEWAY"
  fi
fi

log "restore ok: $(basename "$ARCHIVE") (snapshot: $(basename "$SNAP")) healthy=$ready"
echo ""
echo "  还原完成：$(basename "$ARCHIVE")"
echo "  回退快照：$SNAP"
echo "  日志    ：$LOG"
echo ""
