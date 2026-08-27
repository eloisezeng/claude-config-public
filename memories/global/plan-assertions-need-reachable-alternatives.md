---
name: plan-assertions-need-reachable-alternatives
description: An assertion is only worth the alternatives its fixture makes reachable — omit the competing index, or the second row, and the test can never fail
metadata:
  type: feedback
scope: global
---

A test that asserts "this query uses index X" proves nothing if the fixture created only index X. The planner had one reachable choice; the assertion passes vacuously and keeps passing while production — which carries more indexes — picks something else.

**Why:** 2026-08-10, your_other_project. The live dashboard hung for ~1.5h: unresponsive, 0 bytes for 120s, and unable to recover without a machine restart. The funnel's per-row `EXISTS` probe on `da_valuations` was routed to `idx_da_valuations_phase_created (phase, created_at)` — an index that cannot satisfy `domain_id = ?`, whose leading column matched 1,498,657 of 1,499,400 rows — so each of 117,560 cohort probes became a range walk. >70s and never finishing, versus 547ms pinned to `(phase, domain_id)`. `funnel.scale.test.ts` already EXPLAINed the byte-exact live query and asserted that access path, but its fixture created `idx_da_valuations_phase_domain` and **not** the competing index, so it was structurally incapable of failing. Adding the competing index to the fixture turned it red with the production plan reproduced byte-for-byte.

**How to apply:**
- Build plan-test fixtures from the **production index set**, not the indexes the query is supposed to use. The competing index is the whole point of the test.
- Assert the index **by name** and assert the wrong one is **absent**. A loose match (`/idx_valuations_phase_/`) passes on the very plan that causes the outage.
- Mutation-check it: remove the pin, confirm red, and read the failure message — it should quote the real bad plan.
- When a probe's correct plan actually matters, pin it (`INDEXED BY`) rather than trusting the planner. A missing index then fails loudly at prepare time instead of silently degrading.
- Check whether `ANALYZE` has ever run (`sqlite_stat1` present?). With no statistics the planner chooses on heuristics, so a plan can be wrong from the day a second index lands and only turn fatal much later as the data grows — the git blame will point at an innocent recent commit.
- Synchronous DB drivers (better-sqlite3) make this a total-outage class, not a slow-page class: one non-terminating query blocks the whole event loop, and a polled endpoint re-triggers it forever.

Related: [[self-referential-fixtures-pin-nothing]], [[verification-claims-are-earned-per-item]], [[scale-test-large-data-paths]], [[verify-claims-against-artifacts]].

## The same principle outside query plans: degenerate fixtures

The general rule is that a fixture must VARY the dimension the property is about. A fixture sitting at a degenerate point makes several independent properties unfalsifiable at once, and reads as coverage.

**Why:** your-research-project round 4, 2026-08-18. A function decomposing error energy by spatial bin had every test fixture built from a **single contributing row** with unit-valued statistics. That one degeneracy killed three unrelated assertions simultaneously: dividing by the row count was the identity, so the row AVERAGE was dead code and "shares sum to 1" could not fail; squaring a value of 1.0 equals not squaring it, so `abs(v)` and `v**1` both passed where `v**2` was the entire point of the function; and "rows are weighted equally" was a string in the output artifact with no property behind it. An independent mutation-hunting reviewer found all three from that one fixture defect.

**How to apply:**
- Name the property, then ask what the fixture would have to contain for the wrong implementation to give a different answer. If nothing in the fixture distinguishes them, the assertion is decorative.
- Degenerate values to distrust: n=1 (means, sums, and per-item weights all collapse), the value 1 (every exponent and every scale factor agree), 0 (absent and empty become indistinguishable), and identical items (any ordering or weighting passes).
- Assert an exact expected value, not an inequality — `share[0] < 0.1 < share[1]` survived a wrong weighting that an exact `0.8` would have caught.
- When a test's docstring claims a distinction ("absent must not collapse with zero"), check the fixture actually contains both cases distinguishably; see [[a-surviving-mutant-may-mean-the-property-is-unobservable]].
