---
name: a-control-must-match-the-probes-shape
description: A control that exercises a probe's components in isolation does not control the probe; reproduce the failing measurement's SHAPE, and never read an exit status off a compound command line
metadata:
  type: feedback
  scope: global
---

A compound command line exits with the status of its **last** component, and the background-task
harness reports that line's status. Two shapes, one defect:

```sh
long_command > out.log 2>&1; echo "EXIT=$?"; tail -25 out.log   # reports tail's exit
v=$(long_command | tail -1); ec=$?                              # reports tail's exit
```

Both report **`tail`'s** status — always 0 — no matter what `long_command` did. The `;` form is the
one people quote; the **pipe** form is the one that actually ships, because piping a verbose command
into `tail` to keep a log readable is the same reflex that makes the bug invisible. Capture the
status into a variable the instant the command returns, with nothing between
(`out=$(long_command 2>&1); ec=$?`), and trim for display **afterwards** — never inside the
substitution whose status you are about to read. Or run the command bare and let the harness report
it. In zsh a pipeline's real statuses are in `$pipestatus` (`${PIPESTATUS[@]}` is the bash spelling),
but reaching for that is a sign the pipe belongs on a later line.

The instrument this defends is a **polling predicate**, which is where it costs the most: a poll
loop that misreads its predicate's status does not merely mis-report once, it exits early and
certifies the thing it was watching. Measured 2026-09-08: a CI poll written `v=$(ci-green.sh | tail
-1); ec=$?` exited on poll 1 with `CI_GREEN_EXIT=0` while the verdict text it had just captured, and
written to its own log, read `NOT-GREEN ... still running` with ten jobs unfinished. The control is
cheap and must reproduce the SHAPE: run the same predicate against the same live state through the
corrected capture and require the opposite answer — 1 where the broken form read 0.

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

**A second shape, measured the same day, worth naming separately: a tool that resolves what it
inspects from a FIXED path cannot be controlled by copying the tool.** `fleet doctor` reports whether
each of its dependencies is installed, reading them from `BIN="$HOME/.claude/bin"` — a hardcoded
absolute path, not its own location. My control copied `bin/` into a sandbox, deleted one dependency
from the copy, and ran the copy: doctor read the *real* install, found the file present, and printed
`ok`. The control looked exactly right — break it, run it, expect MISSING — and could not possibly
have failed, because the thing it broke was not the thing under inspection. The fix was to build a
whole fake install under a sandbox `$HOME` and run with `HOME=` pointed at it. **Ask what the tool
DEREFERENCES, not what you executed** — and note this control was only diagnosable because it FAILED
loudly; the same mistake in a passing direction is a green test of nothing.

So: before trusting a control, state the exact shape of the thing that failed and check the control
has that shape. And when a striking result rests on one probe you wrote yourself, re-read the probe's
own full output before writing it up — the refutation is often already in it.

Related: [[surprising-result-check-metric-identity]] (a surprising number is a defect signal first),
[[absence-needs-a-probe-that-could-see-presence]], [[verify-claims-against-artifacts]],
[[control-a-settle-detector-on-captured-output]], [[re-read-cannot-tell-wrong-from-acted-on]].
