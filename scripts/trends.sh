#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# cakeclaw trends — 巡检 JSON 聚合周报
# cron: 0 9 * * 1 /data/scripts/trends.sh
# ============================================================

REPORT_DIR="/data/logs/trends"
HC_DIR="/data/logs/health-check"
mkdir -p "${REPORT_DIR}"

TS=$(date -u +%Y%m%d)
REPORT="${REPORT_DIR}/weekly-${TS}.json"
echo "[$(date '+%Y-%m-%d %H:%M')] generating weekly trend..."

count=0
scores=0
disk_sum=0
mem_sum=0
samples_ok=0
samples_degraded=0

for f in $(ls -t "${HC_DIR}"/*.json 2>/dev/null | head -672); do  # 7天 × 24h × 4次/h = 672
  [ -f "$f" ] || continue
  disk=$(jq -r '.disk_pct // 0' "$f" 2>/dev/null || echo 0)
  mem=$(jq -r '.mem_free_gb // 0' "$f" 2>/dev/null || echo 0)
  gw=$(jq -r '.gateway // "unknown"' "$f" 2>/dev/null || echo unknown)
  nginx=$(jq -r '.nginx // "unknown"' "$f" 2>/dev/null || echo unknown)
  [ "$disk" -eq 0 ] && [ "$mem" -lt 0 ] && continue
  count=$((count+1))
  disk_sum=$((disk_sum + disk))
  mem_sum=$((mem_sum + mem))
  # 评分: disk>90 扣 30, mem<1 扣 30, gw 非 Up 扣 50, nginx fail 扣 20（满分 100 底）
  sample_score=100
  [ "$disk" -gt 90 ] && sample_score=$((sample_score - 30))
  [ "$mem" -lt 1 ]   && sample_score=$((sample_score - 30))
  echo "$gw" | grep -q "^Up" || sample_score=$((sample_score - 50))
  [ "$nginx" = "fail" ] && sample_score=$((sample_score - 20))
  scores=$((scores + sample_score))
  [ "$sample_score" -ge 70 ] && samples_ok=$((samples_ok + 1)) || samples_degraded=$((samples_degraded + 1))
done

if [ "$count" -eq 0 ]; then
  echo "[$(date '+%H:%M')] no data, skip"
  exit 0
fi

avg_score=$((scores / count))
avg_disk=$((disk_sum / count))
avg_mem=$((mem_sum / count))
ok_pct=$((samples_ok * 100 / count))

cat > "${REPORT}" << EOF
{
  "ts": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "samples": ${count},
  "avg_score": ${avg_score},
  "avg_disk_pct": ${avg_disk},
  "avg_mem_free_gb": ${avg_mem},
  "samples_ok": ${samples_ok},
  "samples_degraded": ${samples_degraded},
  "ok_pct": ${ok_pct},
  "status": "$([ ${avg_score} -ge 70 ] && echo ok || echo degraded)"
}
EOF

echo "[$(date '+%H:%M')] done: avg_score=${avg_score} avg_disk=${avg_disk}% avg_mem=${avg_mem}G ok=${ok_pct}% → ${REPORT}"
