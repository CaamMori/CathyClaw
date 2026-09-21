---
name: host-operations
description: Use before host, Docker, Gateway, Mihomo, Telegram networking, systemd, Nginx, restart, recovery, health-check, or infrastructure troubleshooting tasks. Requires reading current state and preserving rollback.
user-invocable: false
---

# Host Operations

## Start here

1. Read `/workspace/SELF.md` for architecture and known failure modes.
2. Read `/workspace/memory/ENV-SNAPSHOT.md` only as a pointer; verify mutable state live.
3. For shell/preflight or outbound-network issues, read `/workspace/runbooks/exec-safety.md`.
4. State the intended change, expected effect, verification, and rollback before changing infrastructure.

## Operating rules

- Query live state first (`docker inspect`, Compose status, health endpoints, logs, systemd/Nginx status as applicable). Memory is not evidence.
- Change one risky variable at a time. Back up configuration before editing.
- Never stop, remove, kill, restart, pause, rename, or exec into the Gateway's protected self-components from the agent container. Use the authorized host control plane and ask the owner when required.
- For Gateway topology, use the complete Compose project; do not restart one container in a shared-network stack.
- Test network health in the correct network namespace. `127.0.0.1` in a helper container is not the Gateway loopback.
- Prefer reversible additions and sidecars over replacement of a running control plane.
- Validate bind-mount source type, ownership, permissions, and writable destinations.
- Never claim recovery from process state alone: run an end-to-end functional check.

## Failure handling

Classify failure before retrying:

- Deterministic/configuration rejection: change approach; do not repeat unchanged commands.
- Transient timeout/rate limit: bounded retry with backoff, then use a different path.
- Three unchanged outcomes means a loop: stop and report the blocker and rollback state.

## Completion evidence

Report:

- configuration diff or exact changed resources;
- live service/container health;
- one user-path test (for example Telegram delivery or internal API request);
- rollback command or backup location.
