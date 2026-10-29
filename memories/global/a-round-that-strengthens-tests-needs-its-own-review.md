---
name: a-round-that-strengthens-tests-needs-its-own-review
description: A fix round that strengthens assertions is a change like any other — review it, and expect the new assertion to carry the same defect shape as the gap it closed
metadata:
  type: feedback
scope: global
---

A review round whose fixes are all in TESTS still ships new claims, so it gets its own round — and the defect you will find there is usually the SAME SHAPE as the gap being closed, because the author's attention was on the axis they were fixing and not on the operand beside it.

**Why:** measured on one arc's round 5, which read only the test-only diff of round 4's own fixes: 4 findings, and 3 of the 4 were holes in assertions round 4 had just added. Two of those three were the identical shape to the gap they closed —
a `source` sweep added to fix "only two of four values were ever passed" handed every swept source the same `alternatives: [{reqId:"b"}]`, so `remove: true` mutated to `!(source === 'current_term' && !alternatives.length)` survived all 40 assertions of three sections (and `CS 021` in the current term is exactly that state, so an in-progress course with nowhere else to go would have lost its control with the suite green); and a parser widened from "stop at the first blank line" to "stop at the next term or any `#`" still read `#1: A move can use…` as a heading, so a contradictory continuation cut the entry off exactly at the approved wording and the guard exited 0 — `[[a-fixture-helpers-default-pins-the-swept-axis]]` · `[[a-mention-is-not-a-property]]`.

**How to apply:** when a round's fixes are test-only, do not skip to the merge. Run ONE scoped counter-party read of the fix diff by a lens that filed none of those findings (not a fourth full panel), freeze the tree while it reads, and point it at the two questions that catch this class: *can each new assertion fail at all* (name a concrete implementation it rejects — comparing output against the input object usually cannot), and *what did the new case destroy for a later one* (a mid-section `page.reload()` wipes module state; the suite stays green and a later case goes vacuous). Add a mutant per finding and prove the kill, which is also how you learn the fix's own second-order defects — the reload that re-read a stored record cleared `openBreakdowns` and only the downstream throw revealed it.

Where the fix is a REWORDING, the position of the injected probe is the whole test: the same contradiction placed mid-definition truncates short of the approved text and the guard FAILS (looking fixed), while placed at the END of the definition — where a continuation naturally goes — it reads green. Put the control where the hole is, not merely somewhere the string appears — `[[absence-needs-a-probe-that-could-see-presence]]` · `[[a-region-that-finds-a-defect-every-round-is-a-design-not-a-bug]]`.
