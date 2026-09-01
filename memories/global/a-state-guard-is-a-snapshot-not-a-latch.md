---
name: a-state-guard-is-a-snapshot-not-a-latch
description: A DO-NOT-REVIVE guard written into state.json is erased the moment the guarded seat wakes and rewrites its own record — guard counts decay silently, so every "N guarded" claim is a timestamped snapshot, never a latch
metadata:
  type: feedback
  scope: global
---

The fleet guard is written into `~/.claude/jobs/<sid>/state.json` — **the record the guarded seat itself owns and rewrites**.
A seat that wakes for any reason republishes that file from its own in-memory notion of its state, and the guard goes with it.

Measured 2026-08-25, minutes apart, in one sweep:
`2b9a9ca6` was guarded (verified from the file, `blocked`, 143,313 tokens).
Retiring the seat it supervised made its own stall-watchdog fire `TERMINAL`, which woke it.
On waking it rewrote `state.json` — guard **gone**, tokens up to 155,886, and `detail` reverted to a line from *before* the user ran `apply-do-not-revive-v2.py` ("69 targets, 0 currently guarded"), silently resurrecting a stale claim as though it were current.

This is the same shape as [[a-gate-may-not-read-its-verdict-from-the-gated-party]]: the flag lives in the artifact the gated party authors, so the gated party can clear it.

Rules:
- Treat every guard count as a **timestamped snapshot**. "295 guarded" means "at that instant"; it decays with no event and no error. Re-measure before relying on it, and never carry a count forward across a gap.
- **Retiring a supervised seat wakes its supervisor.** A watchdog that alerts on `TERMINAL` is an ignition source at retirement time, not only at stall time — expect the wake, sequence for it, and do not read the resulting turn as a defect.
- Never re-guard a seat the live predicate calls LIVE, even when you watched its guard disappear: a live seat rewrites the file again and the write is both futile and a race.
- The durable half is the **process** action (kill / disarm), which no wake can undo. The `detail` marker only advises a wave that bothers to read it. When something must not come back, do not rely on the marker alone.
- A wake also **reverts `detail` to stale text**, so a marker's absence is not evidence it was never written — check the `.bak-*` files the sweep left before concluding a seat was missed.
