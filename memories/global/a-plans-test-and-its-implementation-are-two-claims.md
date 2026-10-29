---
name: a-plans-test-and-its-implementation-are-two-claims
description: "When executing a plan that ships both test code and implementation code: the two are separate claims that can disagree, and the disagreement is a finding about the PLAN to be adjudicated on what the product needs — never resolved by preferring whichever side you typed first"
metadata:
  node_type: memory
  type: feedback
  scope: global
  originSessionId: 1f31cb2a-63a9-4d07-83f6-fbee394fef79
  modified: 2026-10-07T18:40:59.886Z
---

A plan that carries both the test and the implementation for a task carries TWO claims about one behaviour, written at different moments, and nothing ever ran them against each other.
Expect them to disagree, and expect the disagreement to surface as a red test on correct code — which is the one shape most likely to be "fixed" by quietly bending whichever side is in front of you.

**Why:** the author's own review rounds read the plan as prose, so a numeric disagreement between its test block and its code block is invisible there; it becomes observable only at execution, and by then the plan looks converged, which is a strong attractor for conforming the code to the document.
Measured on one 20-task plan: 3 of the first 5 tasks had such a contradiction, and in two of them the plan's TEST was the defective side.
Twice the plan's test contradicted assertions elsewhere in the same test file, so the file disagreed with itself.
Once the plan's parser would have failed a row of its own spec's contract table outright, because it assumed raw text where the platform normalises first.

**How to apply:**

- Run the task's test against the task's implementation EXACTLY as the plan wrote both, before editing either. A red here is data, not an obstacle.
- Adjudicate on what the PRODUCT needs, in writing, and say which side you kept. A `remaining` that excludes the admission just granted shows a visitor "1 left" immediately after their last brief; that settles it without appealing to authorship.
- Look for a tiebreak inside the file first: a contradiction usually has a majority. Four assertions demanded one reading and two the other, which named the defective pair rather than leaving it to taste.
- Expect a finding's own fix not to have been propagated into the sibling tasks' tests. A split between a parser and a policy was folded into the task that created it and left wrong in the two tasks that consume it.
- Pin the adjudicated semantics with a NEW test that states it directly, plus a mutant that restores the other reading, so the next reader cannot re-decide it. Then record the deviation where the next session will read it: the plan still says the old thing, and `[[re-read-cannot-tell-wrong-from-acted-on]]` applies to whoever reads it next.
- A plan's performance shape is a claim too. Replacing it is allowed when verification goes UP, never down: keep every anchor the plan specified and add the property sweep that makes the replacement trustworthy.

