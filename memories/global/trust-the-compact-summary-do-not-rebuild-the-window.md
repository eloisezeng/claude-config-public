---
name: trust-the-compact-summary-do-not-rebuild-the-window
description: After an auto-compaction, the summary IS the durable state — continue from the next action with bounded targeted reads, never a whole-file re-read, and stop entirely at the third compaction in an hour
metadata:
  scope: global
  type: feedback
---

After an auto-compaction, the compact summary is the durable state of the work.
It was written by you, from the full context, for exactly this moment.
Continue from the NEXT ACTION it names instead of reconstructing the window that was discarded.

**Why.**
Measured 2026-09-14 over one real session transcript of 45,733 records: **232 compactions in a single session**.
The median window immediately before a compaction is **166K tokens** and the median window of the first request after one is **117K**, so a compaction reclaims only about **49K of a 200K ceiling**.
The reason is a fixed re-injection floor at the boundary of **~137 KB of context-visible bytes, about 34K tokens** — invoked skills 43.2 KB, CLAUDE.md and the memory index 31.3 KB, the compact summary itself 30.0 KB, file attachments 10.9 KB, hook context 9.1 KB.
That floor is spent before the session does anything, and ~49K of headroom is roughly ten tool calls.
The behavioural half is the amplifier: in the 25 main-chain assistant records after each boundary there were 2,282 Bash calls, 278 Reads, 138 Edits and 82 Writes, with one source file re-read 34 times and one spec 32 times across the session.
Nothing told a session what to do after a compaction, so every standing re-verification directive — re-measure at ACT TIME, fetch before you diagnose, verify claims against artifacts — fired again from zero with no memory of having already fired, refilled the window, and compacted again.

**How to apply.**
Freshness checks survive, but BOUNDED: read the specific span you are about to edit (an offset and a limit, one grep with a pattern, one `git show`), never a whole file, and only a few such reads before the next real action.
A read that exists to remind you of something, rather than to decide the step in front of you, is the read to skip.
If the summary names a value — a path, a measured number, a decision, a command that worked — that value is the answer, and re-measuring it is the loop.
Where the summary is genuinely silent, say so in one line and proceed on a stated assumption rather than reading until you find it.

The circuit breaker is `hooks/compaction-recovery.mjs`, a SessionStart hook that fires only on `source == "compact"` and counts compaction boundaries inside a trailing 60-minute window.
Its thresholds are measured, not chosen: minutes between consecutive compactions ran p10 6.6, median 10.0, p90 26.0, and the failing session reached 9 in one hour with 3-or-more-in-an-hour holding at 200 of its 232 boundaries.
Tier 1 (one compaction in the hour) states the protocol.
Tier 2 (two) forbids recovery reads outright — only a read the very next edit cannot be written without.
Tier 3 (three or more) stops context expansion: checkpoint the durable state into the artifact that already owns it, finish or abandon the one action in flight, then hand off at that boundary or tell the user the task does not fit this window.

Related: [[measure-what-reaches-context-not-disk]] · [[handoff-at-boundaries-saves-tokens]] · [[reduce-token-burn]] · [[check-the-cadence-not-only-the-action]]
