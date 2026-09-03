---
name: a-tail-window-is-not-a-failure-report
description: "a fixed tail of a failing job's output is fail-open reporting — multi-line teardown noise evicts the assertion; and a redirected log shows only stderr until exit"
metadata:
  type: feedback
  scope: global
---

A runner that reports a failure as `tail -N` of the captured output is **fail-open
reporting**: the window is sized for the tidy case, and any process that prints
multi-line noise on the way out evicts the one line that names the cause.

Measured 2026-09-02 in `tests/run-all.sh`. `tests/handoff.test.sh` tears down ~20 seat
processes, and every shell job-control notice (`Terminated: 15`) reprints the seat's
whole inline script — about **12 lines apiece**. So `tail -20` was four teardown notices
and zero assertions: the runner said `FAIL ... (exit 1)` and showed nothing to act on.
Re-run by hand the suite passed (`EXIT=0`), which is the worst outcome — an unreproducible
red with no artifact, indistinguishable from flakiness. The fix is one line of the
REPORTER, not another test run: grep the captured output for the assertion markers, print
those FIRST, keep the tail after for context, and when there is **no** marker say so
explicitly with the exit code, so "the suite failed on its own" is a stated fact rather
than an empty box. Control it both directions on a fixture whose marker sits 300 lines
above the tail window: the old reporter shows only noise, the new one shows the marker.

**And a redirected log is empty until the process exits.** stdout block-buffers when it is
not a tty, stderr does not — so a live `cmd > log 2>&1` shows only stderr, and reading it
mid-run yields exactly the teardown noise and none of the results. A 0-byte log after 13
minutes is not a hang. Do not diagnose from a running redirect; wait for exit, or force
line buffering (`stdbuf -oL`, `script`, `PYTHONUNBUFFERED`).

**Why:** both failures in this session were invisible for the same reason — the channel
that should have carried the cause was structurally incapable of carrying it. Chasing the
subject before fixing the channel spends runs to learn nothing.

**How to apply:** when a failure report gives you nothing to act on, fix the REPORTER
before re-running the subject. Related: [[a-control-must-match-the-probes-shape]],
[[verify-claims-against-artifacts]], [[unambiguous-status-and-logs]].
