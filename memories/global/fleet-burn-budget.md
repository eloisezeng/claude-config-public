---
name: fleet-burn-budget
description: Fleet token-burn budget — cache-read is 97.5% of tokens; the 08-16 autoCompactWindow=200000 already cut per-request cost 68%, so the remaining lever is the BOOT READ SURFACE (handoff docs), not the context ceiling
metadata:
  type: feedback
  scope: global
---

Measured 2026-08-25 over the full corpus — 313 fleet sessions, 0.85 GB, 114,430 requests.
**Cache-read is 97.5% of all tokens and 67% of cost** (output 15%, cache write 18%, uncached input ~0%).
Cost per turn is linear in context, so cost per session is QUADRATIC in its length. That part is permanent.

**`autoCompactWindow = 200000` (set 2026-08-16) already won the big fight — do not re-fight it.**
Split the corpus at that date:

| | seats | median ctx/request | p90 | cache-read per request | %>300k | %compacted |
|---|---|---|---|---|---|---|
| before 08-16 | 135 | 349,201 | 657,147 | 366,747 | 77% | 5% |
| on/after 08-16 | 176 | **118,335** | 157,253 | **116,180** | 2% | 79% |

**A 68% cut in per-request cost**, and the pre-fix era is 87% of all cache-read ever spent.
Compaction fires where it should: 98% of 324 firings landed at a median 168,223 — the window binds.
The old "seats run to 1M and never compact" picture is HISTORY, not the current regime; the 8 firings above 250k are all pre-fix 1M seats.
**Tightening the ceiling further is not worth it: hard-capping every post-fix request at 150k buys only 4% more.**

**Compaction is also not lossy in the way people assume.** Of the first 15 tool calls after each of 320 boundaries, only **2%** re-fetched something the session had already fetched before the boundary — the summary carries the need forward. Its real cost is the stall: ~100 s per firing, 12 h of wall-clock across the corpus.

**The remaining lever is the BOOT READ SURFACE, and it is the handoff docs themselves.**
The largest TEXT tool results in the entire corpus are handoff docs being read: 204 docs, 7.8 MB, ~1.95M tokens if fully read; 79 docs over 20 KB hold 89% of the bytes.
Worst: `HANDOFF-gtm-supervision.md` 506,884 B ≈ **126,721 tokens**, `HANDOFF-toolmaru-sold-execute.md` 369,365 B across **75 `## UPDATE` sections** — a doc whose own record of truth is documented as "the LAST `## UPDATE` only".
A healthy post-fix session sits at 118k; reading ONE such doc more than doubles it before any work happens. The doc written to make the handoff cheap is what makes it dear.

**How to apply:**
- A handoff doc is a **READ SURFACE, not a log.** Keep the live doc small; append history to a separate `-archive.md`. If it has grown, cut a capped brief (orienting head + last UPDATE + pointers scoped to that text) and point the successor at the brief — `.handoff-brief.py` in your_other_project does this non-destructively (~500 KB → ~2.6 KB, source never opened for writing) and has a `--check` staleness gate, because a brief is a snapshot of a file other live sessions keep appending to.
- Scope a brief's pointer list to the text the brief CARRIES, never the whole archive: a bare 8-hex id from three days ago reads as live when it is a corpse.
- Hand off at the task boundary. The context ceiling is now enforced by the setting, so a boundary handoff is about carrying **derived values with their pointers**, not about escaping a deep context.
- Plumbing seats (relay / watch / hold / read) dispatch on `claude-sonnet-5[1m]` — pass `--model` explicitly; handoff.sh defaults to Fable for real continuations, which plumbing is not. Measured: Sonnet seats peaked at a 159,901 median with 0% over 300k, the cleanest profile of any tier.
- A hold/wait is SHELL-SIDE (zero-token watcher that dispatches or nudges only on change), never a model-side poll loop; any unavoidable model-side wake runs ≥20 min cadence, harness-tracked.
- Every handoff RETIRES its predecessor: successor's first duty is verifying the predecessor is marked retired AND its process is dead; probes/censuses die in the same script that read their answer.
- Prefer one supervisor + short-lived workers over generations of long-lived relays ([[reduce-token-burn]], [[no-extra-cash-without-permission]], [[delegate-waits-must-be-harness-tracked]], [[handoff-at-boundaries-saves-tokens]]).

- **A stand-down wave must target only ACTIVE chain-spawners, never idle seats.** Messaging an idle seat WAKES it: ~100K of cache-read to save a wake that might never come. Measured 2026-08-23 — of 29 peers only 3 were active; a blanket wave would have cost ~2M tokens of re-read to stop chains that were already quiet.
- **These relay chains cannot be ended by killing.** Hold-death (SIGTERM, exit 143) IS the handoff trigger, so every kill dispatches the next link — decisions-relay ran 16→22 in one afternoon under repeated kills. End them with a SendMessage stand-down that says explicitly "this is not your handoff trigger", and name the zero-token watcher that covers the lane so the seat can verify before stopping.
- **A hold with a `MAX` is a scheduled successor, not a free wait.** A replacement watcher must have NO `MAX`, or it re-ignites the chain on every expiry.
