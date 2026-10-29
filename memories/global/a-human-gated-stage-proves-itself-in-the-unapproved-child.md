---
name: a-human-gated-stage-proves-itself-in-the-unapproved-child
description: Where a stage's output waits behind an approval, the PUBLISHED artifact is a measurement of the approver, not the stage — read the unapproved child plus the card
metadata:
  type: feedback
  scope: global
---

Where a pipeline stage's output waits behind a human approval, "check the live artifact" measures
the APPROVER, not the stage.
A stage that worked perfectly and a stage that found nothing produce an identical published page,
because neither has published anything — so the artifact that proves the stage ran is the
UNAPPROVED CHILD it wrote plus the card it filed, and the published one is the wrong question.
Name the approval gate before choosing the artifact, and read `newest` beside `published` rather
than `published` alone.

**Why:** the normal discipline — never trust a status flag, go and look at the live product — is
right, and it points at the wrong object here. It cost a whole session: a shelf re-link run had
linked 17 of 19 rows into ten unapproved versions and filed one approval card, and the published
page correctly showed 19 rows still unlinked, which read as a total failure to find any product.
The resulting brief named a refuted hypothesis as its leading theory and told its successor the
pipeline was broken. The same probe re-run against `newest` reported 2 asin-less rows, not 19.

**How to apply:** for any approval-gated stage, the done-check is three reads, not one — the child
version exists and is NOT approved, its rows carry the new values, and the card exists in a status
the schema actually permits. Enumerate the status vocabulary from the schema before writing the
card probe, because a probe querying a value the CHECK constraint forbids returns empty forever
and cannot see presence (`[[absence-needs-a-probe-that-could-see-presence]]`). And a stage whose
log names only what it WROTE — versions, sites, "1 action proposed" — cannot distinguish the two
cases at all, so make it report the DECISION count read off the rows
the question from, which is how the wrong reading survives into a brief
(`[[an-inherited-environment-fact-is-a-stale-measurement]]`).
