---
name: a-ci-only-slowness-needs-the-codes-contribution-bounded-first
description: Bound the code's contribution with a local CPU-throttle sweep before attributing a CI-only timeout to it; a hosted runner can deschedule the browser process entirely, and zero long tasks with nothing outstanding is that signature
metadata:
  type: feedback
  scope: global
---

Before attributing a CI-only timeout or slowness to the code, bound what the code could possibly
contribute, locally, with a measurement: drive the same page under CDP
`Emulation.setCPUThrottlingRate` across a ladder (1x, 2x, 4x, 8x, 16x) and extrapolate. If reaching
the observed figure needs an implausible penalty, the code is exonerated and the remaining work is
about the machine. Then read the renderer's OWN account of the slow interval —
`PerformanceNavigationTiming` split into `responseEnd` / `domContentLoadedEventEnd` / `loadEventEnd`,
a `PerformanceObserver` on `longtask`, and the outstanding `PerformanceResourceTiming` entries. **Zero
long tasks, nothing outstanding, and a slow wall-clock together mean the process was not executing**:
the host descheduled it, which no amount of application work explains.

A hosted runner's tail is far wider than its typical variance
(`[[normalise-a-ci-measurement-against-an-in-job-control]]` gives ~1.5x on untouched work). Measured
2026-10-08 on GitHub's `windows-latest`, six navigations to one unchanged URL inside one job:
`loadEventEnd` 132, 143, 996, 1160, 8874 and 40420 ms — **a 308x spread** crossing a 30 s cap once —
while `responseEnd` never exceeded 89 ms and `domContentLoadedEventEnd` stayed 76–960 ms. Locally the
same page reached `load` in 814 ms at a 16x CPU penalty, so roughly 600x would have been needed. The
remedy follows from WHICH quantity is noisy, not from the symptom: a test may wait on what the
product controls (a status, a rendered assertion, `domcontentloaded`), never on an event whose
arrival time the host decides. Prefer the auto-retrying assertion that proves the page actually
worked, which is a stronger claim than `load` firing ever made.

Two corollaries about silencing such a failure, from the same arc. First, **scope the silence to the
leg that fails**: `test.skip(!!process.env.CI, …)` added for a Windows-only timeout deleted the test
from the Linux leg too, where it passed in 2.0 s and where the required checks live. Second, **check
first whether that leg can fail the run at all** — `continue-on-error` was already set for Windows,
so the skip prevented nothing and cost the only coverage there was. Measure the per-platform
behaviour before writing a condition that spans platforms —
`[[fix-the-class-not-the-reported-instance]]`, `[[wall-clock-ceilings-measure-the-machine]]`.

**Why:** a CI-only symptom reads as a defect in the change in front of you, and the cheapest
hypothesis is the code; without a bound on the code's contribution there is nothing to refute it, so
the hunt runs for hours in the wrong file and ends in a skip or a raised timeout.

**How to apply:** throttle locally and extrapolate; read long tasks and outstanding resources for the
slow interval; wait on product-controlled quantities only; and scope any skip to the leg that fails,
after checking that leg is not already advisory.
