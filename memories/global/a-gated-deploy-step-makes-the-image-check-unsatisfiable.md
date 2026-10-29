---
name: a-gated-deploy-step-makes-the-image-check-unsatisfiable
description: a deploy pipeline that gates its STEPS yields a green, correctly-pinned run that shipped nothing — so "confirm the running image carries your merge SHA" can be unsatisfiable BY DESIGN; the tell is elapsed time, and the right answer is to report the non-event, never to force a deploy
metadata:
  type: feedback
scope: global
---

A deploy workflow commonly decides, inside the deploy job, whether this push can change anything,
and then puts that decision on **every** deploy step as `if: steps.scope.outputs.skip != 'true'`.
The job must be gated that way rather than skipped outright, because a job a filter skips publishes
no status at all and a required check that never reports leaves the pull request unmergeable for
ever.
The consequence is a run that is green, pinned to exactly your merge SHA, with every job `success`,
and which **deployed nothing**.

So a handoff instruction of the form "watch the deploy pinned by your merge SHA and confirm the
running image is `<app>:gh-<your merge sha>`" is not always a check you can pass.
For a documentation-only merge it is unsatisfiable the moment you merge, and no amount of watching,
re-running or re-reading will change that.
A successor that treats it as a required outcome will either force a deploy nobody asked for, re-run
a workflow to chase it, or write a verification sentence it did not earn.

**The tell is elapsed time, not any flag.** Nothing in `status`, `conclusion` or the job list says
"deployed nothing" — all three read exactly as a real deploy does.
What separates them is the clock: a run that builds an image and replaces a machine takes minutes,
and this one takes seconds.
Treat a sub-minute deploy run as a claim to disprove.

**Why:** measured 2026-10-28 landing PR #521 (documentation only, one prose file) on
your-other-project. Merge `b1dd4a6f`, deploy run `40738967525`: `deploy interlock` success,
`fly deploy` success, whole run **25 seconds** (17:46:59→17:47:24) and the deploy job itself **10
seconds**, against roughly four minutes for the code merge thirteen minutes earlier. The step
"Decide whether this push can change the running machine" ran `scripts/ci-docs-only.mjs` and printed
`docs-only change (1 path(s)) — skipping install, typecheck, build and the unit suite.` The freeze
precheck still ran and still logged CLEAR; `setup-flyctl`, `flyctl deploy`, the smoke check and both
alarm steps were all skipped. The box's image was byte-identical before and after the merge —
`your-app:gh-5dcb8f3f…`, machine `28692e4c929ed8`, version 576, `LAST UPDATED`
`17:36:45Z` on both reads — which is the positive proof that nothing was replaced rather than an
absence of evidence.

**How to apply:**
- Read the **step** conclusions, not the job's. Pull the run log and find the scope/decide step's own
  output; it names the decision and usually the paths it saw. A job's `success` is compatible with
  every interesting step having been skipped.
- When the artifact is absent by design, say so and verify **what does exist**: that the change is on
  the default branch, and that production is **unchanged**. Prove the second from an identity that
  would have moved — the image tag plus the machine's `LAST UPDATED`, read before and after — so
  "nothing happened" is a measurement and not a shrug.
- Do **not** force the deploy, re-run the workflow, or push an empty commit to trigger one. A
  docs-only change not restarting production is the pipeline working, and restarting the single
  machine to satisfy a sentence in a handoff is a real cost paid for a cosmetic one.
- Write the instruction better next time: pin the requirement to the **stage that owns** the
  artifact, and make the docs-only branch explicit ("confirm the image, OR confirm the scope step
  skipped the deploy and the box is unchanged"), so the successor has a reachable pass on both paths.
- A green deploy that deployed nothing also means the freeze gate was still consumed and still read
  CLEAR, so a CLEAR freeze is not evidence that a deploy occurred either.

Related: [[watch-the-run-you-triggered]] · [[a-deploys-artifact-is-not-a-lazily-triggered-effect]] ·
[[verify-claims-against-artifacts]] · [[a-guard-must-be-satisfiable-not-just-failable]] ·
