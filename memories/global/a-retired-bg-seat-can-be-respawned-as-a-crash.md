---
name: a-retired-bg-seat-can-be-respawned-as-a-crash
description: A handoff.sh retirement stops the predecessor's process, but the bg daemon can read that exit as a crash and auto-restart the seat, flipping its state.json from done back to working — a retired seat can come back, and a seat that wakes after its own handoff must stand down, not resume
metadata:
  type: feedback
  scope: global
---

Observed 2026-08-27 16:09 EDT (job `60980d53`, repo cc-handoff-lifecycle): the seat dispatched its successor with `handoff.sh --force`, the dispatcher reported `retired: pending (state=done, sentinel written; stopping pid 19735)`, the process exited — and the harness restarted the same job ("automatically restarted after its process exited unexpectedly"), with `state.json` back at `state=working` and only the `<sid>.handed-off` sentinel and `firstTerminalAt` surviving.

**Why:** to the daemon's respawn logic a retirement kill is indistinguishable from a crash, so the durable half of a retirement (the process kill) is undone and the marker half decays — see [[a-state-guard-is-a-snapshot-not-a-latch]]. A restarted seat that resumes its old objective duplicates the successor's work on a shared `.git` and reopens a contested seat — see [[a-handoff-doc-must-not-assert-a-drop-it-has-not-made]].

**How to apply:** if you wake after you handed off (your own `.handed-off` sentinel exists, or the handoff file says you dispatched), do NOT continue: verify the successor from the record (`session_id` byte-exact via `od -c`, its `state.json` live and its tier from ITS `respawnFlags`), touch no tree and message no seat, re-mark your own `state.json` done, write one line into the handoff file naming the successor's job id and telling it to ignore you, and end. When dispatching, expect the predecessor to possibly reappear and pre-empt it in the successor's brief ("ignore job <id>"). The real fix belongs in the daemon: an exit whose job carries a `.handed-off` sentinel / `firstTerminalAt` is a retirement, never a crash to respawn.
