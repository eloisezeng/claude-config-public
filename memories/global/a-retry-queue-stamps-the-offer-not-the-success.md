---
name: a-retry-queue-stamps-the-offer-not-the-success
description: A queue ordered by "waiting since" starves behind its first permanently failing item unless being OFFERED advances the stamp — and the stamp is offer+1, because offer ties with the cohort arriving at that offer and the tiebreak hands the slot straight back
metadata:
  type: feedback
scope: global
---

Any bounded re-probe queue — resolve a company, retry a fetch, re-screen a posting, re-send a message — orders its candidates by how long each has been waiting, and the waiting-since value is almost always written at DISCOVERY and advanced on SUCCESS. That is correct for everything that eventually succeeds and catastrophic for the first item that never does: it keeps the oldest stamp for ever, sorts ahead of the whole queue on every run, and the item behind it is never offered at all. The flag reads healthy, the cron fires, the failing item's attempt count grows, and nothing anywhere says the queue stopped.

The fix is that being OFFERED is itself an event the row records, and the ordering reads that: `waitingSince = lastOffered === null ? discovered : lastOffered + 1`.

Two details that are the whole of it, and both are invisible without simulating:

- **The `+ 1` is load-bearing.** Mapping `lastOffered` directly gives the failing item the key `r` on the run it was offered in, which TIES it with everything discovered in run `r` — and a tiebreak on identity (a company key, an id) then hands it the slot again, for ever. Simulate cap 1 with three items before writing the code; the degenerate three-item case shows it and the two-item case does not.

Pin it with the exhaustion drive, not with a unit assertion: cap 1, N items, a first item that fails every probe, assert every item was offered AND every item carries attempts. The control is the OLD mapping driven through the SAME harness — mine issued `alpha-robotics` on all three runs — because an assertion that one item per run came out is satisfied by a queue of one.

**Why:** 2026-10-03, the job-hunt build's company-resolution queue. Slug guessing failed for 12 of 20 measured companies, so a permanently failing first company was the NORMAL case rather than an edge, and the queue as written would have resolved exactly one company for ever. Found by simulating the ordering before writing the field, not by review: three review rounds had read the same `firstDiscoveredRun` mapping as correct. The same shape already existed one module over as `contentFirstSeenRun` for read state, which is what made the defect legible — [[measure-a-lanes-inlet-not-its-enable-flag]] is its sibling, where the stage reads green while producing nothing.
