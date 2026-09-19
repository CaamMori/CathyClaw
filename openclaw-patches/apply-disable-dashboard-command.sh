#!/usr/bin/env bash
# Disable the low-value /dashboard chat command without removing dashboard tools or Control UI.
# Result: absent from native menus; manual /dashboard is intercepted without an LLM run.
# Idempotent and fail-closed on upstream source drift.
set -euo pipefail

python3 - <<'PY'
from pathlib import Path

root = Path('/app/dist')
registry_candidates = list(root.glob('commands-registry.data-*.mjs'))
handler_candidates = list(root.glob('commands-handlers.runtime-*.mjs'))
miniapp_candidates = list(root.glob('miniapp-api-*.mjs'))
reply_candidates = [q for q in root.glob('get-reply-*.mjs') if 'commandName !== \"new\" && commandName !== \"reset\" && commandName !== \"dashboard\" &&' in q.read_text() or 'dashboard uses deterministic text fast path' in q.read_text()]
if len(registry_candidates) != 1 or len(handler_candidates) != 1 or len(miniapp_candidates) != 1 or len(reply_candidates) != 1:
    raise SystemExit(
        f'[disable-dashboard] unexpected module count: '
        f'registry={len(registry_candidates)} handler={len(handler_candidates)} '
        f'miniapp={len(miniapp_candidates)} reply={len(reply_candidates)}'
    )

registry = registry_candidates[0]
handler = handler_candidates[0]
miniapp = miniapp_candidates[0]
reply_module = reply_candidates[0]

# 1. Remove the separate Telegram Mini App /dashboard menu registration.
m = miniapp.read_text()
miniapp_marker = '// openclaw-local: Telegram Mini App dashboard command disabled'
miniapp_line = '\tapi.registerCommand(createTelegramMiniAppDashboardCommand(api, launchTickets));'
if miniapp_marker not in m:
    if m.count(miniapp_line) != 1:
        raise SystemExit('[disable-dashboard] miniapp source mismatch; refusing blind patch')
    m = m.replace(miniapp_line, f'\t{miniapp_marker}', 1)
    miniapp.write_text(m)
    print(f'[disable-dashboard] removed Telegram Mini App registration in {miniapp.name}')
else:
    print(f'[disable-dashboard] miniapp already patched: {miniapp.name}')

# 2. Keep a hidden text-only command descriptor. nativeName:false prevents menu
# registration, while preserving parser recognition for manually typed /dashboard.
r = registry.read_text()
registry_marker = '// openclaw-local: dashboard native command hidden; text interceptor retained'
original_line = """\t\tdefineBuiltinCommand("dashboard", "Create or update this session's dashboard.", "tools", "standard", { args: [defineCommandArgument("request", "Dashboard requirements", { captureRemaining: true })] }),"""
hidden_line = """\t\tdefineBuiltinCommand("dashboard", "Disabled; use /status or /tasks.", "tools", "standard", { nativeName: false, args: [defineCommandArgument("request", "Ignored", { captureRemaining: true })] }),"""
old_removed_marker = '\t\t// openclaw-local: dashboard chat command disabled'
target = f'\t\t{registry_marker}\n{hidden_line}'
if registry_marker not in r:
    if r.count(original_line) == 1:
        r = r.replace(original_line, target, 1)
    elif r.count(old_removed_marker) == 1:
        r = r.replace(old_removed_marker, target, 1)
    else:
        raise SystemExit('[disable-dashboard] registry source mismatch; refusing blind patch')
    registry.write_text(r)
    print(f'[disable-dashboard] hid native command and retained text interceptor in {registry.name}')
else:
    print(f'[disable-dashboard] registry already patched: {registry.name}')

# 3. Allow the hidden text-only /dashboard descriptor to use the internal fast path.
g = reply_module.read_text()
fast_marker = '/* openclaw-local: dashboard uses deterministic text fast path */'
fast_original = 'commandName !== "new" && commandName !== "reset" && commandName !== "dashboard" &&'
fast_target = f'commandName !== "new" && commandName !== "reset" && {fast_marker}'
if fast_marker not in g:
    if g.count(fast_original) != 1:
        raise SystemExit('[disable-dashboard] fast-path source mismatch; refusing blind patch')
    g = g.replace(fast_original, fast_target, 1)
    reply_module.write_text(g)
    print(f'[disable-dashboard] enabled deterministic fast path in {reply_module.name}')
else:
    print(f'[disable-dashboard] fast path already patched: {reply_module.name}')

# 3. Replace execution with a deterministic no-LLM response. Keep original body
# commented for an auditable upgrade diff.
h = handler.read_text()
handler_marker = '// openclaw-local: dashboard chat command disabled (no LLM/skill run)'
start = '''const handleDashboardCommand = defineAuthorizedTextCommand({
\tlabel: DASHBOARD_COMMAND,
\tmatch: (body) => matchCommandPrefix(body, DASHBOARD_COMMAND)
}, async (params, requirements) => {'''
replacement = '''const handleDashboardCommand = defineAuthorizedTextCommand({
\tlabel: DASHBOARD_COMMAND,
\tmatch: (body) => matchCommandPrefix(body, DASHBOARD_COMMAND)
}, async () => {
\t// openclaw-local: dashboard chat command disabled (no LLM/skill run)
\treturn commandReply("/dashboard 已停用。请使用 /status 查看状态,或使用 /tasks 查看后台任务。");
});
/* original dashboard handler retained below but unreachable for upgrade diff:
async function disabledDashboardHandlerOriginal(params, requirements) {'''
end = '''\treturn {
\t\tshouldContinue: true,
\t\texplicitSkillSelections
\t};
});
//#endregion
//#region src/auto-reply/reply/command-exec-result.ts'''
end_replacement = '''\treturn {
\t\tshouldContinue: true,
\t\texplicitSkillSelections
\t};
}
*/
//#endregion
//#region src/auto-reply/reply/command-exec-result.ts'''
if handler_marker not in h:
    if h.count(start) != 1 or h.count(end) != 1:
        raise SystemExit('[disable-dashboard] handler source mismatch; refusing blind patch')
    h = h.replace(start, replacement, 1).replace(end, end_replacement, 1)
    handler.write_text(h)
    print(f'[disable-dashboard] installed deterministic disabled response in {handler.name}')
else:
    print(f'[disable-dashboard] handler already patched: {handler.name}')
PY
