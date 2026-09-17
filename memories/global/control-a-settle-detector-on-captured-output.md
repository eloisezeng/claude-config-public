---
name: control-a-settle-detector-on-captured-output
description: A "has it finished" predicate must be controlled against the tool's REAL captured output AND require a derived expected set to be PRESENT — and that set may only name jobs the EVENT can actually register (file `on:`, job `if:`, the head's copy of a shared workflow), or the gate is unsatisfiable and the PR is unmergeable forever
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
workflow's job names at the sha under test, plus the base ref's copy of any workflow FILE the head
does not have at all — a `pull_request` run executes the MERGE ref; per-file, not per-job, for the
reason in the 2026-09-08 section below), and refuse an empty derived set as a parser failure rather
than reading it as a pass. Working implementation:
`~/.claude/bin/ci-green.sh` + `ci-derive.py`.

**Presence has an ordering half too: a ROLLUP JOB publishes its own check-run AFTER the jobs it
reads.** A rollup (`needs: [...]` + `if: always()`) cannot start until its inputs finish, so there
is a real window in which every job you can see has concluded and the one name branch protection
actually requires has not appeared yet. Measured 2026-09-15: a detector armed on the six jobs
present at arm time read SETTLED while the required rollup `test + typecheck` was still to come,
and only the act-time re-check reading `--required` explicitly caught it before a merge. The
derived-expected-set rule above already covers this, because a rollup job is a job in the workflow
and lands in the derived set — but a detector that snapshots "the jobs that exist right now"
instead of deriving them will miss it every time, and it will miss it silently.

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
Measured 2026-09-01 on `your-org/your-other-project` PR #339:

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

**A check-run's `status` and its `conclusion` can disagree, and the fix's own strictness became
the fourth fail-CLOSED.** Measured 2026-09-02 on `your-org/your-other-project` sha `0f566b00`:
`repos/.../commits/<sha>/check-runs` served the job `deploy freeze check` as
`status="in_progress"` **with** `conclusion="success"`, while the workflow run itself read
`completed`/`success` and the other 23 check-runs all read `completed`/`success`. `ci-derive.py`
required `status == "completed"` per row, so it reported `NOT-GREEN -- still running` on a commit
whose CI had finished, and the watcher ran to its 2400 s ceiling ~40 minutes after green. The rule
is: **a row carrying a conclusion is finished, whatever its `status` says** — `conclusion` is written
only at finalization, so this is not a loosening; a row with an empty conclusion still counts as
running, and a `completed` row with an empty conclusion still fails as not-successful. Both
directions are pinned (cases 19–21 against the real capture, mutant `require-completed-status`).
Note what the earlier controls could not see: every fixture in the suite had been captured at a
moment when the two fields agreed, so the disagreement was not *in* the captured output until this
commit produced it. Capturing real bytes buys you the states you happened to observe, not the state
space — when a predicate reads two fields, control it on them disagreeing even if you have never
seen that.

**The expected set may only name jobs the EVENT can actually register — the fifth fail-CLOSED, and
the first one a PR could not fix by any commit.**
Measured 2026-09-08 on `your-org/your-other-project` PR #419, which cut CI spend by moving the
19-leg chromium sweep behind `if: github.event_name == 'schedule' || github.event_name ==
'workflow_dispatch'`, deleting the `repo layout` job and moving the your-module job into its own file.
The deriver read the workflow's jobs and demanded all of them, so the required set carried
`e2e (chromium layout) 1/19` … `19/19` plus `repo layout` on every pull request — names no pull
request can produce.
Two separate causes, and both are the same mistake at different scopes:

- **A job-level `if:` is the file-level `on:` block one level down.** A job the event cannot satisfy
  registers no check-run, so requiring it is permanently NOT-GREEN. Read only EVENT conditions and
  fail closed in both directions: an `if:` naming no event context (`always()`, `success()`, a
  `needs.*` result) decides nothing about registration and the job stays REQUIRED; a plain
  disjunction of `github.event_name == '<literal>'` is evaluated; anything else touching that context
  is REFUSED BY NAME, because guessing "it runs" rebuilds the permanent red and guessing "it is
  skipped" is a fail-open hole. A *step's* `if:` is indented deeper and is not the job's — anchor the
  match exactly rather than searching the job body.
