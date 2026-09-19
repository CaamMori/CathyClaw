#!/usr/bin/env bash
set -euo pipefail

# =============================================================
# cakeclaw uninstall — 完整卸载
# 删除: 容器 / 数据 / cron / Nginx / compose 临时文件
# 用法: sudo bash uninstall.sh [--force]
#   不加 --force 会要求输入 yes 确认
# =============================================================

if [ "$(id -u)" -ne 0 ]; then echo "请用 sudo 执行"; exit 1; fi

FORCE="${1:-}"
if [ "${FORCE}" != "--force" ]; then
  echo "=== cakeclaw 卸载 ==="
  echo "将删除: 容器 / 数据目录 / cron / Nginx 配置"
  echo ""
  read -p "确认卸载? 输入 'yes' 继续: " CONFIRM
  [ "${CONFIRM}" = "yes" ] || { echo "已取消"; exit 0; }
fi

echo "[1/5] 停止容器..."
docker rm -f cakeclaw-gateway cakeclaw-fallback 2>/dev/null || true
docker network prune -f 2>/dev/null || true

echo "[2/5] 删除 Nginx 配置..."
rm -f /etc/nginx/sites-available/cakeclaw /etc/nginx/sites-enabled/cakeclaw 2>/dev/null || true
nginx -t 2>/dev/null && systemctl reload nginx 2>/dev/null || true

echo "[3/5] 清理 cron..."
# 新方式：移除 /etc/cron.d/ 下的 cakeclaw 任务文件（独立、精确，不用 grep 模糊匹配）
rm -f /etc/cron.d/cakeclaw-backup /etc/cron.d/cakeclaw-health-check /etc/cron.d/cakeclaw-watchdog /etc/cron.d/cakeclaw-trends /etc/cron.d/cakeclaw-cert-check /etc/cron.d/cakeclaw-audit 2>/dev/null || true
# 兼容旧版本（把任务写在 root crontab 里的版本）清理
crontab -l 2>/dev/null | grep -v -E 'cakeclaw|watchdog|health-check|trends|audit|sync|cert-check|kbase' | crontab - 2>/dev/null || true

echo "[4/5] 删除数据目录..."
rm -rf /data/state /data/backups/openclaw-state /data/logs/health-check /data/logs/watchdog /data/logs/trends /data/logs/audit 2>/dev/null || true
rm -rf /data/scripts/alert.sh /data/scripts/watchdog.sh /data/scripts/health-check.sh /data/scripts/trends.sh /data/scripts/audit.sh /data/scripts/backup.sh /data/scripts/backup-cakeclaw.sh /data/scripts/cert-check.sh /data/scripts/changelog.sh /data/scripts/kbase.sh /data/scripts/failover.sh /data/scripts/sync.sh 2>/dev/null || true
rm -rf /data/knowledge 2>/dev/null || true
rm -f /root/cakeclaw-credentials.txt /data/logs/sync.log /data/logs/sync-target 2>/dev/null || true
rm -rf /data/etc/openclaw 2>/dev/null || true

echo "[5/5] 清理临时文件..."
rm -f /data/etc/openclaw/docker-compose.yml /tmp/cakeclaw-compose.yml 2>/dev/null || true

echo ""
echo "cakeclaw 已卸载。"
echo "如需删除 Docker 镜像: docker rmi ghcr.io/openclaw/openclaw:2026.7.1"
echo "workspace 保留在 /data/workspace/（手动删除: rm -rf /data/workspace）"
