---
name: triage-review-findings-by-intersecting-cited-lines-with-the-diff
description: Separate a review round's in-scope findings from pre-existing ones mechanically — intersect each finding's cited line range with the diff's changed lines — before reading a single body, because an uncalibrated lens reports both at the same severity
scope: global
metadata:
  type: feedback
---

A review lens asked to check neighbouring code *will* report defects in code the change never touched, at the same severity as the change's own.
Those are real findings and they are not merge blockers: fixing them widens the diff and re-opens the whole range for review.

Triage before reading any body.
Derive the set of lines the change altered from the diff's own hunk headers — `git diff -U0 BASE HEAD -- <file>`, each `@@ -… +start,count @@` expanding to `range(start, start+count)` at HEAD numbering — and intersect it with each finding's `line_start..line_end`.
An empty intersection is pre-existing; report the overlap as a count (`15 of 15 cited lines changed here` is this change's own new code, `2 of 168` is a finding about a neighbour that brushes it).
Then read only the in-scope bodies, and file the rest as one lane naming each by row and cited line.

**Why:** round 1 of PR 76's panel in `your-university_scheduler` returned 12 requirement-data findings, every one `high` at confidence 0.98–0.99 — a severity distribution that is itself the tell that a lens is not calibrated. The intersection split them 3 in-scope / 9 pre-existing in one command, and the three included the one whose cited lines were 15 of 15 the change's own. Reading twelve bodies first would have cost the same work and produced the same three.

Two cautions this does not remove.
A pre-existing finding the change made ANSWERABLE still belongs in the lane with that note — PR 76 added three historical catalog snapshots, which is the only reason anyone could see that one major's old-year students read today's rules.
And the intersection decides SCOPE, never TRUTH: reproduce every in-scope claim before acting on it, since that same uncalibrated lens also called three settled, already-correct rows defects at 0.99.

Related: `[[codex-parallel-lenses-beat-serial-rounds]]`, `[[verify-claims-against-artifacts]]`, `[[ops-lane-ledger]]`.
