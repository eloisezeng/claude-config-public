---
name: run-the-reproduction-against-the-parent-too
description: a reviewer's reproduction run only at HEAD is a finding; run it at the PARENT too and it becomes a regression with a direction — and after a refactor, re-check that your old mutants still ARM
metadata:
  type: feedback
scope: global
---

A review finding comes with a reproduction at HEAD. Run that same reproduction
against the PARENT commit before acting: HEAD alone tells you the code is wrong,
HEAD-vs-parent tells you whether YOUR change broke it and in which direction.
The direction decides the fix and the severity — a lost true positive and a
gained false positive read identically in a finding body and are different
defects. It also catches the reviewer who has described a pre-existing bound as
a new one.

The same "re-measure against changed code" applies to a mutant battery carried
across a refactor. An anchor that no longer matches reports MISARMED, which is
NOT a SURVIVED and is not a verdict at all — and an anchor that now matches
TWICE is itself a finding: the refactor added a second site with the same shape,
and each site needs its own mutant. Re-point them per site and name which
assertion kills each.

**Why:** measured 2026-10-14. Two confirming-round findings, both reproduced at
HEAD, became "lost a true positive" (1 problem → 0) and "gained a false
positive" (0 → 1) only once the parent was measured. In the same round a mutant
came back MISARMED because the file had been rewritten; its anchor now matched
two sites, and splitting it found two untested properties at the new one, both
of which then survived their first mutants.

**How to apply:** keep the reproduction script as a file and run it against both
shas; after any refactor, read every mutant's armed/MISARMED line before reading
its verdict. See [[a-mutant-must-arm-where-the-consumer-reads]] ·
[[verify-claims-against-artifacts]].
