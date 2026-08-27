---
name: mockup-critiques-into-spec
description: "Fold your mockup critiques into the written spec so they aren't lost before implementation"
metadata: 
  node_type: memory
  type: feedback
  scope: global
  originSessionId: 4e85aedd-72b3-4e58-86b9-ac16d336fd49
---

When you critique a visual mockup (e.g. your-review-tool review surface) during brainstorming, every concrete change you ask for must be carried into the written spec/design doc — not left only in the mockup or the chat.

**Why:** In the TO-DO-13 session, two mockup-approved details — the rename pencil mirrored via `transform: scaleX(-1)`, and CSS-drawing the take-× delete badge as two crossing bars for true centering — were discussed and approved in your-review-tool mockup but never made it into the spec → plan → implementation, so they silently didn't ship. The Decision log captured the big conceptual choices but not the fine visual critiques from the mockup-refinement rounds.

**How to apply:** As mockup critiques come in, append each one to the spec's decision log / a "Visual details" section (exact value: glyph, transform, color, spacing, layout). Before finishing brainstorming, reconcile the final mockup against the spec so every approved pixel-level change is written down, then make sure those line items appear as tasks in the implementation plan. Relates to [[your-review-tool-artifact-prefs]].
