---
name: control-a-settle-detector-on-captured-output
description: A "has it finished" predicate must be controlled against the tool's REAL captured output AND require a derived expected set to be PRESENT — a settled `gh pr checks` drops the pending clause, and its rollup also lags, so "nothing is pending" is satisfied by a list that has not been populated yet
metadata:
  type: feedback
scope: global
---

When you write a predicate that decides **"has this finished?"**, capture the tool's real terminal
output once and control the detector against that captured text. Never hand-write the success case.

**Why.** Measured 2026-08-31 watching PR #332's checks. `gh pr checks` prints
`"12 passed, 0 failed, 9 pending, 21 total"` while running and
**`"22 passed, 0 failed, 22 total"`** when settled — the `pending` clause is *dropped*, not zeroed.
Two predicates failed on the same output shape within one hour, in opposite directions:

- `*"0 pending"*` — fired on `20 pending` (substring), reporting SETTLED against a running build.
  **Failed open.**
- `*", 0 pending,"*` — the fix for that, correct on both invented shapes, but the settled output
  contains no `pending` substring at all, so it never fired. The loop ran to its 90-poll ceiling
  and reported TIMEOUT twenty minutes after CI went green. **Failed closed.**

The second script *carried a control and the control passed*: it proved the predicate rejects
`20 pending` and accepts `0 pending`. Both strings were invented by the same reasoning that wrote
the predicate, so the control tested that reasoning against itself. A control is only independent
evidence when its inputs come from somewhere the predicate's author did not make up.

**A "nothing is pending" predicate is not enough, even structurally.** Measured 2026-09-01 on
`your-org/your-project` PR #48: a minute after pushing, `gh pr checks` returned exactly one row
(`GitGuardian`, pass) — `pending: 0 of 1` — while `repos/.../commits/<sha>/check-runs` showed
**four** checks with **three queued or in progress**. The rollup had not been populated yet. So
`all(.bucket != "pending")`, which this memory previously recommended as the structural fix, is
ALSO fail-open: an empty or partial list satisfies it vacuously. An earlier watcher on the same PR
reported `SETTLED after 630s` on that one row — and the run it was watching had been *cancelled* by
`cancel-in-progress` when the next push superseded it, so there was no green anywhere.

The missing half is **presence**: a settle detector must require the set of checks it EXPECTS to be
there, not merely that nothing visible is pending. Derive that set (for GitHub Actions: parse the
workflow's job names at the sha under test, UNIONed with the base ref — a `pull_request` run
executes the workflow from the MERGE ref, so a job only the base defines still runs), and refuse an
empty derived set as a parser failure rather than reading it as a pass. Working implementation:
`~/.claude/bin/ci-green.sh` + `ci-derive.py`.

**One NAME can carry several check-runs, and keying by name fails open a third time.** Measured
2026-09-01 auditing `ci-derive.py` itself: it built `{name: (status, conclusion)}`, so a second
check-run under the same name — a `workflow_dispatch` run alongside the `pull_request` one, or a
rerun that ADDS a run rather than replacing it — silently overwrote the first, and *which* one
survived was whatever the API happened to list last. A stale green could bury a live red in the one
tool the merge gate depends on. Keep every row and require EVERY row to be green: that fails closed,
where last-wins could have merged over a red. Pinning it took three cases, and the case that killed
the `dedupe-by-name` mutant was the ordering one (running FIRST, green second) — a fixture with the
rows the other way round passes under both implementations, so the fixture, not the assertion, is
what made the property observable. The both-green case is there to prove the rule SATISFIABLE, not
just failable.

**The presence half then failed its own satisfiability test — twice, in `ci-green.sh` itself.**
Measured 2026-09-01 on `your-companyAI/your-other-project` PR #339:

- It hard-coded `GH_TOKEN=$(gh auth token --user your-org)`, an account with no read on that org's
  repo. The `check-runs` call 404'd, the unchecked redirect left an EMPTY `runs.tsv`, and the
  deriver faithfully rendered that as `VERDICT: NOT-GREEN -- jobs never registered; no check-runs at
  all`. A **permission failure printed as a CI result** — and a private repo answers 404 for "you may
  not read this" byte-identically to "it is not there", so nothing in the output said auth. An
  errored read is not evidence about CI: check the API call's exit status and abort on a distinct
  code, because an empty result only means something when the call SUCCEEDED. Never pin a tool to one
  named account; honour the ambient token.
- A matrix job's `name:` is a TEMPLATE. Taking it literally put
  `e2e (chromium layout) ${{ matrix.shard }}/${{ matrix.shardTotal }}` — a name no check-run can ever
  carry — into the required set, so the predicate could report **NOT-GREEN forever**: unsatisfiable,
  exactly the class [[a-guard-must-be-satisfiable-not-just-failable]] warns about, hiding inside the
  fix for the previous fail-open. Expand against the inline matrix (19 concrete leg names): strictly
  STRICTER than dropping the entry, which would have required nothing that exists. The two wrong
  repairs are symmetrical — keeping the raw template is unsatisfiable, silently dropping it is a
  fail-open hole in the presence check — so an UNRESOLVABLE template must refuse as a parser failure.
  Both are pinned by mutants (`expand-only-first-leg`, `ignore-unresolved-template`).

Note the ordering that found these: the *negative* control (force a 404 → must ABORT) surfaced the
auth bug, and the *positive* one (real repo → must yield a real verdict) surfaced the unsatisfiable
set. Running only the failure side would have left a detector that could never say GREEN.

**How to apply.** Prefer a structural terminal condition over string-matching a summary line
(the exit status or a state enum over prose), read the per-commit API rather than a PR rollup,
require presence as well as non-pendingness, and never collapse rows by a key the API does not
promise is unique.
Where you must match text, run the command once at each state you care about, save the bytes, and
assert the predicate against those files. And give the loop a ceiling that *reports* rather than
one that merely stops — a false timeout is recoverable, a false green is not, so when in doubt
build the predicate to fail closed. Related: [[absence-needs-a-probe-that-could-see-presence]] ·
[[a-guard-must-be-satisfiable-not-just-failable]] · [[verify-claims-against-artifacts]] · [[watch-the-run-you-triggered]].
