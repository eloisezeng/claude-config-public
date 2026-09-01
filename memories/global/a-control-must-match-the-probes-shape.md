---
name: a-control-must-match-the-probes-shape
description: A control that exercises a probe's components in isolation does not control the probe; reproduce the failing measurement's SHAPE, and never read an exit status off a compound command line
metadata:
  type: feedback
  scope: global
---

A `;`-joined command line exits with the status of its **last** component, and the background-task
harness reports that line's status. So the ubiquitous idiom

```sh
long_command > out.log 2>&1; echo "EXIT=$?"; tail -25 out.log
```

reports **`tail`'s** exit — always 0 — no matter what `long_command` did. Capture the status into a
variable the instant the command returns (`long_command > out.log 2>&1; ec=$?`) and assert on `$ec`,
or run the command bare and let the harness report it.

**Why:** measured 2026-09-01. A full vitest suite printed `Tests 5 failed` and the harness reported
exit 0, which reads as a catastrophic CI-integrity defect: `npm test` gates a required check, so a
red suite could certify green. I opened a lane on it. Vitest had exited **1** the whole time, and my
own output carried `EXIT=1` on line 1 — directly above the summary table I was quoting from. I
quoted the table and never read the line above it.

**The part worth keeping is why the controls missed it.** I ran two, both sound, both aimed at the
wrong thing:

- a deliberately failing single test file exited 1 → proved vitest's exit code works, which nothing
  disputed;
- a backgrounded `exit 3` was reported as exit 3 → proved the harness propagates a non-zero status
  **of a bare command**, which is precisely not the shape that failed.

Each control tested a *component* of the probe. Neither reproduced the probe's **shape** — a
compound line ending in a formatting command — which is where the status was lost. A control that
cannot fail the way the real measurement failed is not a control for it; it is a second, unrelated
measurement that happens to be green.

So: before trusting a control, state the exact shape of the thing that failed and check the control
has that shape. And when a striking result rests on one probe you wrote yourself, re-read the probe's
own full output before writing it up — the refutation is often already in it.

Related: [[surprising-result-check-metric-identity]] (a surprising number is a defect signal first),
[[absence-needs-a-probe-that-could-see-presence]], [[verify-claims-against-artifacts]],
[[control-a-settle-detector-on-captured-output]], [[re-read-cannot-tell-wrong-from-acted-on]].
