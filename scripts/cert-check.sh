#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# cakeclaw cert-check — 证书到期前 14 天提醒
# cron: 0 9 * * * /data/scripts/cert-check.sh >> /data/logs/cert-check.log 2>&1
# ============================================================

DOMAIN="${1:-}"
[ -n "${DOMAIN}" ] || { echo "[$(date '+%Y-%m-%d %H:%M')] no domain specified, skip"; exit 0; }
DAYS_WARN=14

CERT_FILE="/etc/letsencrypt/live/${DOMAIN}/fullchain.pem"
[ -f "${CERT_FILE}" ] || { echo "[$(date '+%Y-%m-%d %H:%M')] no cert for ${DOMAIN}, skip"; exit 0; }

EXPIRY=$(openssl x509 -enddate -noout -in "${CERT_FILE}" 2>/dev/null | cut -d= -f2)
[ -n "${EXPIRY}" ] || { echo "[$(date '+%H:%M')] cannot read cert expiry"; exit 1; }

EXPIRY_TS=$(date -d "${EXPIRY}" +%s 2>/dev/null || date -j -f "%b %d %T %Y %Z" "${EXPIRY}" +%s 2>/dev/null)
NOW_TS=$(date +%s)
DAYS_LEFT=$(( (EXPIRY_TS - NOW_TS) / 86400 ))

echo "[$(date '+%Y-%m-%d %H:%M')] cert ${DOMAIN}: ${DAYS_LEFT}d left, expires ${EXPIRY}"

if [ "${DAYS_LEFT}" -le "${DAYS_WARN}" ]; then
  echo "[$(date '+%H:%M')] ALERT: cert expires in ${DAYS_LEFT} days!"
  if [ -x /data/scripts/alert.sh ]; then
    bash /data/scripts/alert.sh "HIGH" "TLS cert for ${DOMAIN} expires in ${DAYS_LEFT} days" 2>/dev/null || true
  fi
fi
