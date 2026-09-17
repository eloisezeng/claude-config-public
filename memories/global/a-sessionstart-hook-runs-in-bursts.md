---
name: a-sessionstart-hook-runs-in-bursts
description: A fleet dispatch starts several sessions at once, so a SessionStart hook writing shared state runs as a BURST — without a lock the symptom is not breakage but a FALSE failure report from the losers, which is worse, because it accuses a store that in fact moved
metadata:
  type: reference
  scope: global
---

A SessionStart hook is easy to picture as one process at a time. It is not: a fleet dispatch, a watchdog revival wave, or simply opening several seats starts a handful of sessions within the same second, and every one of them runs the hook against the same shared state.

The interesting part is the SYMPTOM. If the shared state is a git store, the winner fetches and merges normally and the losers collide on the same refs; each loser then reports what its own command said — `cannot lock ref`, a held `index.lock` — as a failure of the store. **The store moved. The report says it did not.** That is worse than breakage, because a loud correct failure gets investigated once, whereas a false failure gets read as a broken store and either sends a session hunting a problem that does not exist or trains every later session to ignore the report — the fail-open direction in `[[a-load-flake-names-the-regime-it-was-measured-in]]`.

**So any SessionStart hook that WRITES shared state takes a lock.** The shape that works, shipped in this config's memory-store refresher:

- a per-store lock file taken with an exclusive create, so the loser never blocks and simply returns the last report;
- a staleness bound on the lock (two minutes) so a killed run cannot wedge every later session;
- a throttle stamp checked again INSIDE the lock, so the whole burst does one fetch rather than one per waiter;
- **fail open, always.** The hook exits 0 whatever happens, because a store refresh may never block a session from starting.

**Pin it with a burst test, not a single-run test.** The shipped guard runs three trials of four simultaneous sessions and asserts three things per trial: the store MOVED, no output contains a failure line, and the lock was released. The dispatching session's own diagnosis measured the pre-lock rate at 3 of 6 trials with 3 simultaneous sessions (lane `2026-09-17-codify-session-learnings-into-claude-config`). Asserting only "the store moved" would pass on a run where every loser screamed; asserting only "no failure line" would pass on a hook that did nothing at all.

Related: `[[a-standdown-must-disarm-the-shell-watchers]]`, `[[measure-what-reaches-context-not-disk]]`, `[[stage-immediately-verify-commits-from-the-object]]`, `[[absence-needs-a-probe-that-could-see-presence]]`.
