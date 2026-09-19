---
name: durable-task-delivery
description: Use for tasks over 30 seconds, background or unattended work, deployment, upload, external sending, Git push, cross-host writes, taskboard operations, or any task requiring durable progress and acceptance verification.
---

# Durable Task Delivery

## Required references

- Read `/workspace/runbooks/delivery-and-verification.md`.
- For unattended work, taskboard, cron, or daemon behavior, also read `/workspace/runbooks/task-engine-and-unattended.md` and `/workspace/task-engine/README.md`.

## Workflow

1. Define the deliverable, acceptance condition, estimated time, and rollback.
2. For external side effects, create a task with a machine-checkable `--accept-cmd` before executing.
3. Run the task through `create → run → status → verify`; do not use narration as the completion authority.
4. If the state is `awaiting_verification`, verify within the next tool action. If the original check is obsolete but the owner explicitly accepts, use `--accept`.
5. On failed acceptance, reset/reopen and fix; never relabel failure as completion.
6. For work over 30 seconds, announce the plan and provide progress every 30–60 seconds. If elapsed time exceeds three times the estimate, report the stall and bypass.

## Evidence levels

- External completion requires an external read-back: remote SHA, response/status, message ID, remote file read, or health endpoint.
- Local state proves only local work. Cached remote-tracking refs are not remote evidence.
- If external verification is unavailable, say `操作已发起,尚未验证外部结果`.

## Completion report

Include task ID/state, acceptance command result, external evidence, remaining risk, and rollback.
