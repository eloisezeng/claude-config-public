---
name: a-tree-validating-reviewer-is-invalidated-by-any-write
description: a reviewer that validates "the tree did not move" is voided by ANY concurrent write of mine, including to files it never reads — plan the panel and the battery as exclusive phases, not as disjoint artifacts
metadata:
  type: feedback
  scope: global
---

A read-only reviewer that guards its verdict with "the tree did not move while I
read it" is checking `git status`, not the files it opened. So ANY write of mine
in that window voids it — including a write to a file the reviewer never reads,
and including one a tool puts in a scratch directory. The signal is `rc=5 TREE
MOVED during the read: HEAD <x>→<x>, content/status changed; child rc=0`: the
child SUCCEEDED and its verdict is quarantined to `<out>.verdict.json.tree-moved`
anyway, so the work is paid for and the round is not closed.

**Why I got this wrong, which is the part worth keeping:** my own written
preflight said "the mutation battery runs on a COPY while the lenses are out,
since mutants and reviews touch different artifacts". That reasoned about
ARTIFACTS when the detector reasons about the TREE — and `mutate.py`'s
`--copy-dir` is *required* to be inside the worktree and git-ignored, so its copy
is the one place that is both safe for mutants and fatal for a concurrent review.
Writing new tests in the same window was the second writer.

So the question at plan time is never "do these touch the same files?" but **"does
anything I am about to run write inside that worktree?"** — and the answer for a
mutation battery, a test I am authoring, and a progress note in `docs/` is all
yes. Sequence them as EXCLUSIVE PHASES of the round (panel out → nothing written
→ panel in → fix → battery), or give the mutating half its own worktree
(`isolation: "worktree"`, or a second linked checkout) so the reviewed one stays
still. Measured 2026-10-06: 4 lenses launched, 1 finished before I started
writing and returned a verdict, 3 were quarantined at rc=5 and had to be re-run.

Read a quarantined verdict anyway — it is already paid for and its findings were
real (6 defects, all reproduced) — but re-run for the verdict OF RECORD, because
what it read is not what is on disk now.

Related: [[isolate-agents-that-mutate-the-tree]] ·
[[never-arm-a-fault-in-an-auto-syncing-tree]] · [[preflight-the-cost-before-you-pay-for-it]]
