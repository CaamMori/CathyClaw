#!/usr/bin/env bash
# claim_audit_cron.sh —— 声称-证据一致性审计（定时入口）
#
# 设计要点（与 stale_alert.sh 同源思路）：
#   1) 审计**真正外发给用户**的消息（transcript 的 channel-final），非思维链
#   2) **去重**：同一条消息只告警一次，按消息指纹记账，避免重复刷屏
#   3) 只在**发现新的**疑似幻觉时才推送，正常时完全静默（exit 0）
#   4) 审计对象 = 近 N 天（默认 3 天），由 cron 每日跑一次
#
# 用法：由 cron 调用，无需人工干预
set -u

TE_DIR="/data/state/workspace/task-engine"
STATE="$TE_DIR/.claim_audit_state.json"
GW="openclaw-gateway"
TARGET="${TE_ALERT_TARGET:-}"
DAYS="${CLAIM_AUDIT_DAYS:-3}"

export TASK_ENGINE_HOME="$TE_DIR"
cd "$TE_DIR" || exit 1

# 审计需读 transcript 库（在 gateway 容器内），故经 docker exec 执行。
# ⚠️ 两个环境路径不同，勿混用：
#     宿主 /data/state/workspace/task-engine/  ⇄  容器 /home/node/.openclaw/workspace/task-engine/
# ⚠️ 审计器语义：退出码 0=干净 / 1=发现疑似幻觉 / 2=运行错误。
#    发现幻觉(1) 才是本 wrapper 要处理的场景，**绝不能** `|| exit 0` 把它吞掉。
#    仅当运行错误(2) 或取不到输出时才静默退出。
RAW=$(docker exec "$GW" python3 /home/node/.openclaw/workspace/task-engine/claim_audit.py \
        --transcript --days "$DAYS" 2>/dev/null)
rc=$?
if [ "$rc" -eq 2 ] || [ -z "$RAW" ]; then
  exit 0
fi

# 提取本轮命中的「时间 + 正文前缀」作为指纹，与历史账本比对
MSG=$(python3 - "$STATE" "$RAW" <<'PY'
import json, os, re, sys, hashlib, time
state_path, raw = sys.argv[1], sys.argv[2]

# 解析审计输出块：[疑似幻觉] 消息 #N  [时间] ...  正文: ...
blocks = re.findall(r"\[疑似幻觉\] 消息 #(\d+)\s+\[([^\]]+)\][^\n]*\n(?:.*?\n)*?\s*正文: (.*)", raw)
if not blocks:
    sys.exit(0)

state = {}
if os.path.exists(state_path):
    try: state = json.loads(open(state_path).read())
    except Exception: state = {}

now = time.time()
lines = []
dirty = False
for idx, ts, body in blocks:
    # 去重键必须含消息号：仅用 ts|body 前缀时，两条正文前缀相同、
    # 时间戳相同的消息会被误判为同一条而永久静默（审计失效）
    fp = hashlib.sha256(f"{idx}|{ts}|{body[:120]}".encode()).hexdigest()[:16]
    if fp in state:
        continue                      # 已告警过，跳过
    state[fp] = now
    dirty = True
    snippet = body.strip().replace("\n", " ")[:60]
    lines.append(f"• [{ts}] {snippet}")

# 账本只保留 30 天，防无限增长
cut = now - 30 * 86400
state = {k: v for k, v in state.items() if v >= cut}
if dirty:
    try: json.dump(state, open(state_path, "w"))
    except Exception: pass

if not lines and blocks:
    # 全部命中均已在账本中：这是正常的去重结果，但必须留痕，
    # 否则“审计无输出”与“审计从未运行”无法区分
    sys.stderr.write(f"[claim_audit] 全部 {len(blocks)} 处命中均已在账本内，本次不重复推送\n")
if lines:
    print("⚠️ 完成声明缺少外部证据（疑似幻觉）\n" + "\n".join(lines) +
          "\n\n说明：声称「已推送/已发送/已部署/已完成」但未附 A 级证据"
          "（git ls-remote / curl 状态码 / 平台 messageId）。"
          "\n核对：python3 task-engine/claim_audit.py --transcript --days 3")
PY
)

[ -z "$MSG" ] && exit 0

docker exec "$GW" openclaw message send --channel telegram --target "$TARGET" -m "$MSG" >/dev/null 2>&1 || {
  echo "推送失败（gateway 可能不在线）" >&2
  exit 1
}
echo "已推送审计告警"
