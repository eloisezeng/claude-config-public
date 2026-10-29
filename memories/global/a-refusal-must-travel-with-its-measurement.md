---
name: a-refusal-must-travel-with-its-measurement
description: A recorded refusal stops a lever being re-proposed, which also stops it being re-measured — so a refusal travels into the implementer's brief WITH its number, its date and its rule, or it travels not at all
scope: global
metadata:
  type: feedback
---

A refusal is recorded so the same lever is not re-proposed next quarter.
That is exactly why it is dangerous to carry forward bare: it suppresses the **re-measurement** as effectively as the re-proposal, and a refusal resting on an estimate is a refusal that may be wrong.

So a refusal reaches the brief an implementer boots from, or it reaches nobody — **and it arrives with the number, the date, the rule that produced the number, and an explicit invitation to re-measure.**
Writing it only into the document the user read, or only into your own lane record, leaves it in the two places that cannot stop the lever.

**Why:** measured 2026-10-26 on `your-other-project`. I refused gating the nightly full suite on the commit having changed, on an estimate of ~960 billed minutes a month, reasoning that the suite's distinctive value over an unchanged tree is time-dependent rot. I wrote that refusal into the published decision document and into my lane's handoff, and **not** into the brief I dispatched the implementer with. The implementer never saw it, measured the bill from a standing start, and got **1,081 of 1,177 billed minutes over 30 days — 92% of the entire Actions bill, with 20 of 20 sampled nights running against the same unchanged commit.** It then shipped a *weekly floor* rather than the unconditional skip I had refused, so a date-dependent failure surfaces within seven days instead of never. My refusal was wrong, and the only reason it was corrected is that it failed to travel.

Two readings follow, and the second is the load-bearing one:

- The omission was a defect in my brief. A refusal in the artifact the user reads is not in the artifact the next worker acts from.
- Had the bare refusal travelled, it would have cost the better measurement. Two independent measurements landing near each other from different directions (~960 against 1,081 of 1,177) are worth more than either figure alone, and a bare "declined, see earlier" produces exactly one.

**How to apply:**
- Put every refusal in the dispatch brief, in a "considered and declined" section, each with its number, the query or rule behind it, the date measured, and the words "re-measure before deferring to this".
- A refusal older than the thing it refuses is a prompt to measure, never a verdict. State its age in the same sentence as its number.
- Distinguish the refusal's SHAPE from its direction: I refused an unconditional skip and what shipped was a floored one. A successor reading only "declined" cannot see that a materially different design was never refused, so name what was refused precisely enough that a neighbouring design is visibly not covered.
- When a successor's measurement beats yours, correct the user-facing artifact **in place**, and say in the record that the figure was an estimate — not that the successor overruled you.

Related: [[preflight-the-cost-before-you-pay-for-it]], [[optimize-the-loop-unprompted]], [[verify-claims-against-artifacts]], [[an-inherited-environment-fact-is-a-stale-measurement]], [[a-gitignored-doc-store-does-not-reach-a-fresh-worktree]].
