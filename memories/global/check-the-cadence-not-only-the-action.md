---
name: check-the-cadence-not-only-the-action
description: A self-check aimed at "is this action correct?" is structurally blind to a wrong RATE — every instance passes while the aggregate is the defect; audit the loop's cadence, answer with a count, and fix the schedule not the instance
metadata:
  type: feedback
scope: global
---

The user, 2026-09-06, on a session that had been re-running a full suite per commit across a
twenty-five-task arc: the diagnosis she asked me to keep is *"my self-check was aimed one level too
low — 'is this action correct?' at each step, never 'is this cadence correct?'"*

**Why a per-action check cannot see this.**
A step-level self-check only ever evaluates ONE instance, and every instance passes.
The rate, width, or repetition of those defensible actions is the actual defect: a suite re-run per
commit when the arc needed one at the tip, a 150-line progress note per task across fifteen tasks,
a poll every 60 s on state that moves hourly, a fan-out three times wider than the question.
Correctness lives at the step; cost, latency and noise live at the cadence.
The aggregate is a DIFFERENT OBJECT from the step, and only the aggregate carries the bill —
checking one and calling it verification is measuring the wrong level, the same shape as quoting a
total as a per-item figure ([[surprising-result-check-metric-identity]]).

**The sharpest form: a periodic job whose SUBJECT has not moved.**
Where a scheduled run verifies an artifact, gate it on the ARTIFACT having changed, never on the clock alone — and put both facts in the key of whatever records "already done", so a new subject and a new period each miss for their own legible reason.
Measured 2026-10-26 on `your-other-project`: the nightly full suite was 1,081 of the repository's 1,177 Actions minutes over thirty days, 92% of the whole bill, and every one of the 20 nights sampled ran against the SAME commit because nothing had merged in 39 days.
Its own purpose made this decidable rather than a matter of taste — the run existed to catch failures a per-change test selection had skipped, which is a property of code ARRIVING, so on an unchanged tree it was buying a second measurement of a result already in hand.

Three things that case settles for the next one.
Name what the period still buys, because it is rarely nothing: a suite can change verdict on an unchanged subject when the failure is a function of TIME (an expired certificate, a date-bomb test, a vendor response that changed shape), so keep a FLOOR and report the resolution you traded (one day to seven), rather than presenting the saving as free.
Measure the floor instead of assuming the skip is free — step timings gave checkout 7 s, setup 3 s, install 15 s, suite 2,399 s, so the suite was 99% of the run and a skipped night bills the 1-minute minimum, which is what makes 1,081 minutes become ~190.
And fail OPEN toward running, sweeping every value that is not the single skip-permitting one: a wrongly-skipped run reports SUCCESS having verified nothing and is indistinguishable in a run list from one that passed, while a wrongly-run one costs its minutes visibly — the cheap failure is the loud one.

**Do this instead.**
At every loop or task boundary, ask the SECOND question out loud before continuing — *is this
cadence correct?* — and answer it with a COUNT, never an impression: how many times will this run
over the remaining work, and what does that multiply out to.
Ask it at the FIRST boundary, not the tenth.
Everything needed to answer — how many iterations remain, what each costs — is available at
iteration one, and the savings are only collectable forward; this is the same one-increment-late
construction that put a preflight gate in front of round 1
([[preflight-the-cost-before-you-pay-for-it]]).

**Fix a wrong cadence by changing the SCHEDULE.**
Batch it, background it, cap it, or drop the step.
Never make each instance slightly cheaper — that preserves the defect at a discount and leaves the
multiplier intact.
And a cadence cut may not change what is VERIFIED: where a project rule fixes the rate (this repo's
"`npm test` and `npx tsc --noEmit` must be green before you commit"), the cadence is not yours to
lower — say so and find the cost elsewhere ([[optimize-the-loop-unprompted]]).

Related: [[optimize-the-loop-unprompted]] · [[preflight-the-cost-before-you-pay-for-it]] ·
[[reduce-token-burn]] · [[surprising-result-check-metric-identity]] ·
[[enumerate-the-transforms-between-authoring-and-use]]
