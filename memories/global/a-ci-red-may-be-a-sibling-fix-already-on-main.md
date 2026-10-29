---
name: a-ci-red-may-be-a-sibling-fix-already-on-main
description: "Before fixing a CI red your branch cannot explain, check whether a sibling already fixed it on main — and if the conflict lands in the file you fixed, read their version before resolving, because your fix may be superseded rather than mergeable"
metadata:
  node_type: memory
  scope: global
  type: feedback
---

A CI red that does not reproduce locally, in code your branch does not touch, is as likely to be a
sibling session's known problem as your own defect. **Measure the branch population before writing a
second fix**: list the last ten runs of the workflow with each branch and conclusion, then look for
branches whose NAMES describe your symptom and for commits on `main` newer than your merge.

Measured 2026-10-28 on `your-org/your-other-project`: a dashboard e2e test failed twice on my branch
while eight other branches went green, which kept my branch implicated — but two sibling branches
named `fix/dashboard-e2e-ci-reliability` and `fix/pipeline-first-load-after-deploy` had appeared in
the previous hour, one of them a minute after my failing run started, and `git log origin/main..` on
both printed NOTHING because they had already merged. Their fix was the cure: the suite now serves a
PRODUCTION BUILD instead of `next dev`, which removes the mechanism entirely rather than papering
over it. Merging `main` again was the whole repair, and it cost one command.

**The sharp half is what happens next.** The merge conflicted in exactly the two files my own fix had
touched, because the sibling had rewritten the same helper. The reflex is to re-apply your side. **Read
their version first**: theirs had DELETED the retry my fix repaired, and had added a test pinning the
new behaviour (`fails on the FIRST attempt even when the server severed it`). Re-applying my fix would
have restored a mechanism they removed on purpose, with a green suite either way. The resolution was
to take theirs wholesale — proved by hashing each file against `origin/main`'s blob, never by test
colour — and to retire my positive-control test in the same commit rather than leave it asserting a
path that no longer exists.

A fix being correct for the code as it stood does not make it correct for the code as it now is. Keep
the half of your work the merge does not touch (my timing fix survived and was the half that mattered),
and say plainly in the merge message which half was superseded and why — `[[merge-clean-is-not-merge-correct]]`,
