---
name: a-strengthened-assertion-needs-its-own-mutant
description: A test strengthened in answer to a review finding is a NEW claim and needs its own mutant; in a UI a second mechanism often clears the state, so the obvious assertion pins nothing
metadata:
  type: feedback
scope: global
---

When a review says a test is weak, the fix is a new CLAIM and carries the same risk as the old one.
Arm a mutant against the strengthened assertion specifically — not the defect's mutant, which the
old test probably already caught, but one that removes exactly the behaviour the NEW line claims to
pin. State in the test which mutants it kills and which it does not.

**Why:** in a UI, outcome state is usually reachable by more than one route, so an assertion about
the outcome cannot see the step you believe it proves. Measured on one arc: a review found an
expiry test accepted a state a missing reset would produce, so I asserted the input was empty and
the table gone before any reload, and wrote in the comment that this pinned the live reset. Three
mutants through the real build said otherwise — removing the write-time guard (the original defect)
was KILLED, while removing the reset's live-state calls SURVIVED, and so did removing its store
cleanup. A diagnostic explained it: when the session expired the page also flipped to its
signed-out branch, which unmounts the populated form and mounts an empty one, and the re-visit path
reset the draft behind it. Each half of the effect was redundant given the guard, and no outcome
assertion could distinguish them.

**How to apply:** mutate through the artifact the test actually drives — for a browser test that
means rebuilding, which is the cost of the answer and cheaper than a false claim. Mutate each HALF
of a multi-call effect separately, since a pair that both produce the end state makes either one
individually invisible. When a mutant survives, run a REPORTING diagnostic (print the live state
and the stored state) under that mutant rather than theorising about why, and read the answer as
telling you which mechanism is load-bearing. Then keep the redundant calls if they are cheap, say
in a comment that they are defence in depth and that their removal is not observable, and correct
the overstated claim in place. Never delete an outcome assertion that survived a mutant: it still
documents the user-visible result and catches a different future regression.

Related: [[a-surviving-mutant-may-mean-the-property-is-unobservable]],
[[a-mutant-must-arm-where-the-consumer-reads]], [[verify-in-the-consumers-condition]],
[[an-owner-stamp-needs-a-writer-gate-and-a-transition-reset]].
