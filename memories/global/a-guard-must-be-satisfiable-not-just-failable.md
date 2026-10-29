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

**Measured, 2026-08-28, your-module phase-0 spec §6.2.**
The clause read: *a source scan asserts the exported function set of `agentActions.ts` equals these eight plus the unchanged exports named in §6.1, so a ninth converted helper cannot be added without a case here.*
That set does not exist — the file has **26 exports**, and **11 are named nowhere in §6.1**.
So the guard written to catch a ninth converted helper was **hiding the ninth converted helper** (`setAgentGate`, a direct map reader whose `?? []` path would have silently returned an empty gate map), for six review rounds, and no round reported it.
A peer lane found the missing member by enumerating the file; the unsatisfiability only surfaced when I tried to satisfy the clause myself.

**How to apply**
- For any assertion of the form `set(X) == <hand-named list>`, compute both sides against the real artifact before believing it. The count is the check — "these eight plus the ones named above" is not a set until you evaluate it.
- Replace restatement with **derivation**: define the set by a predicate over the artifact (every exported function whose first parameter is the map; every caller of the gate), then assert driven-equals-derived in **BOTH directions**. One direction catches a new member added with no case; the other catches a member dropped.
- Derivation moves the drift, it does not delete it — so **state the bound in the clause**. A type-level derivation still admits a member that takes the argument and ignores it; say which other assertion covers that, and that the two are load-bearing only together.
- A hand-named list inside a guard is the same open-enumeration failure as a hand-named list inside a claim — see `[[fix-the-class-not-the-reported-instance]]` and `[[enumerate-recurring-defect-classes]]`. The guard is just where it is hardest to see, because the guard is what you were trusting.
- **Measure the invariant's POPULATION before you write it as an assertion**, and when it comes back unsatisfiable, look for the satisfiable CONJUNCTION rather than widening it or bolting an exemption on. Measured 2026-09-24: "the option's catalog page names every course this requirement references" read **262** violations, for three reasons that were not defects — a page need not restate an Institute-wide equivalence, a requirement may name courses documented on another option's page, and some rows come from a different artifact entirely (PDFs the page never mentions). Conjoining it with "and no course in the course listings matches it either" read **0** over 1830 references, and means exactly the thing worth asserting: we point at something that has left BOTH sources. The unsatisfiable version would have been widened by hand within a round.
- **Before building an exemption mechanism, check whether the SYSTEM'S OWN equivalence rule already discharges the case.** I was handed a design for a per-requirement `catalogSpelling` map to excuse a catalog typo (`EE/MedD 114` for `EE/MedE 114`). Reading the page under the rule the *matcher* already uses — department sets need only INTERSECT — discharged it for free, because `{EE, MedE}` still meets `{EE, MedD}` at `EE`. No map, no exemption list, and one fewer rule in the system. An exemption is a second rule about the same facts; ask what the first rule says before adding it.
- When a peer reports one missing member, fix the member AND ask why the closure guard did not catch it. The answer is the real finding.
- **A safety gate must ask its REAL question, not a proxy for it.** A cheap, precise-looking comparison substituted for the actual predicate refuses correct work and reads as rigour while doing so. Measured 2026-09-17: an archive gate compared CONTENT HASHES where the question it existed to answer was whether a NAME was absent, so it refused a safe move over five files a merge had legitimately rewritten — every one of them a true negative for the real question and a true positive for the proxy. Write the question the gate answers in one line ABOVE the comparison, then check that the comparison decides exactly that question; where they differ, the proxy is the defect, not the data. A proxy is also the shape `[[a-mention-is-not-a-property]]` describes, one level up: a property tested through a stand-in is not the property.
