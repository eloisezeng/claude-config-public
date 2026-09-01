---
name: background-subagent-parallel-workflow
description: "the user wants to fire off messages and have the heavier ones answered by background subagents in parallel (Slack-threads style), not blocked one-at-a-time"
metadata: 
  node_type: memory
  type: feedback
  scope: global
  originSessionId: 8ea80339-868d-4aaa-b6aa-ed6777bf483d
---

The user wants a working mode where she can send messages freely and the agent dispatches a **background subagent** to answer the heavier ones in parallel, returning control immediately — Slack-threads style, never sequential one-at-a-time blocking.

**Why:** she dislikes that sending a message blocks her from sending the next while the agent works; she wants to stack questions and get answers asynchronously.

**How to apply:** substantive/heavy question → dispatch a background subagent (Agent tool, or Bash `run_in_background`) and hand control back fast; relay each answer as its subagent completes. Quick questions: answer inline. Never silently fall back to answering everything inline-and-sequential. Format replies richly (**bold**, bullets — including in lavish). She prefers config choices exposed as operator toggles on the page, not hardcoded.

**In lavish:** thread each relayed answer under the message it answers via `stream --agent-reply --reply-to` on her fork — see [[lavish-axi-threading-and-collapsibles]]. Never run concurrent `poll --agent-reply` calls: a newer poll supersedes the open one (SERVER_ERROR, and can drop a user message in flight on the superseded poll).

Related: [[visualize-in-browser]].
