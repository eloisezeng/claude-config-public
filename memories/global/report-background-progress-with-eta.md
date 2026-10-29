---
name: report-background-progress-with-eta
description: Never report a background job as just "still running" — emit a progress bar with a counter, elapsed time, ETA, and an explicit stalled/working signal
metadata:
  type: feedback
scope: global
---

When work runs in the background, "1 shell is still running" is not a status report.
The user cannot tell a job that is progressing from one that is wedged, so she waits on both.

Report background work as: `[####......] 40%  12/30  elapsed 5m10s  ~7m40s left  — <label> | working`.
Derive the ETA from the observed rate (elapsed/done x remaining), not from a guess made before starting.
Say **working** or **NO PROCESS** explicitly, and call a flat counter with no live process **STALLED** rather than letting it look busy.

**Why:** silence and "running" are indistinguishable from a hang, which is the one state that needs her to act.
A rate-derived ETA is honest — it self-corrects as the job runs — where an up-front guess is not.

**How to apply:**
- Design every long background command around a *countable artifact* (one log file per run, one marker per item), so progress is observable from outside the process. A job whose only output arrives at the end cannot be reported on.
- Arm `Monitor` with `~/.claude/bin/progwatch "<label>" <total> <interval> "<count-cmd>" "<pgrep-pattern>"` at dispatch time so the bar streams into the conversation. `~/.claude/bin/prog` renders a single line on demand.
- State the total and the expected duration in the SAME message that announces the dispatch.
- A background SUBAGENT (Agent tool) is background work too, and the worse case: it shows NO running shell, so "it's running" is unverifiable to her. Arm the bar on its countable artifact at dispatch — commits since the start SHA (`git rev-list --count <start>..HEAD` out of N plan tasks), files written, or verdicts landed — with the dispatch time as the start epoch. No pgrep pattern exists for a subagent, so the bar's `working` word cannot speak for it; prove liveness by the newest artifact's mtime when asked. (2026-10-09: two "State: RUNNING" reports on an implementer subagent with no bar; she asked why no shell showed.)
- Two macOS traps that silently zero a counter: `/tmp` is a symlink, so `find /tmp -maxdepth 1` never descends — use `/private/tmp`; and zsh aborts a whole command when a glob matches nothing, so count with `find`, not `ls *.log`.
- Pairs with [[worker-liveness-must-reflect-progress]] (a health signal must track real forward progress) and [[handoff-at-boundaries-saves-tokens]].

**Platform note (2026-08-20):** `~/.claude/bin/progwatch` does not exist on the your-university cluster (login nodes hpc-92-*); there the loop is written inline in the `Monitor` command (count / elapsed / rate-ETA / STALLED from log-mtime / terminal outcome), e.g. the C2 stage2500 watcher.
