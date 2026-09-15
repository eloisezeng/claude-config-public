---
name: trust-the-compact-summary-do-not-rebuild-the-window
description: After an auto-compaction, the summary IS the durable state — continue from the next action with bounded targeted reads, never a whole-file re-read; a SECOND compaction in an hour means checkpoint and hand off, and a third is an unconditional handoff
metadata:
  scope: global
  type: feedback
---

After an auto-compaction, the compact summary is the durable state of the work.
It was written by you, from the full context, for exactly this moment.
Continue from the NEXT ACTION it names instead of reconstructing the window that was discarded.

**Why.**
Measured 2026-09-14 over **5,660 automatic compaction boundaries** across both config roots, with one pathological session contributing 232 of them.
The median window immediately before a boundary is **166K tokens** and the median window of the first request after one is **107.7K**.
The reason is a re-injection floor of a **median 85,542 tokens** — about HALF the post-compaction window — made of invoked skills, CLAUDE.md and the memory index, the compact summary itself, file attachments and hook context.
An earlier version of this memory put that floor at ~34K; that figure was the `cache_read` component alone and missed roughly 52K of `cache_creation`, so it understated the cost by a factor of about 2.5.
A cycle therefore buys a median **54K tokens, 12 minutes, 32 assistant turns and 8 tool calls** of runway for a median **144-second** stall, and a third of cycles get fewer than five tool calls.
The floor does not scale with the trigger (Pearson r = -0.036), which is why `autoCompactWindow` was raised to 400,000 on 2026-09-15 — it triggers near 334K, and the extra headroom is runway rather than a bigger floor.
The behavioural half is the amplifier: in the 25 main-chain assistant records after each boundary there were 2,282 Bash calls, 278 Reads, 138 Edits and 82 Writes, with one source file re-read 34 times and one spec 32 times across the session.
Nothing told a session what to do after a compaction, so every standing re-verification directive — re-measure at ACT TIME, fetch before you diagnose, verify claims against artifacts — fired again from zero with no memory of having already fired, refilled the window, and compacted again.

**How to apply.**
Freshness checks survive, but BOUNDED: read the specific span you are about to edit (an offset and a limit, one grep with a pattern, one `git show`), never a whole file, and only a few such reads before the next real action.
A read that exists to remind you of something, rather than to decide the step in front of you, is the read to skip.
If the summary names a value — a path, a measured number, a decision, a command that worked — that value is the answer, and re-measuring it is the loop.
Where the summary is genuinely silent, say so in one line and proceed on a stated assumption rather than reading until you find it.

The circuit breaker is `hooks/compaction-recovery.mjs`, a SessionStart hook that fires only on `source == "compact"` and counts compaction boundaries inside a trailing 60-minute window.
Its thresholds are measured, not chosen: minutes between consecutive compactions ran p10 6.6, median 10.0, p90 26.0, and the failing session reached 9 in one hour with 3-or-more-in-an-hour holding at 200 of its 232 boundaries.
Tier 1 (one compaction in the hour) states the protocol, and adds that where the state is ALREADY durable on disk a checkpointed handoff is preferable even here, because the disk carries more than the summary does.
Tier 2 (two) forbids recovery reads outright and directs a checkpoint and a handoff: continuing buys a median eight tool calls before the next boundary, while the handoff buys a whole window.
Tier 3 (three or more) is an UNCONDITIONAL handoff — not one of two options and not a judgement call: checkpoint the durable state into the artifact that already owns it, finish or abandon the one action in flight, and hand off at that boundary.
The user declined a projected tool-call threshold on 2026-09-15, because tasks vary too much in how many calls they need for a call count to measure useful runway; the recurrence count inside the hour is the whole predicate.

Related: [[measure-what-reaches-context-not-disk]] · [[handoff-at-boundaries-saves-tokens]] · [[reduce-token-burn]] · [[check-the-cadence-not-only-the-action]]
