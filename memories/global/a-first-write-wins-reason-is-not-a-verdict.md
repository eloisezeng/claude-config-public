---
name: a-first-write-wins-reason-is-not-a-verdict
description: A first-write-wins refusal reason records the gate that arrived first, not the reason the thing would have lost, so any reader treating one reason as "the only obstacle" trusts arrival order
metadata:
  type: feedback
scope: global
---

A rejection recorded by a first-write-wins `drop()`/`reject()`/`skip()` names **the gate that
reached the item first**, never the reason it would actually have lost by. So any downstream reader
that treats one particular reason as the strong claim "this was the ONLY thing in the way" is really
trusting the ORDER the gates ran in, and that order is usually an accident of the input.

Compute such a reason only after every gate has had its say, and make the deciding predicate
**shared with the live pass** rather than copied — a second copy of a tiebreak is a second answer
free to drift. Where a later gate is a CONTEST the item never entered, say so in the code and state
the bound that leaves open rather than inventing a verdict for it.

**Why:** the reader's claim is strictly stronger than what the writer recorded, and nothing in the
types, the tests or a reviewer starting from the symptom connects the two.

**How to apply:** when a reader branches on WHY something was refused, find the refusal's write site
and ask what else had not run yet. Then ask what makes the gates run in a different order — it is
usually a lifecycle difference, not bad data (a transcript arriving before a current-term grid
entry, a backfill before a live write, a cached item before a fresh one), which is exactly the axis
a fixture holding everything in one place cannot vary.

Two traps, both measured on one fix (your-university_scheduler, 2026-10-29):

1. The deciding question is **"would it have lost ANYWAY?"**, not "did a conflicting party win?".
   The first attempt asked the weaker one and broke the legitimate case, because a sibling usually
   holds the contested thing PRECISELY BECAUSE the first party was full — reading that as a refusal
   inverts cause and effect. A correct-looking fix reddening an existing test is evidence about the
   fix here, not about the test: the test was pinning the real requirement.
2. A test that holds every input in one place cannot see this class at all. The defect needed the
   filler on the transcript and the contested course in the current term; both on the transcript
   gave the right answer through three review rounds. The counter-party found in one round what the
   author could not construct in two — so hand a reviewer the ordering question explicitly and ask
   for the case you failed to build, naming the pass order and the first-write-wins rule.

[[unambiguous-status-and-logs]] · [[encode-the-invariant-in-the-shape-not-another-guard]]
