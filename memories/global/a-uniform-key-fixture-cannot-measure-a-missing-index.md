---
name: a-uniform-key-fixture-cannot-measure-a-missing-index
description: A performance fixture whose lookup key is uniform (agent_id = i % 40) makes every index-less probe terminate on its first steps, so the O(N×M) it exists to detect reads as linear — skew the fixture the way production is skewed, and control it against a forced-scan case
metadata:
  type: feedback
scope: global
---

A scale probe measures the DISTRIBUTION you built, not the query you wrote.
Measured 2026-09-02 on a migration backfill: `SELECT MAX(latest.id) FROM runs latest WHERE
latest.agent_id = r.agent_id`, run once per candidate row, with **no index on `runs(agent_id)`**.
I expected O(candidates × rows) and pre-registered that.
Three sizes (20k/80k/320k rows) came back perfectly linear, and the correlated form was *faster*
than the grouped rewrite (0.7× / 0.5× / 0.4×).

The reason is SQLite's min/max optimization: with no usable index it walks the rowid index
DESCENDING and stops at the first row matching the WHERE.
My fixture used `agent_id = i % 40`, so every agent had a row within the top 40 rowids and every
walk terminated in ~40 steps.
`EXPLAIN QUERY PLAN` said `SEARCH latest` in both arms, and `PRAGMA automatic_index=off` did not
move it — my control failed to force the opposite answer, which is the tell that the probe was
blind rather than the code fast.

Rebuilt with production's actual skew — a few agents whose whole history sits in the OLDEST 5% of
rowids, each with several failed rows (the real shape: an agent that failed repeatedly and then went
dark) — the same query at a **fixed 180 candidates** took 125 → 527 → 2633 ms across 50k → 200k →
800k rows, 28–35× the grouped form. Cost scaling with table size at constant candidate count IS the
O(N×M) signature.

**Why:** an index-less equality lookup costs "distance to the nearest matching row", and a modulo or
round-robin key puts a match next to every probe. The population that hurts is always the skewed
tail — the dead agent, the cold tenant, the abandoned account — and that is exactly the population a
uniform fixture cannot contain.

**How to apply:** build the fixture from the skew the feature exists to serve (if you are backfilling
*failed and then silent*, seed rows that are failed and then silent), and never accept a linear
result until a deliberately-unindexable variant of the same query has produced the quadratic curve in
the same script. Then size it against the real table before spending a fix: mine came to 411,386 walk
rows ≈ a few ms on 60,048 live rows, so the correct disposition was RECORD, not fix — hardening a
path the data cannot reach is how the previous round's findings got minted.
See [[plan-assertions-need-reachable-alternatives]], [[a-control-must-match-the-probes-shape]],
[[absence-needs-a-probe-that-could-see-presence]], [[surprising-result-check-metric-identity]],
[[scale-test-large-data-paths]].
