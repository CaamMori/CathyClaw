---
name: research-recovery
description: Use when web search, scraping, downloads, APIs, or research sources fail; for 403/429/503, TLS errors, timeouts, connection resets, missing data, or multi-source verification. Prevents premature 'cannot obtain' conclusions.
---

# Research Recovery

Read `/workspace/runbooks/exhaustion-and-channels.md`; for command and outbound-network constraints also read `/workspace/runbooks/exec-safety.md`.

## Classify before acting

- No data or incompatible definition: change source.
- 429/503 with retry guidance: back off, reduce concurrency, then try an equivalent endpoint.
- TLS, timeout, reset, or transport failure: change network path or protocol stack before merely changing content source.
- 403/anti-bot: prefer official API/feed/export, then browser rendering when available.
- Tool/preflight rejection: rewrite the operation safely; it is not proof that the underlying capability is absent.

## Recovery ladder

1. Preserve the exact error/status and request context without secrets.
2. Retry transient failures at most twice with changed timing or parameters.
3. Try an equivalent endpoint or independent source.
4. Try a different client/protocol stack or browser where appropriate.
5. Deliver useful partial results with scope and confidence instead of an empty report.
6. Before saying no channel exists, provide the explored candidates and failure class for each.

## Verification

Prefer two independent sources. Distinguish direct observations from inference, and label values that could not be obtained or cross-checked.
