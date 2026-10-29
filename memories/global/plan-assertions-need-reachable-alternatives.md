---
name: plan-assertions-need-reachable-alternatives
description: An assertion is only worth the alternatives its fixture makes reachable — omit the competing index, sit on a degenerate value, or give two candidate SOURCES the same value, and the test can never fail
metadata:
  type: feedback
scope: global
---

A test that asserts "this query uses index X" proves nothing if the fixture created only index X. The planner had one reachable choice; the assertion passes vacuously and keeps passing while production — which carries more indexes — picks something else.

**Why:** 2026-08-10, your-other-project. The live dashboard hung for ~1.5h: unresponsive, 0 bytes for 120s, and unable to recover without a machine restart. The funnel's per-row `EXISTS` probe on `dp_valuations` was routed to `idx_dp_valuations_phase_created (phase, created_at)` — an index that cannot satisfy `domain_id = ?`, whose leading column matched 1,498,657 of 1,499,400 rows — so each of 117,560 cohort probes became a range walk. >70s and never finishing, versus 547ms pinned to `(phase, domain_id)`. `funnel.scale.test.ts` already EXPLAINed the byte-exact live query and asserted that access path, but its fixture created `idx_dp_valuations_phase_domain` and **not** the competing index, so it was structurally incapable of failing. Adding the competing index to the fixture turned it red with the production plan reproduced byte-for-byte.

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

**Why:** MFFP round 4, 2026-08-18. A function decomposing error energy by spatial bin had every test fixture built from a **single contributing row** with unit-valued statistics. That one degeneracy killed three unrelated assertions simultaneously: dividing by the row count was the identity, so the row AVERAGE was dead code and "shares sum to 1" could not fail; squaring a value of 1.0 equals not squaring it, so `abs(v)` and `v**1` both passed where `v**2` was the entire point of the function; and "rows are weighted equally" was a string in the output artifact with no property behind it. An independent mutation-hunting reviewer found all three from that one fixture defect.

**How to apply:**
- Name the property, then ask what the fixture would have to contain for the wrong implementation to give a different answer. If nothing in the fixture distinguishes them, the assertion is decorative.
- Degenerate values to distrust: n=1 (means, sums, and per-item weights all collapse), the value 1 (every exponent and every scale factor agree), 0 (absent and empty become indistinguishable), and identical items (any ordering or weighting passes).
- **The dimension is sometimes PROVENANCE, not magnitude.** When the code chooses between two candidate SOURCES for a value — this frame's reading vs. the previous frame's stored one, the request's header vs. the session's, the override vs. the default — a fixture that gives both sources the same value makes "which one did it read?" unobservable, and the test pins only that *something* was read. Give every candidate source a DIFFERENT value, and where the answer must survive a later change, a third value at the end so the wrong two both fail. Measured 2026-09-01 on a video-seek handle: four tests pinned how a pending seek is priced, but each gave the seek's own issue-time snapshot the same rate, rolling flag and clock as the previous frame's, so three mutations swapping one source for the other all SURVIVED. Rewritten to issue at 0.5x, store 2x, and end at 0.5x again, they killed every one.
- **A TIE-BREAK test must reach the tie by UNEQUAL operands.** When the property is "what happens when two candidates are equal", identical operands are not merely a degenerate point — they are the one case where a WRONG implementation is accidentally right, because two bit-identical derivations compare exactly equal and the tie-break fires correctly. Build the tie from operands that differ everywhere except in the quantity being tied. Measured 2026-10-04, job_hunt: an audit allocator documented "equal remainders go in declaration order" compared `exact[i] - whole[i]`, a float minus a non-zero integer, which loses low-order bits by a different amount per operand — so equal remainders compare UNEQUAL whenever the integer parts differ. My fixture `[11,45,45,0,0]` tied two reasons at EQUAL SPARE (35/35), making their floats bit-identical, so it passed, and so did every mutant I armed against it (reversing the index clause and `floor`→`round` both died, which read as coverage). An independent reviewer reached the same tie at unequal spare, `{10,10,11,15,59}`, and the documented order lost. Rank on the INTEGER remainder (`(budget * spare[i]) % totalSpare`) so the comparison is exact by construction rather than by luck of the fixture.
- Assert an exact expected value, not an inequality — `share[0] < 0.1 < share[1]` survived a wrong weighting that an exact `0.8` would have caught.
- When a test's docstring claims a distinction ("absent must not collapse with zero"), check the fixture actually contains both cases distinguishably; see [[a-surviving-mutant-may-mean-the-property-is-unobservable]].

## The live distribution decides which cases a fixture must contain

A fixture built from the case the author had in mind tests the case the author had in mind.
Once the share of live items carrying a value is MEASURED (question 1 of [[answer-five-written-questions-before-implementing]]), that measurement is the fixture's contract: the test must contain the case that is common live, and it may not hand-write the rare value that unlocks the behaviour under test.

**Why:** 2026-09-11, your-other-project. A short `.org`/`.net` purchase check required a stored company match; live, 0 of 271 stored checks carried one, so the check refused every purchase. Its tests hand-inserted that match into the fixture at three separate call sites — the helper's own comment called it "the only state that lets a gated name buy" — so the suite exercised the 0%-of-live case and never the 100% one. Across the 40 classified post-merge repairs of the preceding month, 4 were exactly this shape and 23 were confirmed not to be.

**How to apply:**
- Hand-writing a stored value into a fixture is allowed only when the test also drives the real WRITER of that value somewhere, or when a sibling test covers the absent case as the default.
- State the measured share in the test name or a comment next to the fixture ("0 of 271 live checks carry this"), so the next reader sees the distribution rather than re-deriving it.
- The common case is usually the ABSENT one, which is why it gets skipped: nobody writes a fixture to express that a field is missing.

## Pinning a DECLINED finding: the fixture must hold the disputed case

When a reviewer's finding is answered by adjudication rather than by a code change — "these two gates read ONE bucket on purpose; here is a test that pins them together" — the pinning test inherits this whole class, and in its sharpest form. A fixture built from the ORDINARY case makes both the shipped reading and the rejected one answer identically, so the assertion pins the agreement and says nothing about the ruling. It then reads as the strongest kind of evidence: a test written specifically to hold the disputed decision.

**Why:** 2026-10-14, your-university_scheduler PR #80. A lifecycle lens reported that a course in the term IN PROGRESS satisfies a requirement's completed-only catalog rule. Declined deliberately — the row's own unit gate counts exactly that bucket, so a stricter rule would give one row two answers — and pinned with a test reading both sets from one crediting pass. The fixture held nothing but transcript courses, where a transcript-only implementation answers identically, so it could not fail. A scoped micro-review of the fix commit caught it. Driving the real case took three corrections that each passed for the wrong reason first: the course had to be DERIVED from live data (one not offered this term is dropped before any of it is reached), it had to be the LAST one filling the row rather than one on top (a full row turns an incoming course away), and the block had to sit outside the section whose page state the following assertions read. Only then did a `transcript-only` mutant die.

**How to apply:**
- Write the mutant BEFORE the assertion: implement the reading you rejected and require it to fail. An adjudication with no surviving-alternative mutant is prose.
- Build the fixture from the disputed case, not from the case that made the ruling obvious.
- Expect a fixture for a disputed case to need several corrections, each one green and wrong: an element silently dropped upstream, a quantity that lands in a different bucket than intended, state left over from the previous case. Read every unexpected PASS as a fixture defect until proven otherwise.
- Hand the micro-review of a fix commit the ruling in words. The finding it returns about your own pinning test is worth more than the round that produced the ruling.
