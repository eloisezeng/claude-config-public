---
name: wall-clock-ceilings-measure-the-machine
description: "A test asserting elapsed < a constant measures the MACHINE, not the code — replace it with a ratio against an in-process calibration phase, and measure the sensitivity you actually bought"
metadata:
  type: feedback
scope: global
---

`expect(elapsedMs).toBeLessThan(1500)` is not a performance assertion. It is a race between your code and whatever else the box is doing, and the comment next to it ("generous CI headroom") is a guess nobody measured under the condition the test actually runs in — inside the full suite, on a loaded machine, next to N other workers.

Replace the constant with a **ratio against a calibration phase the test already performs in the same process**: these tests almost always seed their own N rows immediately before the timed call, so time that seeding and assert `expect(ms).toBeLessThan(insertMs)`. Both halves see the same CPU, the same contention, the same thermal state, so the ratio is load-invariant where either absolute number is not.

**Why:** on 2026-08-20 a `< 1500` ledger-scale budget went red inside a 709-file suite and green alone, blocking an unrelated branch's merge. Measured on one box with the code unchanged: **395–446 ms run alone, 1093–1174 ms alone on a busier box, 1636 ms inside the full suite** — a 4.1× swing. The healthy implementation spans both sides of the line, so the assertion's verdict was decided by load. The ratio replacement measured **0.21–0.38** across that same swing.

**How to apply:**
- Assert the ratio, and **measure the sensitivity you bought** rather than claiming one. For the case above: 2× and 3× regressions stay green, **5× turns it red**. Say that in the test's comment. A tighter multiplier is only safe if the healthy ratio's spread leaves room — 0.21–0.38 does not.
- Keep the structural half of the test, which is what actually pins the property: query count, `EXPLAIN QUERY PLAN` naming the index by name, `not.toContain('SCAN <table>')`. The timing half is a smoke check; the plan assertion is the contract — see `[[plan-assertions-need-reachable-alternatives]]`.
- **A ceiling fails in TWO directions, and the loose one is worse because nothing ever shows it to you.** A ceiling that is too tight flakes, which is at least visible; a ceiling that is too loose is an ABSENT test wearing a passing one's clothes. Measured across 43 assertions in one repository — 29 absolute millisecond ceilings, 5 already ratio-based, 9 semantic freshness bounds — one asserted that a 3.1 ms operation completes under 15,000 ms, so a genuinely quadratic implementation at N=5000 still passes it. When you zero the ceilings, record the RATIO of the ceiling to the measured time as well as the raw elapsed, and treat anything above roughly 100x as unsatisfiable rather than generous.
- **Enumerate the class before you fix instances** — `[[enumerate-recurring-defect-classes]]`. Measure every site by temporarily setting its ceiling to `0` so the assertion prints its own elapsed time (this also proves none is vacuous), then classify BOTH ends — too tight and too loose — three ways: same defect (fix), same shape but large measured headroom (leave, with the number recorded), and not this defect at all (a product deadline under a pinned clock, a freshness bound on a stored timestamp — those are `[[pin-the-clock-in-clock-dependent-tests]]` territory, not this).
- Headroom is judged against the **measured** load multiplier, not a feeling: 23 sites, 3 fixed, 21 left at ≥12× against a measured 4.1× multiplier. Converting 21 unrelated files inside a branch at its final review panel trades a measured, bounded risk for an unmeasured one — record the table instead, and say plainly you cured the instance and not the class.
- A red bar is a red merge whether or not the red is yours: fix the flake in your path rather than re-running it — `[[feedback-fix-dont-just-note]]`.
