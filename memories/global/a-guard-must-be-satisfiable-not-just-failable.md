---
name: a-guard-must-be-satisfiable-not-just-failable
description: A completeness guard whose right-hand side is a hand-named list can be UNSATISFIABLE — and an unsatisfiable guard gets widened by hand to go green, hiding the very thing it exists to catch
metadata:
  type: feedback
scope: global
---

`[[absence-needs-a-probe-that-could-see-presence]]` says prove your probe CAN FAIL.
This is its dual: **prove your guard CAN PASS.**
Before trusting any completeness/closure assertion, satisfy it by hand against the real artifact and count BOTH sides.

**Why.** A guard that cannot fail is silently vacuous; a guard that cannot be *satisfied* is worse, because it is never implemented as written.
The implementer meets an impossible right-hand side, widens it by hand to get green, and the widening restores exactly the drift the guard existed to stop.
Nobody records that the guard was weakened, because from the outside it still reads as a closed enumeration.

**Measured, 2026-08-28, Treecue phase-0 spec §6.2.**
The clause read: *a source scan asserts the exported function set of `agentActions.ts` equals these eight plus the unchanged exports named in §6.1, so a ninth converted helper cannot be added without a case here.*
That set does not exist — the file has **26 exports**, and **11 are named nowhere in §6.1**.
So the guard written to catch a ninth converted helper was **hiding the ninth converted helper** (`setAgentGate`, a direct map reader whose `?? []` path would have silently returned an empty gate map), for six review rounds, and no round reported it.
A peer lane found the missing member by enumerating the file; the unsatisfiability only surfaced when I tried to satisfy the clause myself.

**How to apply**
- For any assertion of the form `set(X) == <hand-named list>`, compute both sides against the real artifact before believing it. The count is the check — "these eight plus the ones named above" is not a set until you evaluate it.
- Replace restatement with **derivation**: define the set by a predicate over the artifact (every exported function whose first parameter is the map; every caller of the gate), then assert driven-equals-derived in **BOTH directions**. One direction catches a new member added with no case; the other catches a member dropped.
- Derivation moves the drift, it does not delete it — so **state the bound in the clause**. A type-level derivation still admits a member that takes the argument and ignores it; say which other assertion covers that, and that the two are load-bearing only together.
- A hand-named list inside a guard is the same open-enumeration failure as a hand-named list inside a claim — see `[[fix-the-class-not-the-reported-instance]]` and `[[enumerate-recurring-defect-classes]]`. The guard is just where it is hardest to see, because the guard is what you were trusting.
- When a peer reports one missing member, fix the member AND ask why the closure guard did not catch it. The answer is the real finding.
