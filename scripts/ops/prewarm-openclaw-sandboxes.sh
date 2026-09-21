#!/usr/bin/env bash
# Gateway 容器变化后,无模型预热 main/guest workspace sandbox。
# 只调用 OpenClaw 自身 provisioning API,不发模型请求、不写聊天记录。
set -euo pipefail

GW=openclaw-gateway
STATE=/var/lib/openclaw/sandbox-prewarm.gateway-id
LOCK=/var/run/openclaw-sandbox-prewarm.lock
LOG=/var/log/openclaw-sandbox-prewarm.log
mkdir -p "$(dirname "$STATE")"

exec 9>"$LOCK"
flock -n 9 || exit 0

gateway_id=$(docker inspect -f '{{.Id}}' "$GW" 2>/dev/null || true)
[ -n "$gateway_id" ] || exit 0
[ "$(cat "$STATE" 2>/dev/null || true)" = "$gateway_id" ] && exit 0

health=$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$GW" 2>/dev/null || true)
[ "$health" = healthy ] || exit 0

# 修复 protected Skill workspace 属主,避免 provisioning 的原子替换失败。
/usr/local/bin/ensure-sandbox-paths.sh >/dev/null 2>&1 || true

tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT
if timeout 90 docker exec -i "$GW" node --input-type=module >"$tmp" 2>&1 <<'JS'
import { r as loadConfig } from '/app/dist/io.runtime-Bm3fPzNt.mjs';
import { n as resolveSandboxContext } from '/app/dist/context-BXF2qE_e.mjs';
const config = loadConfig();
for (const [agentId, workspaceDir] of [
  ['main', '/home/node/.openclaw/workspace'],
  ['guest', '/home/node/.openclaw/workspace-guest'],
]) {
  const started = Date.now();
  const sandbox = await resolveSandboxContext({
    config,
    agentId,
    sessionKey: `agent:${agentId}:startup-prewarm`,
    workspaceDir,
  });
  if (!sandbox?.enabled || !sandbox?.runtimeId) {
    throw new Error(`sandbox prewarm failed for ${agentId}`);
  }
  console.log(JSON.stringify({agentId, runtimeId: sandbox.runtimeId, elapsedMs: Date.now() - started}));
}
// Config/Skill loaders may keep file watchers alive; provisioning is complete.
process.exit(0);
JS
then
  printf '%s\n' "$gateway_id" > "$STATE"
  {
    printf '%s prewarm=ok gateway=%s\n' "$(date -Is)" "${gateway_id:0:12}"
    grep -E '^\{"agentId"' "$tmp" || true
  } >> "$LOG"
  tail -n 200 "$LOG" > "$LOG.tmp" && mv "$LOG.tmp" "$LOG"
  exit 0
fi

{
  printf '%s prewarm=failed gateway=%s\n' "$(date -Is)" "${gateway_id:0:12}"
  tail -n 30 "$tmp"
} >> "$LOG"
exit 1
