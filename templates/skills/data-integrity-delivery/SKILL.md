---
name: data-integrity-delivery
description: Use for Excel, CSV, PDF, HTML, charts, reports, calculations, scraped data, batch processing, or any deliverable containing derived numbers. Requires independent read-back and reconciliation.
user-invocable: false
---

# Data Integrity Delivery

Read `/workspace/runbooks/data-integrity.md` before processing or delivering data.

## Procedure

1. Record source, scope, units, date range, missing-value policy, deduplication key, and aggregation definition.
2. Keep raw input immutable; write transformations to a separate artifact.
3. Add explicit assertions for row counts, key uniqueness, totals, ranges, and expected missingness.
4. Recompute derived values through an independent formula or library.
5. Read the final artifact back using a consumer-equivalent path:
   - XLSX/CSV: reopen and print/check key cells and totals;
   - PDF: extract text and inspect page/render output;
   - HTML/chart: render it and inspect visible output;
   - scraped data: reconcile against at least one independent source when possible.
6. Any unexplained discrepancy must be visible in the deliverable. Do not silently alter or omit it.

## Numeric ledgers

When the expected ledger verifier and its input contract are available, run it before delivery. A non-zero exit blocks a success claim. If it is unavailable, perform equivalent assertions and explicitly state the substitute verification.

## Completion evidence

Report source count, output location, assertion results, independent recomputation result, final read-back result, and unresolved discrepancies.
