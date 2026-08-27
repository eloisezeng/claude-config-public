---
name: mirror-a-gate-at-its-exact-scope
description: "When the UI surfaces a backend gate, apply it exactly where the gate applies — every over-application is a false alarm about something that never happens"
metadata:
  type: feedback
scope: global
---

When you surface a backend rule in the interface — a cap, a quota, a lock, a budget — copying the rule's *logic* is the easy half. The half that gets missed is its **scope**: the conditions under which the backend consults that rule at all. Read the enclosing branches, not just the comparison.

**Why:** on 2026-08-07 an outreach card was made to state a daily email cap and refuse a click that provably sends nothing. The comparison was mirrored perfectly. But the gate sits inside `if (!simulated && email)`, and a separate wrapper routes any demo-flagged action to an inert handler before the gate is reached. So the UI announced "nothing can send" and disabled the button on two populations the executor never caps: dry-run companies and demo cards. A fix for silence had manufactured two new lies. Three narrow review lenses each read it as in-scope-for-someone-else; a whole-diff pass found both.

**How to apply:**
- Before mirroring a gate, find every condition that must hold for the backend to *reach* it, and reproduce that set — mode flags, feature guards, wrapper interceptors, early returns above it.
- State the resulting invariant in one sentence and put it in the code: "the cap constrains the UI iff <conditions>, and nowhere else." A rule you can say in one line is one you can test.
- Look for the codebase's existing precedent — a sibling warning almost always already solves this (`isLive` gating on a balance or lock warning) and its comment usually explains why.
- A shared *predicate* beats a repeated expression. When the backend routes on truthiness and the UI tests `=== true`, they agree until the day they don't; export one function and have both call it. See [[unambiguous-status-and-logs]].
- Over-application fails as loudly as under-application, and is harder to spot: under-application looks like the old bug, over-application looks like a working feature that is quietly wrong.
