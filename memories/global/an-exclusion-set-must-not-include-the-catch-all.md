---
name: an-exclusion-set-must-not-include-the-catch-all
description: a guard asking "is this already handled elsewhere?" must exclude the catch-all bucket that handles everything by construction, or it answers yes for every input until the catch-all saturates — and a fixture copied from a real, near-complete record is saturated, so it reads green
metadata:
  type: feedback
scope: global
---

A guard of the shape "skip anything something else is already handling" is built by unioning
what every handler holds. If one of those handlers is a CATCH-ALL — a total, a general bucket,
a default route, an `else` branch, "any class counts" — then the union contains every input by
construction and the guard is a tautology that skips everything.

It does not read as a tautology, because the catch-all usually has a CAPACITY. While it has
room it swallows every input and the guard returns nothing; once it SATURATES, inputs start
falling out of it and the guard suddenly starts working. So the feature is live exactly for the
subjects who no longer need it and dead for everyone it was written for.

**Measured** (your-university_scheduler, 2026-09-24): `unlistedOptionCourses` listed the courses only
the option representative can approve, skipping any course something was "already crediting" —
computed over every requirement including `general_units`, the 486-unit graduation total whose
own note reads "Any class counts — music, art, language, PE". The list was therefore empty for
every student still short of 486 units: everyone who could still go and ask. Same fixture, one
line apart: `[]` before the skip, `["ME/CE/AM 295"]` after.

**Why it survived three review rounds and a green CI:** the test drove the author's OWN exported
record, and a real record is late-stage and therefore saturated — her total was past 486u, the
planned course fell out of it, the assertion passed. Swapping in a constructed fixture moved the
subject EARLIER in its lifecycle, and the defect appeared on the first run.

So, two rules:

- When you write or review a "something else has this" guard, NAME the handlers it unions over
  and strike the catch-all by id, the way the code's own attribution pass already does. A
  handler that accepts everything is never evidence that an input has a home.
- When you replace a real record with a constructed fixture, expect the fixture to sit earlier
  in the lifecycle than the record did, and treat that as the POINT rather than a shortcoming —
  that gap is where the saturation-hidden defects live. Build the fixture at the stage the
  feature is FOR, not at the stage the sample happened to be at.

The honest assertion afterwards splits in two and asserts BOTH sides, which is strictly more
than the saturated one said: the input credits no NAMED handler, AND it does reach the catch-all.

Related: [[plan-assertions-need-reachable-alternatives]] · [[absence-needs-a-probe-that-could-see-presence]] ·
[[a-fixture-helpers-default-pins-the-swept-axis]] · [[a-guard-must-be-satisfiable-not-just-failable]] ·
[[start-local-runs-from-a-saved-copy-of-live-settings]]
