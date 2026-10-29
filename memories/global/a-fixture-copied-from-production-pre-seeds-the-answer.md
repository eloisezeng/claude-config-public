---
name: a-fixture-copied-from-production-pre-seeds-the-answer
description: A check that copies live state as its fixture and compares it against that same live state cannot fail; strip the field under test out of the copy first, and require the change's own write artifact
scope: global
metadata:
  type: feedback
---

When a check verifies that some step PRODUCES a value, the fixture it runs against must not already contain that value.
Copying the live store — the obvious, careful-looking move, and the one that keeps the fixture realistic — pre-seeds the expected answer, so the comparison is satisfied by the copy rather than by the step.
Strip the field under test out of the copy to a VALID absent state before running the step, assert the stripped copy FAILS the comparison as a positive control, and separately require the step's own write artifact (the run record, the row, the receipt) to exist afterwards and name what it did.

**Why:** a done-check for "every stored score re-derives from its own judgment" copied the live store, re-scored the copy, and compared the copy against the live store.
The live store's scores were already correct, so a re-score that exited 0 having read nothing, written nothing and published nothing left every row matching — and the check printed `36 scored rows re-derived through the real re-score of practice-3, practice-5 and every total and component matches` either way.
Proved by replacing the invocation with `node -e '0;'`: it passed, with that same sentence.
The check had been deliberately written BEFORE the implementation, reviewed, and was the one check the whole objective turned on.

The same hole has a second mouth: the step's run id was a fixed sentinel and the child's output was discarded, so a copy already holding that record short-circuited on the restart preamble and exited 0.
A fixed id plus a discarded exit is the no-op's other route in.

**How to apply:** three moves, and the first alone is not enough.
Strip the field (`overallScore`/`componentScores` → the store's own `unknown` sentinel, which is a valid unscored row and not a corrupt one, so the step treats it as work to do).
Assert the stripped fixture holds zero of what you are about to count, as the control that the comparison can fail at all — without it the strip can be neutered later and nothing says so.
Require the artifact: the record must exist, carry the exact ordered inputs it claims to have consumed, and its own snapshot must describe what it wrote.
A value that happens to be right is never evidence that THIS run produced it.

This is the fixture-side twin of [[a-gate-may-not-read-its-verdict-from-the-gated-party]]: there the gate read its flag from the gated artifact, here the gate read its expected OUTPUT from a copy of the already-correct world.
It is also the general form of the note in [[an-exclusion-set-must-not-include-the-catch-all]] — a real record is late-stage and reads green, so a constructed fixture must sit EARLIER in the lifecycle, and that earliness is the point rather than a loss of realism.
Related: [[verify-claims-against-artifacts]], [[absence-needs-a-probe-that-could-see-presence]].
