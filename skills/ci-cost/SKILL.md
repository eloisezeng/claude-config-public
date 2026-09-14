---
name: ci-cost
description: "Use when CI is first created, audited, or materially changed (adding, removing, sharding, skipping or reordering a job): the GitHub Actions billing model, how developer waiting time and billed minutes move in opposite directions, and the measured traps in sharding, rollups and affected-test selection"
---

# CI cost: developer waiting time and billed minutes

Two different quantities are at stake, and every decision here trades one against the other.

**Developer waiting time** is the wall clock a person waits for a pull request to go green.
It is the MAXIMUM over the required checks, never the sum and never the mean.
**Billed minutes** is the sum over every job of that job's own duration, rounded up.

The user's standing ranking, recorded 2026-09-13: rank a lever by waiting time removed first and billed minutes second, refuse anything that lengthens a pull request's wait, and never buy either with correctness.
Spending substantially more minutes for a tiny speed improvement is not automatically worthwhile.
Every lever that runs the SAME checks more cheaply is approved; deleting checks is refused.

## The billing rule

```
billed_minutes(job) = max(1, ceil((completed_at - started_at) / 60))
```

Three consequences follow, and all three are counter-intuitive.

- A skipped job bills **zero**, so a correctly conditioned job is free rather than cheap.
- Every matrix leg is its OWN job with its OWN rounding, so splitting one 6-minute job into six 1.2-minute legs bills 12 minutes, not 7.2.
  Many small jobs multiply rounding waste.
- Deduplicating setup ACROSS jobs buys waiting time, not minutes, because the minutes it removes are almost always inside a rounding remainder somebody is already paying for.
  Measured on one such hoist: 45 to 44 billed minutes, against 2,582 to 2,419 machine seconds.
  Never re-propose setup deduplication as a minutes saving.

A saving read off a wall clock is a unit error.
One lever recorded as saving "about 145 minutes a month" re-measured at about 950 once the real billing rule was applied.
Compute every saving from `max(1, ceil(...))` per job, never from elapsed seconds.

## Mode A: a repository that is getting CI for the first time

Start from these defaults rather than discovering them later.

1. **One required check name per concern, backed by whatever job topology you like.**
   A rollup job that other jobs feed into lets you reshape the topology later without touching branch protection.
   Reshaping a required check name is the expensive change; reshaping what feeds it is cheap.
2. **Do not shard until one runner is measurably saturated.**
   Sharding is the lever with the worst cost curve in this document, and a suite that fits on one runner pays nothing for staying there.
3. **Set the test runner's worker count explicitly.**
   Vitest's fork pool defaults `maxWorkers` to `availableParallelism() - 1`, which is **1** on a standard 2-vCPU runner — a serial suite nobody chose.
   Fixing exactly that cut one job 14.2%.
4. **Filter documentation-only changes with `on: pull_request: paths:` at the WORKFLOW level, and gate STEPS rather than jobs inside it.**
   A `paths:` filter exists only at the `on:` level, never per job.
   See the fail-open trap below for why a job-level `if:` is dangerous.
5. **Run the exhaustive things on a schedule, not on every pull request** — the full matrix, the slow browsers, the long soak.
   A nightly run on the default branch is the backstop that makes every per-pull-request narrowing defensible.
6. **Write down which check is the critical path** the first time you measure it.
   Every later optimisation is worthless unless it lands on that check.

## Mode B: auditing an existing repository's CI cost

Run these in order.
The order matters, because steps 1 and 2 routinely refute a lever that looked obviously correct.

### Step 1: measure the critical path before optimising anything

Pull the real run history and ask, per run, which required check finished LAST.
A check that is never last is not on the critical path, and time cut from it buys zero waiting time.

Measured example: over eighteen runs, the end-to-end browser check finished later than the test job in **zero** of them, with a floor around 454 to 526 seconds.
Every second cut from the test job was a real second off the wait, down to that floor and not one second further.
That single measurement flipped a recorded refusal of sharding into an approval.

### Step 2: partition the median by regime before quoting it

A blended median describes no real pull request.
In one repository about **28%** of pull requests are documentation-only and finish in 14 to 17 seconds; two superseded figures are on record there precisely because they blended those into the same median as a full run.
Report the regimes separately, with the share of pull requests in each.

### Step 3: count the census with a scanner that blanks strings and comments first

A bare grep over source text counts fixture literals and imports as if they were calls.
Measured: "about 79 seconds of fixed sleeps across 18 nested test-suite runs" was approved on those numbers and re-measured at **5,675 milliseconds across 72 sites and 6 real nested spawns** once the scanner blanked string literals — an overstatement of roughly sixteen times.
Blank strings and comments, then count.

### Step 4: price every lever, including the one you were not going to buy

The obvious lever is frequently the worse one.
Measured: fixing the worker count cut the job 14.2%, while the bigger runner that looked like the real answer was priced at about 0.7 times the cost on four cores and about **1.4 times** on eight — and a worker-count fix is a no-op on a larger runner by construction, so the two levers are not additive.

### Step 5: measure the before state with real runs, never with a projection

