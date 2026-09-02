---
name: document-rounds-end-when-findings-turn-code-shaped
description: A review finding whose remedy is "define this as a function" or "extend this test matrix" is a CODE finding wearing a document finding's clothes — it cannot converge in prose, so the round that turns majority code-shaped is the round the document is DONE; and `--write` serializes per TREE, so independent tracks get their own worktrees
metadata:
  node_type: memory
  type: feedback
  scope: global
---

Read each round's findings by REMEDY SHAPE, not only by severity.
A finding is **code-shaped** when discharging it means writing a function, a case table, or a test matrix row — "this rule has no implementable signature", "this matrix covers one of the three kinds", "this mutant survives".
A finding is **document-shaped** when discharging it changes what the design DECIDES — a wrong ordering, a missing failure branch, a claim about existing behaviour that is false.

**Once a round is majority code-shaped, the document is converged in the only sense that matters, and further prose rounds are a treadmill.**
Code-shaped findings resolve in minutes at the keyboard and are proven by the test going red; in prose they resolve into wording another lens re-opens next round, one sibling site at a time.
Stop the panel and implement — the implementation IS the remaining review.

**Why:** measured 2026-09-01 on the alerting spec: five document rounds, zero lines of code, and round 5 returned a signature finding plus two test-matrix findings — all three of which the first implementation commit would have settled for free.
Worse, round 4's own FIX minted round 5's blocking HIGH (a migration that permanently silenced the three live incidents the feature exists to report), so an extra prose round is not merely slow, it manufactures defects.
This is the arc-level companion to [[eval-clauses-are-code-not-prose]], which says write the clause as a function; this one says the ROUND KIND tells you when the whole document has run out of prose-answerable questions.

**How to apply:**
- Tally each round `document-shaped : code-shaped` in the dispositions ledger next to the severity scorecard. Majority code-shaped, or zero document-shaped, means implement — even with HIGHs open, because those HIGHs are implementation tasks.
- Fix the code-shaped findings in the SAME commit as the code they describe, never as a spec edit that promises them.
- Group them by shape before implementing: "a named matrix covers only one of N kinds" at two sites is ONE class — [[fix-the-class-not-the-reported-instance]].

**`--write` serializes per TREE, not globally — so give every independent track its own worktree.**
One write run at a time with nothing else dirtying the tree is a per-worktree constraint, and independent tracks touching disjoint files have no reason to queue behind each other.
Measured on the same lane: three tracks (burst copy-back · alerting · run instrumentation) ran their implementations strictly sequentially in one worktree for no reason but the launcher's cleanliness check.
Commit with `-o <paths>` while siblings are live, per [[isolate-agents-that-mutate-the-tree]].
Read-only review lenses never had this constraint and should keep running panel-wide.

**Ship the independent slice rather than the whole document.**
When a spec has two halves joined only by a shared transport and every HIGH is in one half, split at the seam and ship the clean half now.
Measured: the disk-headroom alert (a probe, two thresholds, two templates) was blocked for rounds behind the agent-health half that owned every HIGH — and disk headroom was the half the user could act on soonest.
Pairs with [[merge-green-prs-without-asking]]: an unshipped clean half is its own failure.
