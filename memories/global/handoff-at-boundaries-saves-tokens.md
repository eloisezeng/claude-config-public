---
name: handoff-at-boundaries-saves-tokens
description: At task boundaries route the next work item to a FRESH context (handoff doc + new session or background subagent) instead of continuing in the spent one; autocompact firing is a planning miss, not a tool
scope: global
metadata:
  type: feedback
---

**you (2026-08-10):** "continue with stuff on my plate. handoff if it will save tokens - remember this for future."
**you (2026-08-17):** "discuss how to minimize token usage e.g. autocompact/handoff more frequently."

**Why:** A long session drags its entire scaffolding (review rounds, dead ends, tool output) into every subsequent turn, so each additional item costs far more than it would in a fresh context.
Autocompact is the expensive way to discover this: it charges a full summarization pass *and* is lossy in a way that costs correctness, not just tokens — after one compaction the exact semantics of a guard function were gone and had to be re-read from source before it was safe to author against it.
A handoff doc costs about the same tokens to write but is deliberate, reviewed, on disk, auditable, and outlives the session.

**How to apply:**
- The trigger is a **task boundary, not remaining context**. "I still have room" is the wrong test — the marginal token in a large context is worth far less than the first token in a fresh one.
- Treat autocompact firing as a planning miss. Hand off, or `/clear`, *before* it fires.
- At a boundary — a decision delivered, a deliverable finished, a separable item starting — ask: does the next item need THIS context, or just a handoff?
- If separable: write/refresh the handoff doc and index entry, then dispatch a fresh-context background subagent pointed at it, or tell you it is staged for a fresh session.
- Put the **derived values in the handoff, each with its provenance pointer**, so the fresh context cites instead of recomputing — re-derivation is the main thing a cold start wastes ([[reduce-token-burn]]).
- Route the delegate's model tier by task shape: mechanical work against a written spec is a cheap tier; judgment and diagnosis are not.
- A handoff moves WORK, never AUTHORITY. Ratified decisions, guarded surfaces, spend limits and submission rights bind the delegate exactly as they bind you — restate them in the handoff prompt, and never let delegation become a path around an approval you would have needed yourself.
- Continue inline only when the next item genuinely reuses the live context (same branch mid-review, same artifact in hand).

Related: [[reduce-token-burn]], [[background-subagent-parallel-workflow]], [[shared-runbooks-reclaim-ownership-at-fire-time]], [[no-extra-cash-without-permission]].

- **Dispatch flags are part of the handoff:** `handoff.sh <file> -- "<objective>" --permission-mode bypassPermissions --model 'opus[1m]'`. A successor launched in default mode stalls at its first write outside its worktree with nobody to approve (measured 2026-08-20: `d7da2152` did step 0 live, then sat on a prompt for 30+ min while 8/8 sibling dispatches had used `bypassPermissions`); the stall reads as "working" until you read `claude agents --json` (`waitingFor: permission prompt`). Recovery = mark the job `failed`, kill, re-dispatch `--force` with the flags — see [[kill-bg-claude-sessions-via-job-state]].
