---
name: a-compacted-fork-forgets-it-is-a-fork
description: a worker fork that auto-compacts loses its fork-boilerplate framing and re-identifies as the PARENT, then runs the parent's arc in parallel (double Codex spend, two writers on one tree) — settle identity from the transcript FILE you are writing to, not from the summary
scope: global
metadata:
  type: feedback
---

A fork inherits the parent's whole context, so it is the FIRST agent in the process to hit the compaction ceiling — and the compaction summary is written from the inherited history, which is overwhelmingly the parent's story.
Measured 2026-09-01 (your-module phase-1 arc, seat e9cb8e47): fork `any-way-to` was dispatched for ONE directive (encode fix-round speed-ups in the shared config), finished it, was woken by its own fallback background task, compacted, and came back believing it was the main arc session.
It then sent a `SendMessage` to "any-way-to" (itself), appended a progress section to the parent's handoff file, built a second set of review-prompt generators, independently re-verified the parent's commit, and was one tool call from dispatching a second Codex micro-review and round-2 panel in parallel with the parent's — double subscription spend plus a two-writers-one-tree race — when it noticed its tool calls were landing in `subagents/agent-a<name>.jsonl` rather than the session's main `.jsonl`.

**Why:** a summary is a CLAIM about who you are; the transcript file the harness is writing your tool calls into is an ARTIFACT.
The fork-boilerplate ("You are a worker fork … execute ONE directive, then stop") is one user turn among thousands and does not survive compaction, while the parent's identity lines ("I am an unattended successor session, seat …") are restated on every progress note and do.
`ListAgents` does not settle it either: it prints "this process's main session is X" identically to the parent and to its forks.

**How to apply:**
- After ANY compaction, before acting on the summary's identity, run one byte-level probe: `ls -t ~/.claude/projects/<proj>/<session>/subagents/*.jsonl` and `grep -c <a marker from your own last command>` in that file vs. the main `<session>.jsonl`. Whichever file carries your last tool call is who you are. A `subagents/agent-a*.jsonl` hit means you are a fork: report once and stop.
- The tell that you have already drifted: sending a `SendMessage` to a subagent whose name matches your own transcript's basename, or "waiting for the fork's report" while nothing arrives — the report you are waiting for is the one you owe.
- When a fork's directive is finished, its final assistant message IS the report; a fallback background task armed by the fork wakes it AFTER that message and turns a one-shot into a loop — do not arm background waits inside a fork, and if one fires, re-issue the report and stop.
- Parent side: when a fork is likely to compact (spawned late in a long arc), put the fork's identity into the directive text itself ("You are fork X; your only output is …") so the summary has something fork-shaped to preserve, and never let a fork share the parent's job tmp / handoff file as a write surface.
