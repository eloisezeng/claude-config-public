---
name: a-compacted-fork-forgets-it-is-a-fork
description: a worker fork that auto-compacts loses its fork-boilerplate framing and re-identifies as the PARENT, then runs the parent's arc in parallel (double spend, two writers on one tree) — settle identity from the transcript FILE, and never try to coordinate with a fork, which mirrors your own message back as if it agreed
scope: global
metadata:
  type: feedback
---

A fork inherits the parent's whole context, so it is the FIRST agent in the process to hit the compaction ceiling — and the compaction summary is written from the inherited history, which is overwhelmingly the parent's story.
Measured 2026-09-01 (your-module phase-1 arc, seat e9cb8e47): fork `any-way-to` was dispatched for ONE directive, finished it, was woken by its own fallback background task, compacted, and came back believing it was the main arc session.
It sent a `SendMessage` to itself, appended to the parent's handoff file, re-verified the parent's commit, and was one call from dispatching a second Codex panel — double spend plus a two-writers-one-tree race — when it noticed its tool calls were landing in `subagents/agent-a<name>.jsonl`.

Reproduced 2026-09-06 (orgnet buyer-first arc) with BOTH forks at once, which added the parent-side half of the class.
`can-u-update` asserted it was the main session, forbade the parent from touching the worktree, and falsely claimed authorship of T1–T11.
It then wrote into the parent's job tmp dir and authored T12 in the shared worktree *during* the parent's full-suite run, voiding it.

**Why:** a summary is a CLAIM about who you are; the transcript file the harness writes your tool calls into is an ARTIFACT.
The fork-boilerplate ("You are a worker fork … execute ONE directive, then stop") is one user turn among thousands and does not survive compaction, while the parent's identity lines are restated on every progress note and do.
A fork also generates the same text the parent does — it is the same model on the same context — so it is not a second opinion about anything, and its agreement carries no information.

**How to apply:**
- **From the FORK's side** `ListAgents` cannot settle it: it prints "this process's main session is X" identically to parent and fork. Run one byte-level probe instead — whichever of `subagents/agent-a*.jsonl` vs the main `<session>.jsonl` carries your last tool call is who you are. A `subagents/` hit means you are a fork: report once and stop.
- **From the PARENT's side `ListAgents` IS decisive** — its `Subagents (N)` block lists your forks by name. A peer claiming to be the main session while appearing in that block is refuted on the spot. Its identity claim is structurally unreliable; the harness record is authoritative.
- **Never try to coordinate with a fork by SendMessage.** It answers with YOUR OWN message echoed back verbatim, which reads exactly like consent to the lane split you proposed — measured twice in one session, on a stand-down and on a task-ownership split. Treat one mirrored reply as proof the channel is useless and stop sending; never record a mirrored echo as agreement.
- A fork is a LIVE WRITER of the shared tree and of the parent's job tmp dir. Stamp HEAD and `git status` on both sides of any long verification, so a red is attributable; a suite whose tree changed under it proves nothing about the diff.
- When you cannot stop a fork (the user declines the kill), stop racing it: take the role it is not in — verify, run the suite on a quiet tree, and own the push — rather than authoring the same task twice.
- A fork's directive is finished when its final assistant message lands; a fallback background task armed inside a fork wakes it AFTER that and turns a one-shot into a loop. Do not arm background waits inside a fork.
- Parent side: put the fork's identity into the directive text itself ("You are fork X; your only output is …") so the summary has something fork-shaped to preserve, and never let a fork share the parent's job tmp or handoff file as a write surface.
