---
name: surprising-result-check-metric-identity
description: "A surprising effect OR two numbers disagreeing are both triggers to verify metric identity — same statistic, same rule, same artifact — before reporting either; the C2 pilot's '8.4% better' (2026-08-20) was per-sample-mean vs ratio-of-sums (true gap 0.56% the other way), and three passes over an UNCHANGED file (2026-08-28) gave 33/49, 35/54 and 35/56 purely from different counting rules"
metadata:
  node_type: memory
  type: feedback
  scope: global
  originSessionId: 1ff3aee7-f77f-4f87-ae5d-ee0c32091e66
  modified: 2026-08-20T00:00:00.000Z
---

Before reporting any effect that beats the pre-registered expectation by a wide margin, prove metric identity: both numbers come from the SAME result object (or the same aggregation code path), carry the SAME statistic name AND definition, and reproduce from raw predictions or per-sample records.
Then encode the comparison in a driver that reads both sides from one object, so the check is structural rather than a habit.

**Why:** on 2026-08-20 the C2 pilot was reported to the user (twice) as "tail average 8.4% better than the last iterate, helped 10/14, cahn_hilliard 1.79×".
The tail number came from `summary.json`, where `score_panel` emits per-dataset `nRMSE` as the per-sample-MEAN rel-L2 (`metric_source: per_sample_mean`, 0.1685); the last-iterate number came from the result JSON's `c2_last_iterate.nRMSE`, the ratio-of-sums aggregate (0.3017) — two statistics of the same predictions.
Apples-to-apples the tail average was 0.56% WORSE, exactly the "tail ≈ last" the spec predicted; the "encouragement" was withdrawn and the records corrected in place.
The mismatch surfaced only when the next tier's gate driver read both numbers from one JSON and disagreed — a 1.79× single-dataset swing from a passive weight average should have been the tell.

**Escalation (2026-08-26, the same class one level up):** the round-4 BAR itself was metric-mismatched — the mentor's matrix (per-sample-mean rel-L2 by strong inference) was compared against ratio-of-sums nRMSE across an entire certification campaign, manufacturing a fictitious 20-28% "film-lineage gap" that survived a pilot, a diagnosis, and two 90-cell certifications.
Adopting ANY external artifact as a comparator therefore requires, BEFORE first use: (1) a named-statistic contract for the artifact, (2) reproducing at least one of its values end-to-end from raw predictions under that statistic, (3) an executable gate refusing comparisons whose our-side key differs (the `eval/bar_gate.py` pattern: metric contract + full-panel reproduction table + itemized/waived outliers).

**How to apply:**
- Treat "larger than the spec expected" as a defect signal first and a finding second; the spec's prediction is the prior.
- Never pair a number from an aggregate/summary file with one from a per-run result file without printing the `metric_source`/definition of each; prefer the per-run file for both sides.
- When the surprising number is already out, correct it where it was written and say it was overstated ([[verification-claims-are-earned-per-item]]); do not let the correction wait for the next report.
- **The same check applies to a DISAGREEMENT, not just a surprise.** When two counts of one artifact differ, the artifact is rarely the variable — the RULE is. Run the gap down to named items before reporting either number, and never report the side you happen to hold while an unexplained delta stands.
- **A count is not a measurement until its rule is stated.** Publish the rule with the number (corpus, what counts as a member, at which commit), because a bare count cannot be re-derived or disputed — it can only be believed.
- **Validate a walker on the number already agreed before trusting it on the unknown one.** A method that cannot recover the known figure is not evidence about anything else; a method that does recover it has earned exactly one step of extrapolation.

**Second instance (2026-08-28, Treecue §13).** Three passes over a file that did not change produced 33 files/49 lines, 35/54 and 35/56, and each pass reported the previous one as "not reproducing". Nothing had moved — the figures were byte-identical across three commits. An alias-only grep (`@/plugins/`) could not see relative-form imports (`../../plugins/…`); a rule requiring `import` and `from` on one physical line could not see multi-line `} from '…'` specifiers. Closing both blind spots made two independent methods converge. The round that "corrected" the original number had introduced the error, and the original figure was right all along — so **a correction is a claim like any other and earns its own reproduction**, especially when it overturns something ([[re-read-cannot-tell-wrong-from-acted-on]], [[verification-claims-are-earned-per-item]]).

- Related traps: [[rel-l2-is-level-dominated]] (two definitions of one metric name), [[reconcile-aggregates-against-raw-rows]].

- **A predicate is an artifact too — writing the rule down is necessary and not sufficient.** Stating the counting rule is what makes two numbers comparable, but the statement is itself unchecked until someone evaluates it. Measured 2026-08-28: a peer's confirmation message stated its resolution rule as `@/` → `src/` when the repo's tsconfig maps `"@/*"` → `"./*"` — a literal reading yields 0, not 35, so its code could not be doing what its prose said. Check a stated predicate against the artifact it claims to describe, and note which of its choices the agreement does NOT test: two readings that agree *because* they made the same silent choice (here, counting type-only imports as edges) are one test, not two.
