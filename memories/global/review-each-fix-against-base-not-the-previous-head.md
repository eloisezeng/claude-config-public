---
name: review-each-fix-against-base-not-the-previous-head
description: A fix that changes WHAT an expression reads must be re-measured against BASE, not against the head it is fixing — a one-step drift is invisible head-to-head and survives every later round
metadata:
  type: feedback
scope: global
---

Scope each review round `BASE...HEAD`, and when a fix changes **what an expression reads** (which counter, pre- or post-increment, which index, which key), re-derive that expression's values against **BASE** — not against the head being fixed.

**Why.** Measured 2026-08-31 on the zone-scout-com download fix. Round 6 accepted a real MEDIUM (counters charged before a sleep, so the timeout diagnostic over-counted), and the fix moved the sleep above the increment. The gate therefore read a *different value*, and a `+ 1` was added to keep it "1-based" — which shifted **every rung of the exponential backoff ladder one place up against BASE**, costing +30.5 s of mandatory sleep out of an unchanged 70-minute deadline, on exactly the two lanes that worked in production. Rounds 5 and 6 each compared their head against the *previous head*, where a uniform one-step drift is invisible. It took a round-7 lens reading BASE to see it.

Two amplifiers, both worth checking directly:

- **A drift is invisible at a clamped ladder's ENDS.** A floor swallows the bottom rungs, a cap swallows the top; the cost is entirely in the middle. So a test on one rung near either end proves nothing about the schedule.
- **Shape-only assertions cannot see it.** Every pacing test injected `backoffMs: () => 0` and asserted the *sequence of arguments*. Pin the schedule in the unit the regression is measured in (milliseconds), through the real production function, and **freeze BASE's formula as a literal in the test** — it no longer exists in the tree, and a regression pin needs the baseline it pins against. Then assert the intended delta as a number, so the deliberate part cannot move silently.

**How to apply.** At every fix round: name the expressions whose *inputs* changed, enumerate their values at BASE and at HEAD side by side, and state the delta as a number before accepting the fix. If the delta is intended, assert it. And derive the worst case as arithmetic over the whole domain rather than reading one fixture's total — one fixture's best case is not a bound, and a "total" quoted as a "delta" is the same overstatement one level up. Related: [[close-the-reviewed-head-gate-by-measuring-identity]] · [[verification-claims-are-earned-per-item]] · [[surprising-result-check-metric-identity]].
