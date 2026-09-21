#!/usr/bin/env bash
# Hide low-value Telegram Skill shortcuts without disabling model-side Skill use.
# Non-fatal by design: an upstream layout change must not prevent Gateway startup.
set -uo pipefail

node <<'JS'
const fs = require('fs');

const files = [
  '/app/dist/extensions/canvas/skills/canvas/SKILL.md',
  '/app/skills/control-ui/SKILL.md',
  '/app/skills/healthcheck/SKILL.md',
  '/app/skills/node-connect/SKILL.md',
  '/app/skills/node-inspect-debugger/SKILL.md',
  '/app/skills/openai-whisper-api/SKILL.md',
  '/app/skills/python-debugpy/SKILL.md',
  '/app/skills/skill-creator/SKILL.md',
  '/app/skills/spike/SKILL.md',
  '/app/skills/taskflow-inbox-triage/SKILL.md',
];

let failed = false;
for (const file of files) {
  try {
    let text = fs.readFileSync(file, 'utf8');
    if (!text.startsWith('---\n')) throw new Error('missing YAML frontmatter');
    const end = text.indexOf('\n---\n', 4);
    if (end < 0) throw new Error('unterminated YAML frontmatter');
    const fm = text.slice(4, end);
    let nextFm;
    if (/^user-invocable:\s*.*$/m.test(fm)) {
      nextFm = fm.replace(/^user-invocable:\s*.*$/m, 'user-invocable: false');
    } else if (/^description:.*$/m.test(fm)) {
      nextFm = fm.replace(/^description:.*$/m, (line) => `${line}\nuser-invocable: false`);
    } else {
      nextFm = `${fm}\nuser-invocable: false`;
    }
    const next = `---\n${nextFm}${text.slice(end)}`;
    if (next !== text) fs.writeFileSync(file, next, 'utf8');
    console.log(`[skill-menu] hidden: ${file}`);
  } catch (error) {
    failed = true;
    console.error(`[skill-menu] warning: ${file}: ${error.message}`);
  }
}
if (failed) process.exitCode = 2;
JS
