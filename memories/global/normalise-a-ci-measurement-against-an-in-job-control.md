---
name: normalise-a-ci-measurement-against-an-in-job-control
description: A CI runner's speed varies more than most changes you measure on it — read every duration against an untouched control that ran in the SAME job, or you will report the machine
scope: global
metadata:
  type: feedback
---

A hosted CI runner is not a fixed instrument. Measured 2026-09-09 across seven `ubuntu-latest`
`test + typecheck` jobs in one repo, the SAME untouched work — `npx tsc --noEmit` plus `npm run
build` — cost 107 s on one job and 150–172 s on the other six: a **~1.5x spread on work the change
under test could not touch.** The effect being measured was a 14% cut. The variance was larger than
the signal.

That is how a genuinely striking sample gets reported as a result. One parallel sample came back
36% faster than the serial control and read as the change over-delivering; normalised against its
own job's tsc+build it was 12.72 control-units against the serial control's 15.86 — dead centre of
the band every other sample sat in. Its runner was cheap at everything.

**Why:** a same-job control shares the VM, the disk, the network and the noisy neighbour. Nothing
else does. A "control run" dispatched separately is a second measurement on a second machine, which
is exactly the thing you are trying to divide out — `[[a-control-must-match-the-probes-shape]]`.

**A CI leg has TWO durations, and the cap applies to only one of them.** The JOB duration is what
`timeout-minutes` kills on; the STEP duration is what the change under test actually moved. They
differ by the whole prologue — checkout, toolchain setup, dependency install, build, typecheck —
which is minutes, not noise. Measured 2026-10-09 on one `windows-latest` acceptance leg: job 37m05s
against step 32m26s, a 4m33s prologue, and the pre-change samples were 39m22s / 33m39s and 39m15s /
34m17s. A figure carried forward in a handoff or a report named neither unit, so the next session
compared a fresh JOB duration against a recorded STEP duration and concluded the change had made
things SLOWER when the step was 1 to 2 minutes faster and the job had gained 2m17s of headroom. Read
both from the jobs API, label every duration with its unit in the same sentence, and quote the JOB
number whenever the question is the cap — `[[surprising-result-check-metric-identity]]`,
`[[a-setting-is-not-a-rate]]`.

**How to apply:**
- Pick a step in the SAME job that the change cannot affect (a typecheck, a build, a dependency
  install) and report `subject / control` alongside the raw seconds. Say which steps you summed.
- Never quote a single-sample delta. Compare MEDIANS, and say the N on both sides — a historical
  baseline over 57 jobs is free and beats any number of paid control runs.
- State the raw number too, because the raw one is what gets BILLED. Normalisation explains the
  spread; it does not pay the invoice.
- Sibling instance in test code: `[[wall-clock-ceilings-measure-the-machine]]` — an
  `elapsed < <constant>` assertion is the same error with no control at all.
