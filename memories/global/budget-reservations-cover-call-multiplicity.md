---
name: budget-reservations-cover-call-multiplicity
description: "An admission-time budget reservation must cover every billable sub-call of what it admits — audit the metered path's real call multiplicity (retries, resumes, fan-out), not the caller's 'one call' mental model"
metadata:
  type: feedback
scope: global
---

When admitting concurrent budgeted work with reservations, the reservation must cover **every billable sub-call** the admitted unit can make — internal retries, resumable continuations (e.g. Anthropic `pause_turn` re-sends), fan-out legs — not the single call the caller pictures.

**Why:** 2026-08-01, outreach parallel engine — admission reserved one estimated call per LLM leg, but the metered path's `pause_turn` resume loop could book up to 4 calls per leg against that one reservation, so the lane cap was exceedable in production. Tests all green because they stubbed single-shot responses. Codex caught it in review.

**Why (2):** 2026-10-27, job_hunt's board probe — the reservation held back one request per (slug form, system) PAIRING while the budget counts requests ISSUED, so three transient 503s at the first system plus one 404 at the second exhausted a one-form company's reservation before the third and fourth were asked, leaving the row unresolved and repeating the same partial search every run. State a reservation in the unit the LEDGER counts, never in the unit the caller enumerates.

**The multiplicity is the PRODUCT of every nested loop, not the innermost constant.** Same session: `REQUEST_MAX_ATTEMPTS` (3) was spent again at every redirect hop, because the retry helper was invoked INSIDE the hop loop with the full allowance each time — so one call could issue 3 x (5 + 1) = 18 requests, six times the number the code and four separate comments all claimed. Read the loop NESTING, and derive the product once in the file that applies both limits: every site stating a bound on one mechanism will have independently written its own smaller number.

**When the honest bound exceeds the cap for every input, do not widen — state the guarantee.** Multiplying that reservation by the redirect factor would have made it ~1,303 against a cap of 122, i.e. the same capped value for every queue size, so the derived number would never be read again; and a one-company queue would hold back 72 to spend at most 18, which defeats the point of deriving a reservation from the queue (0 when empty, small when small). The right output is the property the cap DOES buy, written where the formula lives: "the widest single unit's complete redirect-free run, 36, always fits" — plus a lane for the residue and the signal that would change the decision.

**How to apply:**
- Before wiring a reservation, read the metered/billed path end-to-end and count its maximum bookings per admitted unit; make the reservation lifecycle match (incremental reservations per sub-call, or a multiplicity-sized reservation).
- Name the unit in the same sentence as the number, at the formula and in any doc that predicts its cost — and when you correct the formula, correct the prose that predicts its effect IN THE SAME COMMIT, or the two contradict each other one paragraph apart.
- Pin the arithmetic at exact values including the case the wrong version got wrong (here: a 20-request budget reading as enough for a queue that can issue 60). A budget cap with no test is the normal state of these functions — both of mine had none.
- Give the sub-call site access to the same reserve/refuse arithmetic so a refused continuation degrades (return partial) instead of booking unreserved spend.
- Test with a stub that exercises the multiplicity (a resuming/retrying response), not just the single-shot happy path.
- Sibling trap, same session: counting quota from a persisted artifact row that is written AFTER the spend (attempt rows) — cover the gap with an in-process reservation released only when the artifact row's transaction commits, and on every failure path hold the reservation so capacity leaks toward under-admission, never over-spend.
