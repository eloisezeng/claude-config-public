---
name: reproduce-cyclic-symptoms-inside-their-window
description: A symptom driven by a daily/periodic cycle is only observable in part of the cycle — check inside its window, or an out-of-window look reads as "no bug"
metadata:
  type: feedback
scope: global
---

When a reported symptom is produced by anything on a cycle — a nightly import, a midnight sweep, a rollover, a cron, a cache TTL — **the symptom exists for only part of that cycle.** Look outside the window and the system looks healthy, which is indistinguishable from fixed.

Measured instance (2026-08-07, your-data-product): the operator reported a screen request holding 246k names — two arrival days. The daily zone drop lands ~07:41 UTC and the expiry sweep clears the older cohort at 00:00 UTC, so the two-day shape existed roughly 07:41→24:00 UTC and the one-day shape 00:00→07:41. You looked at 19:53 UTC (inside). A later check at 03:23 UTC showed **one** day, $28.30 — the same unfixed code, simply observed out of window. Taken at face value that reads as "the bug isn't real."

So:

- **Derive the window before you measure.** Find what drives the cycle and when it fires, then state the hours the symptom should and should not appear. That derivation is the real diagnosis; the measurement only confirms it.
- **A single out-of-window observation refutes nothing.** Neither does a single in-window one confirm a fix — check both sides.
- **Timestamp every measurement and say which side of the window it fell on.** "Card holds 109,691 names" is unusable six hours later; "109,691 at 03:23 UTC, before the day's drop" survives.
- **Put the window in the handoff.** The next session will re-check the live state first, and a wrong-hour look is exactly how a real bug gets closed as unreproducible.

Related: [[verify-claims-against-artifacts]], [[pin-the-clock-in-clock-dependent-tests]] (the test-side counterpart — pin the clock so a fixture cannot drift out of its own window).
