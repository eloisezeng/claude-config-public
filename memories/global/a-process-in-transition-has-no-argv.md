---
name: a-process-in-transition-has-no-argv
description: Between fork and exec, and while tearing down at exit, a process has NO readable argv — `ps -o command` prints the bare `comm` inside a PLATFORM-SPECIFIC delimiter pair, `(sleep)` on macOS and `[sleep]` on Linux, and `pgrep -f` cannot match it — so any predicate on command TEXT must accept BOTH forms or sample more than once
metadata:
  type: feedback
  scope: global
---

A process spends a few milliseconds per lifetime with no readable argv: between `fork` and `exec` (the image is not yet mapped) and during exit teardown (the image is gone, the process is not yet a zombie).
In that state `ps -eww -o command=` falls back to the bare `comm` name inside a delimiter pair, and **that pair is platform-specific: parentheses on macOS, `(sleep)`; square brackets on Linux, `[sleep]`** — which is also how Linux prints kernel threads, so the form is not exotic there.
A zombie prints `<defunct>` on both — a third form for a third state.
Measured 2026-09-02 on macOS, a `while :; do sleep 0.05; done` loop sampled 161 times: 83 rows read `sleep 0.05`, **77 read `(sleep)`**.
A two-second poll is in that form for well under 1% of its life, yet a process-tree guard taking four samples per drive across a large suite hit it and reported the launcher's own `sleep 2` as an unexplained arrival, because its filter was `/^sleep 2$/`.

**Why the platform column is the whole lesson.**
The 2026-09-02 fix was authored from that macOS measurement and widened the filter to `/^(sleep 2|\(sleep\))$/` — one instance of the class, named after the only render the author's machine could produce.
Every CI runner is Linux, so the twin `[sleep]` was left UNEXCUSED on a REQUIRED check for a week, until your-other-project run 34381376055 sampled it on 2026-09-09 17:11Z (`19353 [sleep]`) and it was widened again to `/^(sleep 2|\(sleep\)|\[sleep\])$/`.
Say "the hole was open for a week", not "it was red for a week": a 104-failed-run survey of the same repo (2026-08-19 → 2026-09-09 16:50Z) contains **zero** occurrences, so the measured rate is one red in the first sample taken after the hole was looked for — the exposure is what lasted a week, and the frequency is unmeasured.
The artifact that ACTS (`ps` on Linux) was not the one the author measured — `[[enumerate-the-transforms-between-authoring-and-use]]` — and the class was "an argv-less render", not "the macOS argv-less render" — `[[fix-the-class-not-the-reported-instance]]`.
The failure also reads as a real finding — one pid, one command, no stack trace — and a re-run is green, so it gets filed as "flaky" and never root-caused.
The same mechanism silently breaks the other direction: `pgrep -f <argv pattern>` matches on the full argv, so it returns NOTHING for a process caught in the transient, and a liveness probe built on it reads a live process as gone.

**How to apply:**
- Any predicate on `ps` command text (an allow-list, a deny-list, a `pgrep -f`) must accept **both** delimiter pairs explicitly, or be evaluated over more than one sample before it decides. Name both literally rather than switching on `process.platform` where the rule is meant to be pure — and put the platform in a test COLUMN, so a form excused on one OS and not the other is the shape the test fails on.
- Before excusing `(name)`/`[name]`, prove nothing else in the observed tree can wear that name (grep every spawner), and keep the excused form argument-less so it cannot launder an impostor with a real argument. Assert the negative set too: `[sleep 2]`, `(sleep 2)`, `[node]`, `sleep`, `<defunct>` and the mismatched pairs `(sleep]` / `[sleep)` must all still be findings.
- Control the mechanism with a tight loop of the short-lived process and tally the forms — the number is what turns "flaky" into a root cause. Run that tally on the platform the guard will RUN on, not only the one you are typing on.
- Related: [[a-control-must-match-the-probes-shape]], [[no-timeout-command-on-macos]] (the other macOS process-table trap: `pgrep -c` is absent and a missing flag yields an EMPTY stream).
