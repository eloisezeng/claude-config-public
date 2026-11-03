---
name: greedy-over-overlapping-allowances-is-not-monotone
description: spending overlapping caps/quotas item by item in arrival order can REDUCE the total when an item is added — allocate jointly, prove the property, and make the unproven shape impossible
metadata:
  type: feedback
scope: global
---

Whenever two ceilings can bind the SAME item — "at most 9 units below 100" beside "at most 18 units
from this named list", two budgets over one line item, two rate limits over one request class — a
per-item greedy in arrival order is NOT monotone: adding an eligible item can make the total SMALLER.
Measured 2026-10-29 in your-university_scheduler: a completed `Ph 12c` (in both ceilings) reached the row
first, took the whole 9-unit sub-100 allowance that `EE 001` would have used and 9 of the 18, and the
student's credited units dropped 54 -> 45 for having taken one more eligible course. The consumption
rule was right (an item in two ceilings spends BOTH — they describe one set of credited units from
two angles); only the CHOICE of which item gets the units was wrong, and no single-ceiling test can
see it, because with disjoint ceilings arrival order is already maximal.

**How to fix it.** Name the property first and in the imperative — *adding an eligible item can
never reduce the total* — then make it a pure function over (candidates, caps) so it is
property-testable, and test it against an EXHAUSTIVE-SEARCH ORACLE that shares no code with it, for
three things at once: feasibility, maximality, and monotonicity under dropping each candidate in
turn. Monotonicity is a corollary of maximality (any allocation of a smaller candidate set is still
available to the larger one with the new item at zero), so proving the maximum is what buys the
property. Generate fixtures that force at least one item into two ceilings — a one-ceiling-per-item
generator cannot tell greedy from joint at all.

**State the bound your proof leaves open, and then make it impossible rather than loud.**
Fewest-ceilings-first (ties by arrival) IS the maximum while every connected component of the
cap-overlap graph holds at most TWO caps: moving a unit from a two-cap item to a one-cap item costs
the shared cap nothing and gives the other cap a unit back. It is NOT the maximum for three caps
overlapping pairwise (give each cap 2 units and one 2-unit item per pair: 3 admissible, the rule
finds 2) — so assert that counterexample as a FACT in the test, and add a guard that refuses the
shape in authored DATA, asked through the production predicates so the two rules cannot drift. An
allocator that is quietly non-maximal on a row someone adds next year shows up only as a user losing
credit for doing more work, and shows up nowhere else.

**Lookahead is unavoidable, so buy it without disturbing the pass.** The joint answer needs the whole
candidate set, which an incremental crediting pass does not have. Keep the old greedy answer DURING
the pass so every occupancy read downstream sees exactly what it saw before, record each candidate
with the position its entry would have taken (including the ones greedy refused — finding room for
them is the point), and settle once at a point where no further candidate can arrive, walking
BACKWARDS so an insertion cannot move an earlier recorded position. Route only the rows that need it
(6 of 46 here); the rest keep a byte-identical path, which is the whole blast-radius argument.

Related: [[encode-the-invariant-in-the-shape-not-another-guard]] ·
[[a-guard-must-be-satisfiable-not-just-failable]] · [[plan-assertions-need-reachable-alternatives]] ·
[[close-the-reviewed-head-gate-by-measuring-identity]]
