---
name: feedback-spec-stated-rules-exactly
description: When you state a precise display/counting/layout/timing rule, implement it EXACTLY and pin it with a test — approximate implementations get re-filed verbatim
metadata:
  node_type: memory
  type: feedback
  scope: global
  originSessionId: 147d8326-54aa-44ef-bf0e-12b81f962fcd
---

When you give a **precise rule** — exact count numbers, row layouts, on-the-beat timing, a specific icon transform — you mean it literally. "Close enough" implementations don't satisfy you; they come back as the *same* TO-DO line in the next round.

**Why:** your-project project's TO-DO list is the evidence. The count-number-wrapping rule was re-specified across **7 rounds** (TO-DO 5/7/8/9/13/14/18) because each pass approximated it (see [[count-display-invariants]]). And explicitly-agreed spec items shipped *missing*: TO-DO-14 — "i told you to flip the pencil icon about the vertical axis… i thought we brainstormed this together. why didn't you implement?" and the 16-beat wrapping "i thought we brainstormed this in the last spec. why didn't you implement?" Re-correcting the same rule wastes rounds and erodes trust.

**How to apply:**
1. Treat every stated numeric/layout/timing rule as a hard **invariant**, and pin it with a unit test in the same change (RED→GREEN). A passing invariant test is the proof it's exact, not approximate.
2. Before claiming done, **reproduce the exact example you cited** end-to-end (the specific video, the specific segment size) and confirm the rule holds *there*, not just in general. Ties into [[execution-verification-prefs]].
3. Carry every agreed detail from brainstorm/spec into the plan as a task so it can't silently drop — [[mockup-critiques-into-spec]] — and fix everything you flag along the way — [[feedback-fix-dont-just-note]].
