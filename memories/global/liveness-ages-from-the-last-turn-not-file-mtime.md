---
name: liveness-ages-from-the-last-turn-not-file-mtime
description: A session-liveness probe must age from the last ASSISTANT TURN in the transcript, never the transcript file's mtime — foreign writes refresh mtime and a dead seat then reads LIVE forever
metadata:
  type: feedback
scope: global
---

Age every seat from the timestamp of the **last `type:"assistant"` record** in its transcript (fall back to the last record of any type, and only then to mtime).
Never from `os.path.getmtime()` on the `.jsonl`.

**Why:** a transcript file is written by things that are not the session working — an inbound task-notification, a cross-session message, a tool result, even another agent killing an unrelated orphan process.
Measured 2026-08-22 across one seven-seat fleet: `a59ef4a6` read 5.1m idle by mtime and **54.7m** by its last turn; `842085ef` read 50.3m by mtime and **763.8m** — a seat dead for twelve hours presenting as fresh.
So a hung or dead session that anything writes to reads LIVE forever, and the watchdog goes quiet exactly when it is needed.
This is the same class as "transcript BYTES aren't progress" one level lower: bytes at least require an append, mtime does not.

**How to apply:**
- In any liveness/stall probe, parse for the last assistant turn. `mtime` is a last-resort tiebreak, and say so in the code.
- **Force the clock in the control, don't read live state.** A control that asserts against whatever a real seat happens to be doing passes or fails by accident — the mtime bug survived a seven-control suite because the one seat that could have exposed it happened to have a stale mtime at that instant. Build a fixture where mtime and last-turn DIVERGE by a known amount and assert the probe picks the turn.
- A control whose expected value depends on live fleet state decays into noise; a clock-forced one does not.

Related: [[worker-liveness-must-reflect-progress]], [[absence-needs-a-probe-that-could-see-presence]], [[verify-claims-against-artifacts]], [[a-revival-wave-must-read-detail-before-nudging]]

**A cap-killed seat is not durably dead.** `state=blocked` + a session-limit `detail` + **zero** processes was measured TRUE and was still insufficient: the seat resumed 4h17m later with its full context, six minutes after a revival had been dispatched from its handoff file, double-seating the lane.
So a revival is not a substitute for a settle — dispatch it if you must, then expect a contest and resolve it two-sidedly (the two seats settle it; supervision watches, never adjudicates), and prefer the landing that is already published in the record over the one that needs two documents rewritten.
Same-shaped error one layer down: "not mid-turn" is not "cannot be woken" — an orphan-looking hold whose reader is 4h silent may have its reader back seconds later. Discriminate a cap-kill by a `<synthetic>` model on the final assistant turn, not by `state.json`.
