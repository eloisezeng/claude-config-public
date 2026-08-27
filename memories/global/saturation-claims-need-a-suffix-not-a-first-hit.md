---
name: saturation-claims-need-a-suffix-not-a-first-hit
description: "beyond N, more buys nothing" is a SUFFIX property over the searched range, not the first N that touches the floor — compute both when the metric is non-monotone
metadata:
  type: feedback
scope: global
---

Any claim of the form *"beyond N, more X buys nothing"* asserts a **suffix** property — the metric is at its
floor at N **and at every larger N through the end of the searched range**.
The first N at which the metric touches the floor is a different quantity, and the two coincide only when the
metric is monotone in N.
Print the quantity the sentence actually needs, or do not write the sentence.

**Why:** measured 2026-08-21 on `scripts/e2e-shard-plan.mjs`.
Playwright shards a suite into CONTIGUOUS blocks of the declaration order, so the worst-leg duration is
violently **non-monotone** in the shard count: durations `[1,0,1,2,0,1,1]` have floor 2, reach it at N=3, rise
back to 3 at N=4 and N=5, and stay at the floor only from N=6.
The tool computed the first hit and printed the saturation sentence beside it.

**How to apply:** compute `floorFirstAt` (first N at the floor) *and* `floorStableAt` (scan **down** from N=T
while the metric is still at the floor), and branch the sentence on whether they are equal.
Watch for the trap that hides this class: on both real inputs the two values were identical (92/92 and 79/79),
so the printed sentence was true on the only data anyone ever ran it against.
An implementation wrong in general and right on the live data is the kind that survives indefinitely and then
decides something — which is the argument **for** fixing it, not against.
Same shape as [[plan-assertions-need-reachable-alternatives]]: the fixture has to make the wrong answer
reachable, and a degenerate or monotone input never does.
