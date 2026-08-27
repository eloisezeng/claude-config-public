---
name: surprising-result-check-metric-identity
description: "A surprisingly large effect is a trigger to verify that both sides of the comparison are the SAME statistic from the SAME artifact before it is reported — the C2 pilot's '8.4% better' (2026-08-20) was a per-sample-mean vs ratio-of-sums mismatch; the true gap was 0.56% the other way"
metadata:
  node_type: memory
  type: feedback
  scope: global
  originSessionId: 1ff3aee7-f77f-4f87-ae5d-ee0c32091e66
  modified: 2026-08-20T00:00:00.000Z
---

Before reporting any effect that beats the pre-registered expectation by a wide margin, prove metric identity: both numbers come from the SAME result object (or the same aggregation code path), carry the SAME statistic name AND definition, and reproduce from raw predictions or per-sample records.
Then encode the comparison in a driver that reads both sides from one object, so the check is structural rather than a habit.

**Why:** on 2026-08-20 the C2 pilot was reported to you (twice) as "tail average 8.4% better than the last iterate, helped 10/14, cahn_hilliard 1.79×".
The tail number came from `summary.json`, where `score_panel` emits per-dataset `nRMSE` as the per-sample-MEAN rel-L2 (`metric_source: per_sample_mean`, 0.1685); the last-iterate number came from the result JSON's `c2_last_iterate.nRMSE`, the ratio-of-sums aggregate (0.3017) — two statistics of the same predictions.
Apples-to-apples the tail average was 0.56% WORSE, exactly the "tail ≈ last" the spec predicted; the "encouragement" was withdrawn and the records corrected in place.
The mismatch surfaced only when the next tier's gate driver read both numbers from one JSON and disagreed — a 1.79× single-dataset swing from a passive weight average should have been the tell.

**How to apply:**
- Treat "larger than the spec expected" as a defect signal first and a finding second; the spec's prediction is the prior.
- Never pair a number from an aggregate/summary file with one from a per-run result file without printing the `metric_source`/definition of each; prefer the per-run file for both sides.
- When the surprising number is already out, correct it where it was written and say it was overstated ([[verification-claims-are-earned-per-item]]); do not let the correction wait for the next report.
- Related traps: [[rel-l2-is-level-dominated]] (two definitions of one metric name), [[reconcile-aggregates-against-raw-rows]].
