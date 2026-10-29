---
name: a-region-that-finds-a-defect-every-round-is-a-design-not-a-bug
description: When every review round's findings land in one region, reshape the region instead of patching it again — and re-run the mutants a restructure invalidated
metadata:
  type: feedback
scope: global
---

A falling finding RATE can still mean the loop is not converging: ask WHERE each round's findings are, not
only how many there were. When round after round files against the same region, the remaining findings are
instances of one unsettled design, and the next patch mints the next round's finding.

Measured on the Change-menu arc: 19 findings, then 3, then 3 — and all three of round 3's were in one region,
the code that wrote the student's stored choices and certified which rule they were expressed in. Rounds 1, 2
and 3 each patched it: round 1 held the certificate back when the migration had not run, round 2 withheld the
data write when the notice write failed, round 3's panel then found that a half-landed save still certified a
state storage was not in, that a save after a failed migration reported SUCCESS while certifying nothing, and
that a restore reloaded on a partial write. Three patches, three rounds, one design.

Reshaping it closed all three at once and retired the class by construction — one `writeChoices()` writing
both data keys AND the certificate as a unit, a `saveChoices()` that refuses while the rule is unsettled, and
one named function for the single write allowed before it settles. The certificate had been its own callable
effect, which is what made "certify a state you did not write" expressible at all; after the reshape there is
no way to say it.

Two consequences at fix time:

**A restructure expires every label measured on the old shape.** Re-run the previous rounds' mutants against
the new one (round 2's two both still died, but that is a measurement, not an assumption), and expect a test
that drove a deleted symbol to need REWRITING, not keeping — one here asserted through `stampChoicesRule`,
which no longer exists, so it was rewritten to assert the property that replaced it.

**Do not commit while a panel is reading the tree.** Three of three lenses had their verdicts quarantined
across two rounds because HEAD moved under them mid-read, and one then filed nine findings against a commit
three fixes old, restating findings already fixed twice. Freeze the tree for the round, and read a quarantined
verdict as data only when it names the head it reproduced against.

Related: [[codex-parallel-lenses-beat-serial-rounds]] · [[encode-the-invariant-in-the-shape-not-another-guard]]
· [[verification-claims-are-earned-per-item]]
