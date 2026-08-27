---
name: your-review-tool-triage-model-routing
description: "When answering your-review-tool annotations, triage each by complexity and route Haiku/Sonnet/Opus, label the model used in the reply, and let the user override."
metadata: 
  node_type: memory
  type: feedback
  scope: global
  originSessionId: d1655a75-f8a7-4eda-a004-e936ef4210ed
---

When you review via `your-review-tool` and send annotations/questions, you want each answer **model-routed by complexity** rather than all on one model:

- **Haiku** — pure definitional / acronym questions answerable without reading repo code ("what does PINN/IFC stand for").
- **Sonnet** — code-grounded factual questions that need reading the repo to answer accurately (most questions).
- **Opus** — design / "why" / multi-step / build tasks.

Dispatch Haiku/Sonnet answers via subagents with a `model` override; answer Opus-tier in the main loop.

**Why:** cost efficiency — most simple annotations don't need Opus, but code-grounded ones do (Haiku tends to hand-wave on grounded code questions, so don't route those to it).

**How to apply:** prefix every your-review-tool reply with the model used, e.g. `[ model: Sonnet ]`, and tell you you can reply `haiku` / `sonnet` / `opus` on that thread to re-answer with a different model; honor such overrides. your-review-tool itself has no model logic — routing is a Claude Code decision (the model is the session's, not your-review-tool's). Consume annotations with PR #111's `your-review-tool stream <file> --once` (one message per annotation) and thread replies with `--reply-to <id>`.
