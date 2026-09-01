---
name: codex-handoffs-ship-as-a-pasteable-prompt
description: When the user hands work to a Codex session, deliver a copy-paste prompt block she can drive herself — self-contained, absolute paths, no Claude-side jargon — not a run-codex.sh invocation
metadata:
  node_type: memory
  type: feedback
  scope: global
---

The user 2026-09-01: **"when i handoff to codex session can u just give me a prompt to paste in codex."**

When *she* is moving work to a Codex session, the deliverable is the **prompt text**, in one fenced block she can copy in a single gesture — not a `run-codex.sh` command line, not a description of what to tell Codex, not a file path she has to open first.

**Why:** she drives that Codex session herself, so she is the transport. Codex sees none of our conversation, none of my scratch files, and reads `AGENTS.md` — never `CLAUDE.md`. Anything the task depends on that lives only in my head or my context is simply absent at the other end, and the failure is silent: Codex improvises a plausible answer to a question it was never fully asked. A prompt that assumes shared context is the defect.

**How to apply — the block must survive being pasted cold:**
- **One fence, nothing else inside it.** No commentary, no "here's the prompt:" line within the fence, no trailing notes. She copies the whole block or she has to edit it.
- **Absolute paths everywhere** (repo, worktree, spec, charge, output file). Her cwd is not mine and may not be the repo.
- **State the repo/branch/worktree explicitly** and, if the tree matters, whether Codex may write.
- **Inline the constraints** rather than citing a doc — or point at it by absolute path and say "read this first". Repo conventions in `CLAUDE.md` do not reach Codex.
- **Name the deliverable and its shape**: what to produce, what file to write, what format (and paste the JSON schema inline if the answer must be structured — there is no `--output-schema` when a human drives the session).
- **No Claude-side vocabulary**: no lens names, finding IDs, seat/job ids, lane slugs, or coined shorthand. Codex has never seen any of it.
- **Say the tier and effort OUTSIDE the block** (Sol defaults to `low` — `[[codex-model-tiers-and-effort-routing]]`), since that is a launch choice she makes, not prompt text.
- Then, outside the block, one or two plain lines on what to bring back.

**Scope.** This governs handoffs *she* carries. It does not retire `run-codex.sh` for the fully autonomous convergence arc, where I invoke Codex programmatically and no human is in the loop — `[[codex-exec-hang-watchdog]]` · `[[codex-may-implement-never-self-review]]`. Default to the paste block whenever she is the one asking to hand something over.
