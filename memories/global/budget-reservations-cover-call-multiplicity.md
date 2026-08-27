---
name: budget-reservations-cover-call-multiplicity
description: "An admission-time budget reservation must cover every billable sub-call of what it admits — audit the metered path's real call multiplicity (retries, resumes, fan-out), not the caller's 'one call' mental model"
metadata:
  type: feedback
scope: global
---

When admitting concurrent budgeted work with reservations, the reservation must cover **every billable sub-call** the admitted unit can make — internal retries, resumable continuations (e.g. Anthropic `pause_turn` re-sends), fan-out legs — not the single call the caller pictures.

**Why:** 2026-08-01, outreach parallel engine — admission reserved one estimated call per LLM leg, but the metered path's `pause_turn` resume loop could book up to 4 calls per leg against that one reservation, so the lane cap was exceedable in production. Tests all green because they stubbed single-shot responses. Codex caught it in review.

**How to apply:**
- Before wiring a reservation, read the metered/billed path end-to-end and count its maximum bookings per admitted unit; make the reservation lifecycle match (incremental reservations per sub-call, or a multiplicity-sized reservation).
- Give the sub-call site access to the same reserve/refuse arithmetic so a refused continuation degrades (return partial) instead of booking unreserved spend.
- Test with a stub that exercises the multiplicity (a resuming/retrying response), not just the single-shot happy path.
- Sibling trap, same session: counting quota from a persisted artifact row that is written AFTER the spend (attempt rows) — cover the gap with an in-process reservation released only when the artifact row's transaction commits, and on every failure path hold the reservation so capacity leaks toward under-admission, never over-spend.