- **For a shared workflow file the HEAD's copy wins.** The base-union rule above is true of a
  workflow FILE the head does not have (the merge ref still contains it, so its jobs still run) and
  FALSE of a job the head deleted from a file both sides have (the merge ref carries the head's edit
  of that file). Reading both copies of the same file is what demanded `repo layout` from a PR that
  had deleted it. The residual hole — a job the base ADDED while the PR was open — is fail-open in
  the recoverable direction: that job still registers and still has to be green.

The asymmetry that decides every one of these calls: an unsatisfiable required set is WORSE than a
narrow fail-open hole, because a job that did register is still checked for greenness by the rows
loop, while a job that never registers can never be made green by any commit.

**A CORRECT exclusion can still leave its subject with no reporter at all — ask that question in
the same change.** Dropping the schedule-only jobs from a commit-scoped verdict is right, and
everything above argues for it. What it also did was leave the nightly full suite, which by then
was the ONLY full-suite run anywhere, reported by nothing: `ci-green.sh` answered `VERDICT: GREEN`
for a pull-request sha on 2026-09-14/15 while that workflow was red on the default branch, and it
stayed red for **44 hours**. The detection worked perfectly and twice; the silence was total, and
the pull request that eventually repaired the defect said in its own message that nothing had
caught it. Note the shape: nobody made a mistake at the exclusion. The exclusion was the correct
scoping decision, and the gap opened underneath it.

The general form, which is wider than CI: **whenever you correctly exclude something from a
verdict, name what still REPORTS it, and if the answer is nothing, that is the change's own
finding.** The fix is not to widen the verdict — that re-introduces the unsatisfiability the
exclusion existed to avoid — but to add a second, differently-scoped channel. Here that is an
advisory printed beside the verdict without touching it or its exit code, plus an ops lane that
restates until the run goes green. Both are cheap precisely because they are not the verdict.

Two things this cost that are worth carrying:
the pre-existing test pinning the base-union rule went red on the correct fix, and its comment — "a
job only the base defines still runs" — was true of the FILE case and false of its own fixture, which
both shapes separately, prove the rewritten assertion reddens under the old code, and add the
base-only-FILE case the old test had meant to protect.
And the mutant harness itself was fail-open reporting: a mutation whose anchor had gone stale wrote
no copy, so running the missing file exited non-zero and printed `CAUGHT` — a mutant that was never
built reads exactly like one the suite killed. Check the build's own exit status and fail loudly,
and control that check with a deliberately stale anchor.

**How to apply.** Prefer a structural terminal condition over string-matching a summary line
(the exit status or a state enum over prose), read the per-commit API rather than a PR rollup,
require presence as well as non-pendingness, and never collapse rows by a key the API does not
promise is unique.
Where you must match text, run the command once at each state you care about, save the bytes, and
assert the predicate against those files. And give the loop a ceiling that *reports* rather than
one that merely stops — a false timeout is recoverable, a false green is not, so when in doubt
build the predicate to fail closed. Related: [[absence-needs-a-probe-that-could-see-presence]] ·
[[a-guard-must-be-satisfiable-not-just-failable]] · [[verify-claims-against-artifacts]] · [[watch-the-run-you-triggered]].

The ready-made detector is `~/.claude/bin/ci-green.sh <sha> [base-ref]`, tested by `~/dotfiles/claude/bin/ci-green.test.sh`. Its two predecessors both failed on real captured output: `*", 0 pending,"*` never fired because `gh pr checks` drops the pending clause entirely once nothing is pending, and `*"0 pending"*` matched inside `20 pending` and called a running build SETTLED.

**Calling the correct tool does not inherit its correctness.** A poll loop wrapping `ci-green.sh`
tested `case "$v" in *GREEN*) ... ;; *NOT-GREEN*)` — and since the failing verdict `NOT-GREEN`
*contains* the succeeding token `GREEN`, the first arm won and it announced a green while all four
jobs were `in_progress` (measured 2026-09-07, immediately after a merge). The tool's verdict line
was right; the wrapper destroyed it. So: when two verdict tokens are substrings of each other, match
the negative first AND anchor (`grep -q '^VERDICT: GREEN'`), and control the wrapper the same way
you controlled the tool — here, running it against one sha that was genuinely green and one that was
still running proved each matched exactly one arm.
