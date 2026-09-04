---
name: optimize-the-loop-unprompted
description: Profiling and speeding up a repeated loop is owed unprompted at every round boundary, and a directive alone does not fire — run codex-converge's `profile-loop.sh` over the round dirs (a checklist step now calls it); if you can answer "any way to speed this up?" with a concrete list, you already had the list and withheld it; land the fix in the shared tool as code, with a guard for whatever it stops verifying
metadata:
  type: feedback
scope: global
---

The user, 2026-09-01, after being the one to raise loop speed for the second time in a session: *"i wish i didn't need to remind you to figure out how to speed things up. this should be done automatically."*

**The tell.**
Being asked "any way to speed this up?" and answering immediately with a ranked, concrete list is proof of the defect, not a good response — the list existed before the question.
The measured instance: a mutation battery ran a whole 52-test file once per mutant, 9 mutants a round, for several rounds — 468 test executions to verify 9 facts, when each mutant already named the single test that had to kill it.
The fix was one `-t` flag and it had been available the whole time.
Two sibling failures to watch for in the same breath: re-running a 267-file suite to re-count failures when two independent clusters would do, and running independent clusters serially in one worktree.

**A directive no checklist calls is not a mechanism.**
The user, 2026-09-02, one day after writing this rule: *"i thought you already wrote a skill to automatically detect potential ways to speed up the implementation process. did u forget to activate it?"*
The rule sat in `CLAUDE.md` and here, and the YOUR-MODULE phase-1 seat still hand-rolled cp/sed mutants in the live worktree instead of `mutate.py` on a copy, ran a wide suite ten times where a scoped one answered, and wrote no profile until asked — because nothing in the codex-converge round checklist invoked the rule, so it depended on recall at a busy moment and lost.
The mechanism is now `~/dotfiles/claude/skills/codex-converge/profile-loop.sh <round-dir>…`, called by the "Profile the loop at EVERY round boundary" step in that skill's "Keeping the loop short" section: it reads the artifacts a round already leaves (codex run logs and verdicts, vitest / tsc / mutant logs, CI watches) and prints the ranked wall-clock table, the wait time with nothing else in flight, every gap ≥ 30 min, and each lever evaluated as TRIGGERED or quiet with its fail-open.
When a rule keeps needing reminding, the fix is a step with a script, not a louder rule.

**Do this instead.**
At every boundary of any loop you will run more than twice — review round, fix round, verification battery, sweep — run the profiler and paste its timeline and levers into the scorecard: where did the wall-clock actually go, and what is the top item?
Measure it, do not guess it; a stage nobody timed is where the cost is.
Measured on the YOUR-MODULE arc (15 h window, 2026-09-01/02): waits on Codex / `--write` / CI were 1h22m, and 1h13m of that ran with NOTHING else in flight; one 9h24m gap had no artifact at all; ten wide vitest runs of 1–4.5 min stood in for scoped questions; six mutant batteries ran 13 s–1m41s because they re-ran whole files.
Guesses refuted by the same measurement, so do not repeat them: tsc was already incremental (4 s cold, `tsconfig` "incremental": true); `vitest related` on a core module selected 542 of 545 files, so it is not a selector; a "75 s per mutant" figure was a timeout CEILING, and the real run took 5.75 s.
The signature to hunt is a repeated stage paying O(N x M) for an O(N) fact — a per-item check that re-runs the whole population, a full-suite run standing in for one file, a serial queue of independent items.
Then **land the fix as code in the shared tool** (`mutate.py`, the runner, the harness), never as a prose note or a per-arc script, so every session and every future round inherits it instead of rediscovering it.

**A speedup that changes what is verified is not a speedup.**
Name the fail-open before shipping it.
The `-t` filter had a real one: vitest exits 0 when its name filter matches nothing, so the naive version silently converts every `expect: killed` mutant into a passing `survived` — a faster battery that verifies nothing.
It shipped with a fail-closed guard (a filtered run that executed 0 tests is MISARMED, not SURVIVED), unit-tested on captured vitest summary shapes with a control that forces the opposite answer.
Per-item rigor (the mutation checks, the parallel lenses) is what makes cheapening the loop safe; cutting it does not save time, it relocates the cost to a later round.

**Do not hand the levers back as options.**
Anything you can do unilaterally is already authorised — [[standing-directives-are-standing-requests]].
Report the speedup as landed and measured, and raise only the one lever that genuinely needs her word (spend, or a decision that changes scope).
"Say the word and I'll…" about an optimisation you could have already applied IS the finding.

**The ledger, and the gate that makes it fire.**
Since 2026-09-02 `profile-loop.sh` reads the `loop.py` ledger that every attributed `run-codex.sh --arc/--track/--round` launch writes, so the timeline is derived rather than reconstructed by hand.
`loop.py close-round` makes the gate mechanical: the next round's launcher exits 6 until each TRIGGERED lever is dispositioned, and the codex-converge checklist calls it.
That call is the whole point — a directive nothing calls does not fire, measured 2026-09-02, one day after this rule was written.

**The third trigger failure: this rule is one increment late BY CONSTRUCTION, and that is why round 1 is now gated.**
Every lever here fires at a round BOUNDARY, so the cheapest possible reading is taken after a round has already been paid for.
The shape a loop is launched in — serial where it could be parallel, a full panel where a scoped one suffices, a stop written as "until no findings" — is chosen BEFORE the first boundary exists, and no amount of boundary profiling can refund it.
Measured 2026-09-03: she had to ask "any way to speed this up?" a third time, after the ledger and the close-round gate were both already live and both reading green.
Diagnosis: not a directive nobody called, but a directive that could not fire yet.
The repair is a per-arc record priced before the first launch, gated the same mechanical way — `loop.py preflight`, with round-1 `review`/`write`/`mutant` launches exiting `RC_GATE` until it exists — [[preflight-the-cost-before-you-pay-for-it]].
Grandfathering is derived from the ledger (an arc whose paid jobs all predate the gate), never a list of names, and a job refused the lock spent nothing so it grandfathers nothing.

**The fourth trigger failure: a lever that READS is not a lever that ACTS.**
Measured 2026-09-03, with the preflight gate, the ledger and `close-round` all live and all green: the profiler correctly reported 7h34m of review and `--write` waiting that had nothing else in flight, and the arc still spent it, because every lever was a SENTENCE in a report rather than a change in how the next panel launched.
A boundary reading that a human must act on is a recommendation wearing a measurement's clothes, and it fails exactly like the prose rule two increments ago did.
The repair is to make the application mechanical, not the reading: once a review sha exists, snapshot-safe read-only work launches against that frozen sha in its OWN worktree (`loop.py snapshot`) instead of queueing behind an unrelated write; the per-tree exclusive lock and the CPU lock are taken from what a job actually reads and writes (`lock_modes`) so independent lanes overlap and expensive suites do not fight; and a mutation battery, like every other paid job, takes the same round-locked admission transaction so it can neither run against a closed round nor land its wall-clock in the unexplained-gap bucket.
Measured effect on this arc's own rounds: serial sum 2536.8 s against 1172.4 s of wall (53.8% removed) in round 2, and 1887 s against 821 s (56.5%) in round 3.
The generalisation: for every TRIGGERED lever, ask what CODE would apply it at the next launch — if the answer is "the operator reads the table and remembers", the lever is not landed.

Related: [[convergence-loop-speed-rules]] (the four levers this rule tells you to go looking for), [[a-report-is-not-a-stopping-point]], [[reduce-token-burn]], [[extract-learnings-proactively]], [[a-guard-must-be-satisfiable-not-just-failable]].
