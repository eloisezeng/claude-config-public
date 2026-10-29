---
name: a-pr-head-can-lag-a-landed-push
description: "A pull request's headRefOid is GitHub's RECORD of a push, not the push — a dropped `synchronize` leaves the PR stuck on an older sha with no check-run on the real head, and waiting is unbounded"
metadata:
  node_type: memory
  type: reference
  scope: global
---

A `pull_request` check lives on a **head sha**, and the head sha a pull request reports comes from the `synchronize` webhook rather than from the ref itself.
When that event is dropped or coalesced, the branch ref and the pull request disagree, and nothing ever reconciles them on its own.

Measured 2026-10-26 on your-other-project PR #510: `git ls-remote origin <branch>` and the local remote-tracking ref both read `65af94fc`, and `GET /repos/O/R/commits/65af94fc` returned the object — so the push had landed and GitHub held the commit.
The pull request's `headRefOid` nevertheless stayed at the parent commit `4946e29f` across five readings over six minutes, with a run in flight on that parent and **zero check-runs of any kind on the real head**.
Two commits had been pushed seconds apart, which is the shape that invites the coalesce.

**Why waiting is the wrong response.** A merge gate of the form "every required check green on the exact head you merge" can never be satisfied while the pull request's head is a sha nobody will merge, so the wait has no bound — it is not latency.

**How to apply.** Read the head from BOTH sides before believing either: `git ls-remote origin <branch>` for the ref and the pull request's own `headRefOid` for the record, and treat a disagreement as a dropped event. The repair is to move the ref again so a fresh `synchronize` fires — any real commit you owe anyway (a progress note, a changelog line) does it, and it costs no extra CI because a green run was owed on whatever head the merge takes. The run on the stale sha is cancelled by the same push, which is correct: that sha is not the one being merged. Registration after the repair push was immediate, which is itself the evidence that the first event was lost rather than slow.

Pairs with `[[watch-the-run-you-triggered]]` — same root rule, that a check is about one sha and never about "the branch" — and with `[[conflicted-pr-gets-no-ci]]`, the other way a pull request ends up with no checks for a reason that is not the workflow.
