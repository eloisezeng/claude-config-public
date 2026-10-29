---
name: a-wait-inherits-the-budget-of-the-api-it-is-spelled-with
description: A wait that belongs to one operation but is spelled with another API's call silently inherits that API's timeout, bypassing the project's measured ceilings; and correcting it converts fast failures into slow passes that bill the enclosing job's own ceiling
metadata:
  type: feedback
  scope: global
---

A test harness's wait takes its budget from the API it is SPELLED WITH, never from the operation it
belongs to. A helper that is the second half of a navigation -- waiting for a hydration marker, a
readiness attribute, an app-ready flag -- but written as `locator.waitFor()` with no explicit
timeout gets `use.actionTimeout`, not `use.navigationTimeout`. The project's carefully measured
ceilings file is then simply not consulted on that path, and nothing says so: the ceilings are
right, the wait does not read them. Measured 2026-10-13: a repo with a `ceilings.ts` deriving
`navigation: 10_000` plus a 45,000 ms host-stall allowance for `windows-latest` CI had every
defaulted navigation running its hydration wait at the 5,000 ms action timeout instead, for as long
as the harness had existed. Grep each wait for an explicit `timeout:` and name the ceiling the
operation deserves; a wait with no timeout argument is a wait whose budget you have not chosen.

It surfaces on the ONE test with no fallback path rather than on the slowest, which is why it hides
for so long. Here it was the only spec loading the heaviest document under a paused `page.clock`:
with no timers, React's scheduler had no timer-driven path, so whether hydration finished was a
race against the host. Every other spec either loaded a light page or left the clock running. When
a budget defect fires on exactly one test, ask what that test does that no other does, rather than
treating it as the flakiest.

**The second-order cost is the part that bites a job's own ceiling.** Raising a too-tight wait is
correct and it converts fast FAILURES into slow PASSES, which is the trade the measurements intend
-- and that time is billed to the enclosing job. The same arc's `timeout-minutes: 45` then killed
the run at 45m28s with the suite at test 360 of 388, where previous runs took 21 and 27 minutes.
Measure the per-test durations out of the killed job's own log before blaming the change: here the
nine tests over 20 seconds (the slowest 59) were all in files the pull request never touched, and
the real driver was `workers: 1` on CI against four locally -- 1.5 minutes of wall-clock becoming
45. A job killed by its own ceiling REPORTS NOTHING, so an advisory `continue-on-error` leg that
times out defeats its own purpose; give it room to report rather than letting it die mute.

**Why:** a timeout that is inherited rather than chosen reads as correct in review, because the
call site has no number in it to question, and the measured constants file sitting next to it makes
the whole area look deliberate.

**How to apply:** for every wait in a harness, ask which operation it belongs to and pass that
operation's ceiling explicitly; pin it with a cross-host test asserting the ceiling equals the
operation's and exceeds the one it used to inherit. After correcting any wait budget, re-measure the
enclosing job's wall-clock against its `timeout-minutes` -- `[[a-ci-only-slowness-needs-the-codes-contribution-bounded-first]]`,
`[[changing-the-worker-count-moves-every-wall-clock-ceiling]]`, `[[wall-clock-ceilings-measure-the-machine]]`.
