---
name: a-subset-run-is-not-a-suite-run
description: Re-running only the specs a fix touched leaves every OTHER guard unexercised against the finished artifact; the last full run can predate the whole arc
metadata:
  type: feedback
scope: global
---

A fix round verified by re-running only the specs it touched proves nothing about the guards it
did not run. Those guards last saw the artifact at whatever commit the last FULL run covered —
which, across a long convergence arc, can be the first hour's code. The gap is invisible from
inside the loop: every round reads green, because every round is asking a narrower question than
the one before it.

**Why:** measured on the your-web-app card-reveal arc. The last full Playwright run was at 17:42, an
early commit; the following four hours were subset runs of `ballot-geometry` only. The finished
screen violated the app's OWN spacing rule — sibling `<section>`s 24px apart against a 32px floor —
and `geometry.spec.ts` caught it deterministically at all four viewports the first time the whole
suite ran again, five commits later. `e2e/spacing.ts` was byte-identical between the branch point
and `origin/main`, so the rule was not new and no merge introduced it: nothing had simply looked.
The same run also exposed a test that passed alone and failed under parallel load — a class a
subset run structurally cannot see, because the load is the trigger.

**How to apply:** run the FULL suite at the LAST commit of an arc, never only at the first, and
treat the last full-suite SHA as a tracked fact — if it is not HEAD, the arc is not verified.
Budget one full run per fix round's close, not per arc. When main has moved, run it on the MERGED
tree, since neither side was tested against the other. A subset run is a debugging tool; it is
never the evidence a change is green. See [[verify-claims-against-artifacts]] and
[[close-the-reviewed-head-gate-by-measuring-identity]].
