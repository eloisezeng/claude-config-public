---
name: handoff-at-boundaries-saves-tokens
description: Dispatch a fresh context at TASK BOUNDARIES and for parallelism; mid-task context pressure is auto-compact's job (measured safe, ~52K re-warm ≈ a fresh boot), never a reason to hand off
scope: global
metadata:
  type: feedback
---

**The user (2026-08-10):** "continue with stuff on my plate. handoff if it will save tokens - remember this for future."
**The user (2026-08-17):** "discuss how to minimize token usage e.g. autocompact/handoff more frequently."
**Superseded in part by the 2026-08-31 lifecycle decision** (record: `your-other-project/docs/notes/LIFECYCLE-DECISION-context-vs-handoff-2026-08-31.md`): an earlier version of this memory called auto-compact firing "a planning miss" and said to hand off before it fires. That was measured and found wrong.

**Why (what the measurement changed):** auto-compact near 200K costs a ~2 min stall and a ~52K re-warm — about the same as a fresh session's boot (46–50K) — and `autoCompactWindow=200000` stays the enforced context ceiling (measured 2026-08: it cut per-request cost 68%, and tightening to 150K buys only 4% more). Compaction transfers no ownership, runs no dispatch machinery, and cannot lose the lane. A mid-task handoff at high context costs the same tokens PLUS a dispatch, a successor boot, an ownership transfer that can fail, and the risk that work not yet written down dies with the window. So the two mechanisms have disjoint jobs:
- **Mid-task context pressure → let auto-compact fire.** Before the boundary, make the window disposable: write every unresolved item into durable state (the ops lane ledger `~/.claude/ops/` and/or the lane's own file), checkpoint the current step, keep working.
- **A genuine task boundary or parallel work → dispatch a fresh context** (handoff doc + `handoff.sh`), because there the next item does NOT need this context, and a fresh boot is cheaper than dragging a spent one.
- Threshold-triggered dispatch ("context is high, hand off now") is demoted: never dispatch merely because context is high.

The old "compaction is lossy" concern is real but has a cheaper cure than a handoff: durable-state hygiene (the write-it-down step above), which the context watchdog now instructs at WARN/URGENT.

**How to apply at a boundary (unchanged, still the win):**
- The trigger is a **task boundary, not remaining context**. If the next item is separable, write/refresh the handoff doc and dispatch a fresh-context session pointed at it.
- Put the **derived values in the handoff, each with its provenance pointer**, so the fresh context cites instead of recomputing ([[reduce-token-burn]]).
- Route the delegate's model tier by task shape: mechanical work against a written spec is a cheap tier; judgment and diagnosis are not.
- A handoff moves WORK, never AUTHORITY. Ratified decisions, guarded surfaces, spend limits and submission rights bind the delegate exactly as they bind you.
- Continue inline only when the next item genuinely reuses the live context (same branch mid-review, same artifact in hand).
- Every dispatch registers a **lane** in the ops ledger and every lane needs an explicit close — see [[ops-lane-ledger]].

Related: [[ops-lane-ledger]], [[reduce-token-burn]], [[background-subagent-parallel-workflow]], [[shared-runbooks-reclaim-ownership-at-fire-time]], [[no-extra-cash-without-permission]].

- **Dispatch flags are part of the handoff:** `handoff.sh <file> -- "<objective>" --permission-mode bypassPermissions --model 'opus[1m]'`. A successor launched in default mode stalls at its first write outside its worktree with nobody to approve (measured 2026-08-20: `d7da2152` did step 0 live, then sat on a prompt for 30+ min while 8/8 sibling dispatches had used `bypassPermissions`); the stall reads as "working" until you read `claude agents --json` (`waitingFor: permission prompt`). Recovery = mark the job `failed`, kill, re-dispatch `--force` with the flags — see [[kill-bg-claude-sessions-via-job-state]].
