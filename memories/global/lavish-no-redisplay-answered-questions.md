---
name: lavish-no-redisplay-answered-questions
description: "In Lavish review surfaces, never re-display a question the user already answered — show it as confirmed/collapsed instead"
metadata: 
  node_type: memory
  type: feedback
  scope: global
  originSessionId: 55767a6f-fa0c-4916-9e7f-90f33317cd9f
---

When building Lavish review surface (and later the forked version), once you have answered a question, do NOT show that question again on a subsequent update of the page.
Replace it with a compact "confirmed / answered" summary (or collapse it) so the surface only ever presents what still needs your input.

**Why:** You answered Q2 (parallel gaps), and a later page revision still rendered Q2 as an open question alongside the one remaining question — you found re-asking an already-settled question redundant and told me directly to remember it.

**How to apply:** Track which `data-lavish-question` keys have been answered. On any re-render/agent-reply, render answered questions as a small "✓ Confirmed: <answer>" line, and keep only unanswered questions as live controls. Relates to [[visualize-in-browser]], [[present-options-abc-not-star]], and [[check-memory-before-asking-user]].
