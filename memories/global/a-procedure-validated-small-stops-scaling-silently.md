---
name: a-procedure-validated-small-stops-scaling-silently
description: A documented recovery procedure validated at a handful of items stops being executable somewhere between that number and production scale, with no edit and no alarm — it worked at 5 domains and could not reach the end of its own list at 47; state the size a runbook was proven at, and drive the per-item interface when it breaks
metadata:
  type: reference
  scope: global
---

A runbook step reading "re-run `--apply` until it exits 0" is a claim about a loop that terminates. It stops being true the moment the list is long enough for a per-request limit to bite, and nothing announces the transition: the document is unchanged, the code is unchanged, and the command simply dies partway through.

Measured 2026-08-31 on a live box (the affiliate-DNS throttle lane in the ops ledger): the documented sweep died on the **THIRD** domain with an HTTP 503 from the registrar's API. It was not that domain and not the credentials — a direct probe of the same four domains spaced 1,500 ms apart succeeded for every one, and the credential check passed. It was rate limiting, and a grep for `sleep|setTimeout|delay|throttle|retry|backoff|429|503` over the module returned **zero matches**: no throttle, no retry, no backoff anywhere. **It worked at 5 items and silently stopped scaling somewhere between 5 and 47.**


What to do:

- **Record the size a procedure was proven at, in the procedure.** "Validated at 5" is the fact that makes the 47-item failure diagnosable in minutes instead of being read as a new outage.
- **Drive the per-item interface when the sweep breaks.** The script was idempotent and resumable, so invoking it once per item, multi-pass, is legitimate use rather than a hack, and it unblocked the go-live without a code change.
- **Fix it in the module, not in the caller** — a minimum inter-request interval plus bounded retry with backoff on 429/5xx, and the same treatment for a busy-database error on the local write. Both are pass/fail rules, so they ship as property-tested pure functions in the same commit — `[[eval-clauses-are-code-not-prose]]`.
- **Give the sweep one enum value per meaning.** It exited non-zero for the ordinary "not ready yet" case as well as for real errors, so no wrapper could tell "swept, awaiting certs" from "failed" — `[[unambiguous-status-and-logs]]`.

Related: `[[scale-test-large-data-paths]]`, `[[a-uniform-key-fixture-cannot-measure-a-missing-index]]`, `[[dry-run-bounds-writes-not-resources]]`, `[[shared-runbooks-reclaim-ownership-at-fire-time]]`.
