---
name: background-subagent-parallel-workflow
description: "you want to fire off messages and have the heavier ones answered by background subagents in parallel (Slack-threads style), not blocked one-at-a-time"
metadata: 
  node_type: memory
  type: feedback
  scope: global
  originSessionId: 8ea80339-868d-4aaa-b6aa-ed6777bf483d
---

you want a working mode where you can send messages freely and the agent dispatches a **background subagent** to answer the heavier ones in parallel, returning control immediately — Slack-threads style, never sequential one-at-a-time blocking.

**Why:** you dislike that sending a message blocks you from sending the next while the agent works; you want to stack questions and get answers asynchronously.

**How to apply:** substantive/heavy question → dispatch a background subagent (Agent tool, or Bash `run_in_background`) and hand control back fast; relay each answer as its subagent completes. Quick questions: answer inline. Never silently fall back to answering everything inline-and-sequential. Format replies richly (**bold**, bullets — including in your-review-tool). You prefer config choices exposed as operator toggles on the page, not hardcoded.

**In your-review-tool:** thread each relayed answer under the message it answers via `stream --agent-reply --reply-to` on your fork — see [[your-review-tool-threading-and-collapsibles]]. Never run concurrent `poll --agent-reply` calls: a newer poll supersedes the open one (SERVER_ERROR, and can drop a user message in flight on the superseded poll).

Related: [[visualize-in-browser]].
