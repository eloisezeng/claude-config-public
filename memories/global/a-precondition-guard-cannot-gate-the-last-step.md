---
name: a-precondition-guard-cannot-gate-the-last-step
description: A guard written as a precondition of the NEXT step gates every step except the last one — and the last step is usually where the claim gets made, so the guard is absent exactly where it mattered
metadata:
  type: feedback
scope: global
---

A guard phrased "you may not START N+1 while N is open" gates N, N-1 and every earlier step, and it
is ABSENT at the final step, because no N+1 is ever requested there.
The final step is normally the one that makes the claim — declares convergence, publishes the
result, ships the artifact, closes the ticket — so the guard is missing at precisely the point its
whole purpose was to protect.
Nothing about the guard looks wrong; it fires correctly, repeatedly, on every step but one.

**Why:** the enforcement rides on an EVENT (a launch) rather than on the ASSERTION (the result).
A session that stops after the last round emits no further event, so there is nothing left to
refuse.
Measured 2026-10-28: one arc's launch gate held every round open-to-closed correctly and the arc
still declared convergence, merged and deployed with **60 of its 80 ledgered findings carrying no
recorded outcome**, because declaring was not a launch.
The same arc exposed the companion shape: a verdict file that never entered the ledger at all is
invisible to every ledger-reading gate, since absence has no event either.

**How to apply:** gate the DECLARATION, not the next launch — make the artifact that the downstream
consumer requires obtainable only by closing everything, so the refusal lands on the one act that
cannot be skipped.
Ask of any precondition guard: *which step has no successor, and what does that step assert?*
Then check the asserting step reads the same predicate.
Where the consumer is a merge or a deploy, the declaration belongs where that consumer can see it
(a required body line validated by an existing context, never a new required check name —
`[[merging-is-restarting-production]]`), and the validator must recompute from the world what the
artifact claims, because a gate may not read its verdict from the gated party —
`[[a-gate-may-not-read-its-verdict-from-the-gated-party]]`.
Expect the first change under the new gate to be the one change the gate cannot have been applied
to, and say so in that change rather than quietly exempting it —
`[[enumerate-the-transforms-between-authoring-and-use]]` is the same "prevention is one increment
late" shape.
