---
name: assert-complete-message-not-substring
description: For text assembled conditionally, assert the whole happy-path output byte-for-byte — a contains-check passes while spurious clauses ship
scope: global
metadata:
  type: feedback
---

When a user-facing string is assembled from conditional parts, **assert the complete happy-path output byte-for-byte**, not that it contains the payload. Also assert the absence of the clauses that must NOT appear.

**Why:** a `toContain` / `toMatch` assertion on the important substring passes no matter what else got concatenated on. Every failure-mode test is the mirror image — it asserts the apologetic or degraded clause is PRESENT — so the pair leaves the happy path's *full* text unchecked by construction.

Concretely (2026-07-26, agent chat): a bounded tool loop appended "I couldn't finish checking everything in one go" whenever it thought it had run out of steps, and inferred that from "the last conversation entry is a tool_result batch" — which is **always** true after a successful look-up-then-answer, because the loop appends the results, the model replies with prose, and the loop breaks appending nothing further. So *every* grounded answer carried the apology. 4,780 tests were green: the runaway test asserted the line was present; the receipt test asserted only that the answer contained the stored reason. The bug surfaced on the first real turn against the live instance.

**How to apply:**
- One test per surface asserts the entire expected string with `toBe`, on the ordinary success path.
- Add explicit negative assertions for the conditional clauses (`not.toMatch(/couldn't finish/i)`).
- Derive the "degraded" condition from an explicit flag set where the thing actually happened, never inferred from a state that the success path also reaches. That inference is the real defect; the weak assertion only hid it.

Related: [[verify-claims-against-artifacts]] (verify against the artifact, not a flag), [[unambiguous-status-and-logs]] (one enum value per meaning — an inferred condition overloaded across two outcomes is the same mistake in a different shape).
