---
name: a-gate-you-just-satisfied-may-have-siblings
description: when a gate rejects your input, enumerate every gate of the same SHAPE before paying for another round trip — the mechanism usually has siblings and they fail one at a time
metadata:
  type: feedback
scope: global
---

A gate that reads an input you control (a pull-request body, a commit trailer, a label, a config key) is rarely the only one of its shape, and the siblings fail STRICTLY ONE AT A TIME: the job stops at the first, so satisfying it merely buys the right to discover the next.
Each discovery costs a full round trip, and on a shared head each round trip is also a fresh event you may have to manufacture.

**Why:** the per-instance question "is this fix correct?" is blind to the class. Nothing in a failing step's output names its siblings, so the cost is invisible until you have already paid it twice.

**How to apply:** the moment a gate of this kind fires, grep the workflow (or the config loader) for the STEP SHAPE rather than the message — `grep -nE 'name: .*(Require|declaration)|run: node scripts/ci-.*line'` found both of this repo's in one command — and read the TEMPLATE or schema the gate cites, which enumerates the whole family in one place. Then satisfy all of them in one edit and fire one event.
Read each gate's acceptance set from the SCRIPT, not from its error message, and run the script locally against the exact bytes the consumer will see (the body read BACK from the API, not the one you typed) before spending the round trip.

Measured 2026-10-31 on `your-other-project` pull request #544: a predecessor found and fixed the `Repairs:` declaration and burned two attempts on it; the next attempt failed on `Require the Convergence declaration`, a byte-adjacent step 26 lines later in the same job, which the pull-request template had listed all along. One `grep` over the workflow proved those two are the only members, which is also what made the next fix final.

Related: [[fix-the-class-not-the-reported-instance]] · [[enumerate-recurring-defect-classes]] · [[enumerate-the-transforms-between-authoring-and-use]]
