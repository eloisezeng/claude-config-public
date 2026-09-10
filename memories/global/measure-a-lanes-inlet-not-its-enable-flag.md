---
name: measure-a-lanes-inlet-not-its-enable-flag
description: "A switched-on pipeline stage whose inlet predicate nothing writes produces nothing and reads perfectly healthy — measure the INLET ROW COUNT, never the enable flag; and before backfilling into it, measure where its EXIT status lands, because one stage's exit is usually another stage's inlet"
metadata: 
  node_type: memory
  scope: global
  type: feedback
  modified: 2026-09-08T12:41:00.000Z
---

**A stage is healthy only if something is arriving at it.**
Its enable flag, its `active` row and its scheduled cron all read green on a stage that has never processed a single item, because none of them is a measurement of arrival.
The shape that produces this: the inlet predicate is written by an upstream guard that fires only at an item's FIRST visit (`WHERE status = 'candidate'`), so every item that passed through before the stage existed was filed as ordinary and nothing goes back for it.
Measured 2026-09-08: 535 eligible items on the shelf, an inlet holding 0 rows, both agents `active` with `last_success_at: null`.

So the health question is `SELECT count(*)` on the inlet predicate — never "is it on?".

**Then, before backfilling into that inlet, measure where the stage's EXIT lands.**
Pipelines are chains of status predicates, so a stage's completion status is usually the NEXT stage's entry condition, and that next stage may be the expensive one.
Here the exit status was the appraiser's paid deep-valuation queue: a naive backfill would have silently bought 535 valuations nobody asked for.
The cure is to record where an item came from and send it home on completion (a nullable `*_return_status` column, advanced with `COALESCE`), not to reuse the forward path's exit.

The general rule: **a status value is an interface, and it usually has more than one reader.** Grep for every predicate that names it before you write it.
