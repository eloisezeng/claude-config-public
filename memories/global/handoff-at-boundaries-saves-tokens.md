---
name: handoff-at-boundaries-saves-tokens
description: Dispatch a fresh context at TASK BOUNDARIES and for parallelism; ONE compaction is normal, but never assume it beats a handoff — half of every post-compaction window is a re-injected floor, so a recurring compaction means checkpoint and hand off
scope: global
metadata:
  type: feedback
---

**The user (2026-08-10):** "continue with stuff on my plate. handoff if it will save tokens - remember this for future."
**The user (2026-08-17):** "discuss how to minimize token usage e.g. autocompact/handoff more frequently."
**The user (2026-09-15):** "do not assume compaction is preferable to handoff."

**Why (what the corpus measurement changed).** Measured 2026-09-14 over **5,660 automatic compaction boundaries** across both config roots, not the single session an earlier version of this memory reasoned from:

- A compaction re-injects a **median 85,542 tokens** before the successor window does any work — about **half** of the post-compaction window (median 107.7K). The earlier "~34K floor" was the `cache_read` component alone and missed ~52K of `cache_creation`; the earlier "~52K re-warm ≈ a fresh boot's 46–50K" was the summary's own `postTokens`, not the window. Both numbers understated the cost by roughly 2.5x, and neither is a boot-cost comparison.
- A cycle therefore buys a **median 54K tokens, 12 minutes, 32 assistant turns and 8 tool calls** of runway, for a **median 144-second stall**. A third of cycles get fewer than five tool calls.
- The landing point does **NOT scale with the trigger** (Pearson r = -0.036 across the corpus; two real 1M-window sessions landed 32% LOWER than the 200K median at a lower stall). Runway is the trigger minus a roughly fixed floor, which is why raising the window buys proportionally more runway at flat compaction cost — `autoCompactWindow` is **400,000** as of 2026-09-15, triggering near **334K** because the compactor fires at ~83.5% of the configured number.
- Never write that number down a second time. Every band derives from the live setting through `~/dotfiles/claude/hooks/lib/compaction-window.mjs`.

**The rule.** Compaction and handoff both have a real price, and neither is the automatic choice:

- **One compaction is normal and is not a failure, and is not worth contorting the work to avoid.** Before the boundary, make the window disposable: write every unresolved item into durable state (the ops lane ledger `~/.claude/ops/` and/or the lane's own file) and checkpoint the current step.
- **Where the state is already durable on disk, a checkpointed handoff is PREFERABLE even at the first compaction,** because the disk carries more than a summary does. Continue in the compacted window only where the live context still holds something the artifacts do not.
- **A SECOND automatic compaction within 60 minutes means checkpoint and hand off.** Recovery reads are forbidden at that tier. A tool-call runway threshold was considered and the user declined it on 2026-09-15: tasks vary too much in how many calls they need for a call count to measure useful runway. The recurrence count is the whole predicate.
- **A THIRD is an unconditional handoff** — not one of two options, and not a judgement call.
- **A genuine task boundary or parallel work → dispatch a fresh context** (handoff doc + `handoff.sh`) regardless of context level, because there the next item does not need this context.
- Threshold-triggered dispatch on context level ALONE is still not the trigger; the triggers are a task boundary, durable state, or recurrence.

`hooks/compaction-recovery.mjs` enforces the three tiers over a trailing 60-minute window, and `hooks/context-watchdog.mjs` states the choice at WARN and URGENT — see [[trust-the-compact-summary-do-not-rebuild-the-window]].

**How to apply at a boundary (unchanged, still the win):**
- The trigger is a **task boundary, not remaining context**. If the next item is separable, write/refresh the handoff doc and dispatch a fresh-context session pointed at it.
- Put the **derived values in the handoff, each with its provenance pointer**, so the fresh context cites instead of recomputing ([[reduce-token-burn]]).
- Route the delegate's model tier by task shape: mechanical work against a written spec is a cheap tier; judgment and diagnosis are not.
- A handoff moves WORK, never AUTHORITY. Ratified decisions, guarded surfaces, spend limits and submission rights bind the delegate exactly as they bind you.
- Continue inline only when the next item genuinely reuses the live context (same branch mid-review, same artifact in hand).
- Every dispatch registers a **lane** in the ops ledger and every lane needs an explicit close — see [[ops-lane-ledger]].
- **Dispatch flags are part of the handoff:** `handoff.sh <file> -- "<objective>" --permission-mode bypassPermissions --model 'opus[1m]'`. A successor launched in default mode stalls at its first write outside its worktree with nobody to approve (measured 2026-08-20: `d7da2152` did step 0 live, then sat on a prompt for 30+ min while 8/8 sibling dispatches had used `bypassPermissions`); the stall reads as "working" until you read `claude agents --json` (`waitingFor: permission prompt`). Recovery = mark the job `failed`, kill, re-dispatch `--force` with the flags — see [[kill-bg-claude-sessions-via-job-state]].

Related: [[trust-the-compact-summary-do-not-rebuild-the-window]], [[ops-lane-ledger]], [[reduce-token-burn]], [[background-subagent-parallel-workflow]], [[shared-runbooks-reclaim-ownership-at-fire-time]], [[no-extra-cash-without-permission]].
