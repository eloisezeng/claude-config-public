---
name: a-pinned-review-range-may-contain-already-reviewed-work
description: A brief that pins a review range as BASE..HEAD can pin one that still contains work already merged and reviewed, so measure the overlap instead of obeying either instruction
metadata:
  type: feedback
  scope: global
---

A brief that pins a review unit as `BASE..HEAD` and ALSO says "do not re-review the earlier stage"
is usually naming two different ranges without noticing, because a stacked branch keeps the earlier
stage's ORIGINAL commits while the default branch took that same diff as a SQUASH.
Reviewing the pinned range then re-reviews merged, deployed, verified code, and both instructions
read as satisfied either way — the conflict is invisible until you measure it.

Measure the overlap rather than picking an instruction: name the already-merged sha, and take
`comm -23 <(git diff --name-only BASE..HEAD | sort) <(git diff --name-only MERGED_SHA..HEAD | sort)`.
What that prints is exactly the files only the wider range carries, i.e. the earlier stage's.
Re-scope to the later stage's own first commit, and put the excluded files in the lens prompt BY
NAME with the merge sha and the deploy id beside them, so a lens that reads one of them for context
cannot file against it.

This is a cost cut as well as a correctness one, which is why it belongs in the round-1 preflight's
`--scope`: measured 2026-10-26, re-scoping a 37-file / +3,752 unit to its own 30-file / +2,493 half
removed 7 files and ~1,259 lines from both lens prompts before a token was spent, and every one of
the round's 5 findings then landed in-scope (0 pre-existing, 0 unlocatable) — a triage with no
pre-existing lane to file at all, which is what a correctly scoped range looks like.

Expect the same brief's other inherited numbers to be stale in the same way: the stated file and
line counts re-measured differently, and its "main gained two commits" was four.
Related: [[an-inherited-environment-fact-is-a-stale-measurement]] ·
[[triage-review-findings-by-intersecting-cited-lines-with-the-diff]] ·
[[preflight-the-cost-before-you-pay-for-it]]
