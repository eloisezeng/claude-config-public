---
name: grill-defer-domain-judgment
description: "User defers to Claude's judgment on niche, highly domain-specific trade/plumbing details"
metadata: 
  node_type: memory
  type: feedback
  scope: global
  originSessionId: 35ccf7b1-48bc-4fc2-aec9-b23f3463ed3a
---

During the MVP.md grill, the user said: for niche, highly domain-specific matters (e.g. how plumbers' rate cards / billing conventions work), "I'll defer to your judgment going forward."

**Why:** The user is the product owner, not a trades-billing expert; grilling them on plumbing-industry minutiae (min_job_fee semantics, tax/markup conventions) wastes their time and they trust Claude's domain reasoning there.

**How to apply:** For domain-specific trade/billing/industry-convention details, make a well-reasoned recommendation, apply it, briefly state the choice + rationale, and move on — don't force a multiple-choice decision. RESERVE questions for genuine product/business/scope decisions that are the user's to make (pricing model, what's in MVP scope, UX flow). Still capture the resolved domain choices in CONTEXT.md / CLAUDE.md / ADRs as usual.
