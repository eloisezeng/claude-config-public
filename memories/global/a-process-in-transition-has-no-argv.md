---
name: a-process-in-transition-has-no-argv
description: Between fork and exec, and while tearing down at exit, a process has NO readable argv — macOS `ps -o command` prints `(comm)` and `pgrep -f` cannot match it — so any predicate on command TEXT must accept that form or sample more than once
metadata:
  type: feedback
  scope: global
---

A process spends a few milliseconds per lifetime with no readable argv: between `fork` and `exec` (the image is not yet mapped) and during exit teardown (the image is gone, the process is not yet a zombie).
In that state macOS `ps -eww -o command=` prints the bare command name in parentheses, `(sleep)`, and a zombie prints `<defunct>` — two different forms for two different states.
Measured 2026-09-02 on a `while :; do sleep 0.05; done` loop sampled 161 times: 83 rows read `sleep 0.05`, **77 read `(sleep)`**.
A two-second poll is in that form for well under 1% of its life, yet a process-tree guard taking four samples per drive across a large suite hit it and reported the launcher's own `sleep 2` as an unexplained arrival, because its filter was `/^sleep 2$/` (fixed as `/^(sleep 2|\(sleep\))$/`, your-other-project PR #344).

**Why:** the failure reads as a real finding — one pid, one command, no stack trace — and a re-run is green, so it gets filed as "flaky" and never root-caused.
The same mechanism silently breaks the other direction: `pgrep -f <argv pattern>` matches on the full argv, so it returns NOTHING for a process caught in the transient, and a liveness probe built on it reads a live process as gone.

**How to apply:**
- Any predicate on `ps` command text (an allow-list, a deny-list, a `pgrep -f`) must either accept the `(comm)` form explicitly or be evaluated over more than one sample before it decides.
- Before excusing `(name)`, prove nothing else in the observed tree can wear that name (grep every spawner), and keep the excused form argument-less so it cannot launder an impostor with a real argument.
- Control the mechanism with a tight loop of the short-lived process and tally the forms — the number is what turns "flaky" into a root cause.
- Related: [[a-control-must-match-the-probes-shape]], [[no-timeout-command-on-macos]] (the other macOS process-table trap: `pgrep -c` is absent and a missing flag yields an EMPTY stream).