A projected lever can measure to zero.
Four projected "load flakes" worth about 4,000 minutes a month occurred **zero** times across 104 failed runs.

### Step 6: decide, and record what you refused

A refusal with its measurement is as valuable as a saving; it stops the same lever being re-proposed next quarter.

## The traps, each with the measurement behind it

### Sharding costs superlinear machine time once the runner is saturated

Measured: the same suite took **1,679 seconds on one runner and 2,190 across three**, a 30% increase in machine time.
The decomposition was 511 seconds of lost parallelism, 246 seconds of duplicated setup, and 23 seconds of new job overhead.
The parallelism loss DOMINATED, which is the opposite of what the design predicted — the design had budgeted for duplicated setup alone.
Budget sharding on measured machine seconds, never on duplicated-setup arithmetic.

### Sharding under a hash partition is not monotonic in the shard count

Vitest's `BaseSequencer.shard` slices a lexicographic sort of `sha1(file path)`.
That is a RANDOM partition, not a duration-balanced one, so the slowest shard is governed by luck.
Simulated against real per-file durations, the imbalance ran +24% at two shards, +42% at three, +70% at four, +72% at six, and **+188% at eight** — at eight shards the wall clock is worse than at six.
The shipped three-shard run measured +14.5%, so the simulation was pessimistic; the rule that survives is to simulate the real algorithm and then verify against the live run, never to trust either alone.
Balance also drifts silently on every file added, renamed or deleted, so a shard count that was right once decays.

### A job-level skip on a required check leaves the pull request unmergeable forever

A skipped job publishes **no status at all** — not a green one.
Branch protection waits for a status that will never arrive.
A documentation-only fast path must therefore gate the STEPS inside the job, letting the job itself run and report success in a couple of seconds.
A job-level `if:` is safe only on a job whose name is not a required check.

### Moving work out of the jobs a rollup reads fails the rollup OPEN

A rollup job with `needs: [...]` and `if: always()` derives one required verdict from several jobs.
The risk is `always()`: a job that RUNS and does nothing reports SUCCESS.
So when work moves out of the jobs the rollup reads, the verdict silently stops covering it.

Measured: when the build and type-check were hoisted out of the test shards, the rollup still read only the shard results, so a build failure would have published a GREEN required check.
A positive control on a copy — the new leg removed, the old rule applied — accepted **7 of 7** inputs the corrected rule refuses.
Whenever you move a step between jobs, re-derive the rollup's input set in the same change, and control it with a copy that forces the opposite answer.

### Affected-test selection is acceptable only with its residual risk measured

Running only the tests a change touches is the largest single lever available, and it is the one that trades correctness for speed if bought carelessly.
Measured by replaying sixteen days of real failures: a bare selector caught **39 of 50** real failures.
With rails, the misses fell to two flakes and two real ones, and the median wait went from 37 minutes to about 16.

The rails that produced that number:

1. an always-run allowlist of guard tests that must execute on every pull request;
2. forced-full runs on any change to a lockfile, CI config, or test configuration;
3. fail-closed behaviour — if the selector errors or returns nothing explicable, run everything;
4. a nightly full-suite run on the default branch as the backstop.

State the structural blind spot out loud rather than discovering it later: an import-graph selector cannot see a test that reaches its subject through a file read or a spawned child process, because there is no import edge to follow.

### A minutes lever bought with tests that pass for the wrong reason is refused

Measured, rather than assumed: disabling test isolation exposed **311 order-dependent tests**, one of which makes a real outbound HTTPS call to the live vendor API when unisolated, masked locally only because no credential was set.
Measure what a shared-state lever exposes before pricing it, and refuse it when the answer is "tests that now pass for a different reason".

### Raising a timeout buys time and fixes nothing, and the same sentence must say so

Measured: a job timeout went from 60 to 180 minutes because runtime was doubling every **15.5 days** (R² = 0.919).
The growth was broad suite growth — tests 3.9x, duration 6.5x, per-test cost only 1.66x — so there was no single file to repair and the raise was correct.
It bought scheduling room, not health.
Always report a timeout raise together with the growth rate that forced it, so the next person knows when it will be hit again.

## The interaction with the always-on directives

Do not restate these here; they already fire on every turn.
This skill supplies the billing model they do not contain.

- `[[wall-clock-ceilings-measure-the-machine]]` — a test asserting `elapsed < constant` measures the machine.
- `[[a-blind-poll-sleep-bills-the-fast-path]]` — a supervision loop's sleep is billed to every child that exits early.
- `[[check-the-cadence-not-only-the-action]]` — ask whether the RATE is right, not only the action.
- `[[a-subset-run-is-not-a-suite-run]]` — the missed-failure risk of running a subset.
- `[[replacing-a-list-with-a-glob-changes-the-set]]` — define "the tests" exactly once.
- `[[the-effective-timeout-is-the-min-of-two-budgets]]` — a test driving a child has two ceilings and the minimum fires.
- `[[preflight-the-cost-before-you-pay-for-it]]` — never buy speed with correctness, security or a required check.
