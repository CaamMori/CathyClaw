## Description: <br>
Self-reflection + Self-criticism + Self-learning + Self-organizing memory. Agent evaluates its own work, catches mistakes, and improves permanently. <br>

This skill is ready for commercial/non-commercial use. <br>

## Publisher: <br>
[gasgangrene](https://clawhub.ai/user/gasgangrene) <br>

### License/Terms of Use: <br>
MIT-0 <br>


## Use Case: <br>
Developers and agent operators use this skill to help an agent learn from explicit corrections, self-reflection, and repeated workflow patterns while keeping memory local and auditable. <br>

### Deployment Geography for Use: <br>
Global <br>

## Known Risks and Mitigations: <br>
Risk: The skill keeps durable local notes about corrections, style preferences, and project habits. <br>
Mitigation: Review ~/self-improving/ periodically and use the documented audit, export, and forget commands to inspect or clear memory. <br>
Risk: Sensitive personal, regulated, credential, or third-party information could be stored if a user asks the agent to remember it. <br>
Mitigation: Follow the documented security boundaries and avoid storing credentials, health data, financial data, biometric data, location routines, access patterns, and third-party information. <br>
Risk: Overgeneralized or stale memory can affect future agent behavior. <br>
Mitigation: Keep new lessons tentative until confirmed, cite memory sources when applying patterns, and use compaction, demotion, archiving, or forget operations when patterns no longer apply. <br>


## Reference(s): <br>
- [ClawHub skill page](https://clawhub.ai/gasgangrene/skills/self-improving) <br>
- [Homepage](https://clawic.com/skills/self-improving) <br>
- [Security boundaries](artifact/boundaries.md) <br>
- [Setup guide](artifact/setup.md) <br>
- [Learning mechanics](artifact/learning.md) <br>
- [Memory operations](artifact/operations.md) <br>


## Skill Output: <br>
**Output Type(s):** [text, markdown, shell commands, configuration, guidance] <br>
**Output Format:** [Markdown guidance with inline shell commands and local file templates] <br>
**Output Parameters:** [1D] <br>
**Other Properties Related to Output:** [Produces local memory and workspace-setup guidance; no credentials or extra binaries are required.] <br>

## Skill Version(s): <br>
1.0.0 (source: ClawHub release metadata; artifact frontmatter states 1.2.16) <br>

## Ethical Considerations: <br>
Users should evaluate whether this skill is appropriate for their environment, review any generated or modified files before relying on them, and apply their organization's safety, security, and compliance requirements before deployment. <br>
