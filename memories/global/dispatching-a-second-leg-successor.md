---
name: dispatching-a-second-leg-successor
description: handing work onward from the file you were dispatched FROM is refused, and a bg successor's listed name is truncated past typing — read it from `claude agents --json`
metadata:
  type: reference
scope: global
---

Two mechanics bite in the same minute when a dispatched session hands its remainder onward, and
both cost tool calls that a 300K-token window cannot spare.

**`handoff.sh` refuses a second dispatch from the same handoff file.** The file's dispatch record
already names a live successor — and that successor is YOU, because that record is how you were
launched. Measured 2026-10-12: `handoff: a live successor (9e51579c, working) is already on record
for .handoff-10-12-feedback.md — use --force to dispatch anyway`. Do not reach for `--force`,
which asserts the recorded successor is gone when it is the session typing the command. Write a
NEW leg file (`<name>-2.md`) that carries the objective and the hard limits and POINTS at the
original's state section by absolute path and section heading, rather than duplicating it — one
record per leg stays honest, and two copies of a state section drift. Options go AFTER the
positionals (`handoff.sh <file> <objective> [options]`), and the documented `--no-retire` flag is
not in the option parser: use the `CLAUDE_HANDOFF_RETIRE=0` env kill-switch, which you need
whenever you must stay alive after dispatch — to send the live no-merge override, or to collect
subagents still running.

**A background successor's name as `ListAgents` prints it cannot be typed.** The row's name is the
first ~140 characters of the session's initial prompt, cut mid-word, so every form fails:
the truncated string, the 8-hex job id, and a prefix plus the `[ref]` all returned
`No agent named '…' is reachable`. The real name is the `name` field of
`claude agents --json` — in the measured case a tidy `private-frontend-repo 10-12 feedback` that the
listing never showed. Read it from there before the first `SendMessage`, not after three failures.

Also measured: `respawnFlags` and `model` both came back `null` on a freshly dispatched row, so
that row cannot confirm the successor's tier — see [[continued-sessions-default-to-opus]] for what
the launcher's fallback gives.

Related: [[successor-inherits-a-contradicting-system-prompt]] is WHY you need to stay alive past
the dispatch; [[end-a-handoff-with-the-open-command]] is what to hand the user afterwards;
[[a-handoff-doc-must-not-assert-a-drop-it-has-not-made]] bounds what the leg file may claim.

**A dispatched successor can be REPLACED under you, and that silently voids every live message you
sent it.** Measured 2026-10-12: a session dispatched as `243adaec` was gone ~10 minutes later with
a different session working the same worktree under the handoff name, the watchdog armed at dispatch
being the likely re-dispatcher. The no-merge override, the coordination instruction and a finished
subagent's whole report had all gone to the dead id, and the replacement had booted with the same
merge-on-green preamble holding none of them. `SendMessage` is what reveals it, by refusing the
remembered name and offering a row with a NEW `[ref]`. So a live override belongs to the session on
the lane AT ACT TIME: re-read the lane's live session from `claude agents --json` before trusting
any message sent earlier, re-send the override to whoever is actually there, and correct the attach
id you already gave the user. Writing each finished subagent's report into the handoff FILE as well
as relaying it is what made this recoverable rather than a lost report.
