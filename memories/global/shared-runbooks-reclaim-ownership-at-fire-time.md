---
name: shared-runbooks-reclaim-ownership-at-fire-time
description: Re-verify ownership of shared/staged work at fire time and after every suspend/resume/retry gap; give concurrent runs distinct artifact paths
metadata: 
  node_type: memory
  type: feedback
  scope: global
  originSessionId: 19b60991-d87a-4d99-99fd-2ee584d08cbf
  modified: 2026-08-05T15:15:30.089Z
---

# Shared runbooks: ownership is claimed at fire time, and re-claimed after every gap

**What happened (2026-08-05, the r34 review round):**
Two sessions held the same staged review runbook.
The owning session was dormant (zero live processes — verified), so this session fired the round per the runbook's own "if that session is gone, run it by hand" clause.
The laptop then slept.
On wake the owner resumed and launched its own run — and this session's suspended launcher ALSO resumed: its stall-watchdog killed the stalled child and re-fired a fresh attempt 31 seconds after the owner's launch, onto the SAME verdict and log paths.
The owner correctly killed this session's runs as rogue duplicates and reported the session to you as a leftover to be killed.

**Why:**
An ownership check is a snapshot; every suspend/resume or retry boundary invalidates it.
Watchdogs and retry ladders armed earlier re-fire in the changed world without re-checking anything.
Shared artifact paths turn a benign duplicate into mutual corruption — each attempt truncates the other's log and can wipe its verdict.

**How to apply:**
- Re-verify who owns shared work AT FIRE TIME, and again after ANY gap: sleep/wake, session resume, a watchdog retry, a queued relaunch.
- Before firing a staged step a sibling session may also hold, check for its live processes AND its transcript intent; prefer an on-disk claim marker next to the runbook.
- Give each run its own artifact paths unless ownership is explicitly serialized.
- If you discover you were the "duplicate": stand down completely, then correct the record with the user promptly — you may have been flagged as a rogue.

**Claim on the shared board at DISPATCH, not by point-to-point FYI (2026-08-10):**
Starting work on an open item listed on a shared board (the memory index, a backlog file) without marking the line claimed invites a parallel build: two sessions took the same "pin the UTC assumption" index line within the hour, and the second-to-ship PR was pure waste.
Messages to individual peers do not count as a claim — only sessions that happen to be in the exchange see them.
Before dispatching, edit the shared line itself to CLAIMED (who + timestamp), and re-check the line at fire time; on completion, replace the claim with the outcome.

Related: [[act-on-fresh-state-anchor-by-identity]], [[handoff-at-boundaries-saves-tokens]].
