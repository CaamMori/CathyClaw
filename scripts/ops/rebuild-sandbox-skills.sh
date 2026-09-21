#!/bin/sh
# rebuild-sandbox-skills.sh — 重建带 skills CLI 的沙箱镜像并接管 bookworm-slim tag
set -e
docker build -f /data/opt/Dockerfile.sandbox-skills -t openclaw-sandbox:bookworm-slim-skills /data/opt
docker tag openclaw-sandbox:bookworm-slim openclaw-sandbox:bookworm-slim-pre-skills-last 2>/dev/null || true
docker tag openclaw-sandbox:bookworm-slim-skills openclaw-sandbox:bookworm-slim
