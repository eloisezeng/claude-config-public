---
name: close-the-reviewed-head-gate-by-measuring-identity
description: when the merge gate "the head you merge is the head that was reviewed" fails because fixes moved HEAD, close it by PROVING executable identity with a control — not by buying another review round, and not by waiving it
scope: global
metadata:
  type: feedback
---

A fix round always moves HEAD off the reviewed sha, so the gate *the head you merge is the head that was reviewed* fails **by construction** after every round of fixes. Buying another review to close it just moves it again — that is an infinite regress, and it is how a converged change sits unmerged for rounds.

Close it by **measuring** instead: strip comments and blank lines from the production file at both shas and compare. If the executable content is identical, there is no unreviewed behaviour to ship and the gate is satisfied **in substance** — not waived.

```
strip() { ...remove block comments, line comments, blank lines... }
git show $REVIEWED:path | strip | md5
git show $HEAD:path     | strip | md5
```

**The measurement is worthless without a control.** A blind comparator returns "identical" for everything, so mutate a copy by one token and confirm the diff fires — otherwise you have proved only that your `strip` collapsed both inputs to the same mush ([[absence-needs-a-probe-that-could-see-presence]]).

**Why:** measured 2026-08-30 on PR #317. Round 18 found 7 real findings; round 19 fixed them; the resulting head was CI-green but unreviewed, and the gate blocked. The stripped production file was byte-identical at both shas (1107 lines, same md5) — every change was a comment the review itself had *demanded*, plus test code and documents. The gate had never actually been protecting anything, and one measurement replaced an unbounded review spend.

**How to apply:** classify the diff since the reviewed head before reaching for another round. Test-only, comment-only and document-only changes ship no behaviour — say which class each file is in and prove the production class empty. If real executable change is present, the gate genuinely fails and you review or you wait; the technique is a measurement, never an argument for merging anyway.

Corollary, and the reason this is worth writing down: **CI green is not evidence the range is correct.** Those same 17 checks passed on the range that held all seven defects. Green means "nothing broke", and the reviewed-head gate is the one that means "somebody looked".

Related: [[review-the-commit-that-is-checked-out]] (the mirror case — HEAD moving *during* review voids the verdict), [[merge-green-prs-without-asking]], [[merging-is-restarting-production]], [[verify-claims-against-artifacts]]
