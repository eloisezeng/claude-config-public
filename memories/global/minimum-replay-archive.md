---
name: minimum-replay-archive
description: "An archived model artifact is replayable only with all three of checkpoint + dataset + exact code/commit; and regenerate predictions on the SAME device class before comparing numbers"
metadata:
  scope: global
  type: feedback
---

Archiving weights is not archiving reproducibility. The **minimum replay archive is three things, and two of them are the ones people drop**:

1. **The checkpoint** — the only one anybody remembers.
2. **The dataset**, at the path the harness resolves. Hub-mirroring the bytes does not help if the local mount is what the loader reads — see [[recoverable-is-not-unused]].
3. **The exact code, pinned by COMMIT, not just by a content hash.** A content hash (`code_rev`-style) is an identity: it proves which code ran, but nothing points back from it to a tree. Recovering that tree means searching history for a commit that reproduces the hash. Record the commit *beside* the hash at production time.

Keep the hash as the identity and the commit as a recovery pointer — a commit does not determine a content hash over a file subset, and two commits routinely share one. Where a program already computes the sha at production time (a `record_identity()`-style helper), the bug is usually that one producer *discards* it, not that it is unavailable.

**Regenerate on the same device class before comparing numbers.** Verified on the MFFP box 2026-08-18: replaying a checkpoint CPU→CPU is bit-exact, but the archived GPU-produced predictions differ from a CPU replay by ~3e-4 relative. That is harmless for a field-level sanity check and NOT harmless for a metric — on a dataset whose nRMSE was 7.8e-5, the same float noise moved the metric by 3.2e-3 relative, because a near-zero error has proportionally less precision to spare (same failure shape as [[rel-l2-is-level-dominated]] if that is in scope). Sanity-check on CPU if it is convenient; produce numbers that go in a table on the GPU.

**Why:** deleting an artifact class on the strength of "it's regenerable" is only sound if regeneration has actually been performed once. The claim is a hypothesis until then — see [[verify-claims-against-artifacts]].
