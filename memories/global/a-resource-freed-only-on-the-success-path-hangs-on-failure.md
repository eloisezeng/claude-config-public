---
name: a-resource-freed-only-on-the-success-path-hangs-on-failure
description: A browser, child process or server acquired inside a function and released only on its success path turns every failure into a hang; a wait that ignores EOF hangs for its whole deadline instead, and a proving run under a reachable deadline is passed by the timer.
scope: global
metadata:
  type: feedback
---

A long-lived handle — a Playwright browser, a spawned child, a listening server, a pool — acquired INSIDE a function and released at the end of its happy path does not merely leak: it converts every failure into a HANG.
The process cannot exit while the handle is alive, so the run never reports.
A trailing `run().catch(e => { console.error(e); process.exitCode = 1 })` looks like it handles errors and cannot reach a variable scoped inside `run`, so it sets an exit code the process never gets to use.

The defect lives entirely on the failure path, which is the path nobody exercises while things work — so it is invisible for as long as the suite is green, and it fires on the first real red, when you most need the report.
Ask who releases this on the way out, not whether the error is caught.

The same hang arrives by a SECOND door even once the release is bound to scope exit: the failure path runs down the DEADLINE instead.
A reader awaiting an answer must treat EOF as a failure and not only `error` and `close` — a peer that stops sending emits `end`, and emits `close` only once this side is torn down too, which while a read is awaiting an answer it is not.
Listening for `close` alone turns a server that goes away mid-answer into a wait for the whole timeout: a hang wearing a timeout's clothes, and a two-minute one where the deadline is generous.

**Why:** measured 2026-10-05 in your-university_scheduler. Driving one test against a deliberately broken copy of the app ran **past 10 minutes and had to be killed**; with the browser hoisted and closed in a `finally`, the same run **exited in 5 seconds with exit 1 and 6 failing assertions**, and a 13-mutant battery went from hours of ceilings to 60 seconds.
It was found by trying to run that battery, not by review: both node processes read 0.0% CPU, which is the whole diagnosis — idle, not slow.
All 34 `agents/*.mjs` files that launched a browser had the shape, and NOTHING bounded it: no per-check timeout in the runner, no `timeout-minutes` on the workflow step, so in CI it is a hang to the job limit rather than a red.

**How to apply:** bind the release to scope exit (`finally`, a context manager, `defer`), with exactly one release site — delete the success-path close rather than keeping both.
Then bound the outside too, so the next instance is a red that NAMES a file instead of a hang: a per-check timeout in the runner that prints which check it killed, and a step timeout in CI (`timeout` is absent on macOS — use a portable wait).
Enumerate the class mechanically (`grep -l` the acquire call across the tree, then check each for a release on the error path) and count both numbers; fixing one file and listing the rest as a lane is legitimate when the sweep cannot be verified in the current change, but say which.
Prove the fix with a deliberately failing run, timed — a green run reaches the success-path close and is blind to this.
Give that proving run a deadline it CANNOT reach (ten minutes where the test could never wait that long), because otherwise the timer passes the test for you: the run settles, the assertion goes green, and what it proved was that the timeout works rather than that anything is released or that any wait notices.
Measured 2026-10-06 in job_hunt: under an unreachable deadline the IMAP client's failing-read test timed out and named the missing `end` listener; under a short one it would have passed, and the sibling SMTP client had carried the same shape behind a 30-second deadline for weeks.
Related: [[a-tail-window-is-not-a-failure-report]], [[a-blind-poll-sleep-bills-the-fast-path]], [[the-effective-timeout-is-the-min-of-two-budgets]], [[absence-needs-a-probe-that-could-see-presence]].
