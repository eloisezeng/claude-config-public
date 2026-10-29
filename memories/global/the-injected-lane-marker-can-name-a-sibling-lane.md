---
name: the-injected-lane-marker-can-name-a-sibling-lane
description: A dispatched seat's `CLAUDE_HANDOFF_LANE` and its injected "Your lane:" line can name a SIBLING seat's lane when two handoffs launch seconds apart — settle lane ownership from the dispatch record whose `session_uuid` is YOUR OWN, because acting on the injected marker closes somebody else's lane
metadata:
  type: feedback
  scope: global
---

A dispatched seat is told its lane twice: `CLAUDE_HANDOFF_LANE` in the environment and a one-line "Your lane:" in the SessionStart ops injection, which is derived from it.
Both can be wrong.
Measured 2026-10-26: a seat booted with a `CLAUDE_HANDOFF_LANE` naming a lane that had been dispatched 12 seconds earlier for a different objective, and the injection printed that sibling's objective as its own.
The dispatch records settled it in one read: each `handoffs/<name>.md.dispatch` carries `lane=`, `session_id=` and `session_uuid=`, and the record naming MY `session_uuid` named the correct lane.

**The authority is the dispatch record keyed by your own session UUID, never the injected marker.** Your UUID is in your transcript path (`<config-root>/projects/<project>/<uuid>/`); grep the `.dispatch` records for it.
Check it before the first write to a lane and again before `--close`.

**Why this is not cosmetic.** `handoff.sh --close <lane> completed` takes the lane key on the command line and does not verify that the caller owns it, so a seat that trusts the marker closes a live sibling's lane as completed — the sibling keeps working with no open lane, which is exactly the silent drop the ledger exists to prevent (`~/.claude/ops/README.md`: a lane leaves the open set only by explicit disposition).
The failure is loudest when several handoffs are dispatched in one burst, which is the normal shape of a fan-out, and it is invisible from inside the seat: nothing about the wrong lane looks wrong.

Related: `[[address-a-seat-by-job-id-not-by-name]]` (a seat is addressed by job id, not by a name that can move) and `[[ops-lane-ledger]]`.
