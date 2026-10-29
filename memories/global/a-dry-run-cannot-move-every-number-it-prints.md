---
name: a-dry-run-cannot-move-every-number-it-prints
description: "A preview/dry-run mode PINS every metric derived from the action it suppressed, so reading that metric reads nothing — `emailed` was `status === 'accepted' ? plan.toEmail.length : 0` and a dry run can never be accepted, so `emailed: 0` prints whatever the plan holds; gate on the mode-specific annotation instead, and before trusting any ratio two printed counts seem to form, check they share a population (`pages read: 0` beside `removed after reading the page: 223` in the real run proved they do not)"
metadata:
  node_type: memory
  type: feedback
  scope: global
---

Before gating a merge or a deploy on a number a `--dry-run` printed, ask of EACH number
you intend to rely on whether that mode can move it at all.

A metric computed from the status of the action the mode suppresses is pinned to its
zero value by construction, and prints that zero identically for a plan that would do
nothing and a plan that would do a great deal. Measured 2026-10-06: a run's summary
computed `emailed` as `email.status === 'accepted' ? plan.toEmail.length : 0`, and a dry
run's status can only be `nothing_new` or `not_sent`, so `emailed: 0` was not evidence
of anything. The real signals were two ABSENT lines — a `(a real run would email N)`
parenthetical printed only when the plan is non-empty, and a `Subject it would send:`
line printed only on `not_sent`. Their absence established what the printed number
could not, and two independent absences are what made it safe to merge.

So: read the mode's OWN annotations, not the shared metric, and prefer a fact asserted
by two independent lines over one number read once — `[[absence-needs-a-probe-that-could-see-presence]]`.

The same pass turned up the sibling trap. Two counts printed next to each other invite
reading as a ratio, and `pages read: 223` beside `removed after reading the page: 223`
read as a 100% rejection rate. They were different populations: the first counted only
URLs newly ASKED for, the second counted removals over cached readings UNION asked
ones. The real run settled it beyond argument by printing `pages read: 0` beside
`removed after reading the page: 223` from a restored cache. Never let two adjacent
counts imply a denominator neither one claims — `[[surprising-result-check-metric-identity]]`.

And when a deploy must be confirmed rather than assumed, the cheapest decisive artifact
is the DIFFERENCE between the run before and the run after: the pre-merge run printed
`listed: 898` with no per-source breakdown, the post-merge run printed three source
lines that only the merged code can produce. That is the deployed artifact carrying the
change; a green tick never was — `[[watch-the-run-you-triggered]]`.
