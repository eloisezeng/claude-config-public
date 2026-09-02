---
name: a-fixture-helpers-default-pins-the-swept-axis
description: A fixture helper's DEFAULT argument silently pins the very axis a "we sweep the product" test believes it varies — sweep from the helper's call site, and prove it by mutating only the pinned value
metadata:
  type: feedback
scope: global
---

A test that loops over one axis while a fixture **helper's default** supplies the other is not testing a product — it is testing a line. The loop is visible and reads as thorough; the default is invisible and is where the hole lives. This is the sibling of [[plan-assertions-need-reachable-alternatives]]: there the competing alternative was absent from the fixture *set*, here it is present in the domain but unreachable because a default argument never let a call site name it.

**Why:** 2026-09-01, the beat-grid work in the your-project repo. `gestureDisposition`'s ownership is the PAIR `(instanceId, control)`. The test file looped over every receiving control and read as a full sweep — but the fixture builder `gesture()` defaults `control: "offset"`, and the one cross-mount case never overrode it, so **no test in the file ever had a live FOREIGN `scale` or `latency`**. A reviewer's mutant restricting cross-mount takeover to a live `offset` drag SURVIVED all 18 tests. A negative control (removing takeover outright) was KILLED by a named test, proving the harness was wired and the survival was the fixture's fault, not the runner's. Reviewing the whole product found two more axes pinned the same way (`draftOpen` on the pointerdown row, the clause tuple on the mismatched close rows) and a fourth site whose oracle passed `g?.control ?? "offset"` as the receiver — resolving ownership by instance alone, and right only because the mismatch could never occur. Four holes, one shape, none visible in the loops.

**How to apply:**
- Sweep from the **call site**, not from the helper. Every operand the function reads gets a loop; a default is a pin until a test names it.
- **A row that IGNORES an operand is the reason to sweep it, not a licence to pin it.** The property is "the answer does not move", and a fixture holding the operand still cannot assert that.
- The one honest exception is an operand whose answer genuinely *does* move: sweeping it would force the fixture to restate the rule under test. Keep that as a single-tuple sentinel, say so in a comment, and pin its behaviour in its own rows.
- Enumerate the class before fixing: ask which *other* fixtures in the file resolve an operand by default or by `?? <literal>`, and grep for that shape. Three of the four sites here were found by asking, not by being reported.
- Verify per item, never per round: after the fix, every mutant must be KILLED and **attributed to exactly one named test**. A mutant killed by "the suite" tells you nothing about which axis now has coverage.
- Correct the spec's pinning claim in the SAME commit — a document saying "five mutants across three rows" while the code pins eleven across four is the next round's finding.
