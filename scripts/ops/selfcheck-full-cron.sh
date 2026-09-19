#!/bin/bash
# selfcheck-full-cron.sh — 全量自检（供 OpenClaw health-patrol cron 调用）
/usr/local/bin/selfcheck.py --full 2>&1
exit 0
