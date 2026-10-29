---
name: a-uniform-key-fixture-cannot-measure-a-missing-index
description: A fixture keyed by modulo or round-robin spreads EVENLY by construction, so it cannot build the concentrated worst case it exists to measure — the hot key for a missing index, the widest row for a layout rule; skew it the way production skews, and control it against a case that forces the opposite answer
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

The same key, the same blindness, on a LAYOUT rule. Measured 2026-09-24 on your-web-app's
maximum-legal-state fixture: `awardsMaxRounds` assigned each award to
`players[(index * MAX_AWARDS_PER_ROUND + slot) % players.length]`.
A row's width is set by how many DISTINCT awards ONE player holds, and the modulo spread
guaranteed nobody concentrated: at the shipped twelve seats its widest row held **4** of the 8
awards, at eight seats only **2**.
The widest legal row — one player holding all eight, which ordinary play reaches because the
per-round ceiling stops two in one round and nothing stops eight across twenty — was a state the
"maximum state" fixture could not build.
Concentrated instead, the region measured **950px of content in a 358px box, 592px of sideways
scroll** on a phone, against a decision the whole arc existed to keep.
Two review lenses had to find it by reading, because the fixture could not.

**Why:** the general form is that a modulo or round-robin key is an EVENNESS generator, and every
worst case worth measuring is a CONCENTRATION — the nearest matching row, the widest row, the
deepest queue, the hottest tenant.
An index-less equality lookup costs "distance to the nearest matching row", and a modulo key puts a
match next to every probe; The population that hurts is always the skewed
tail — the dead agent, the cold tenant, the abandoned account — and that is exactly the population a
uniform fixture cannot contain.

a layout maximum costs "most items on one row", and a modulo key puts one item on every row.

**How to apply:** ask what quantity the rule is actually about and whether your key can MAXIMISE it
for a single member — then build the fixture from the skew the feature exists to serve (if you are backfilling
*failed and then silent*, seed rows that are failed and then silent), and never accept a linear
result until a deliberately-unindexable variant of the same query has produced the quadratic curve in
the same script. Then size it against the real table before spending a fix: mine came to 411,386 walk
rows ≈ a few ms on 60,048 live rows, so the correct disposition was RECORD, not fix — hardening a
path the data cannot reach is how the previous round's findings got minted.
And publish what the fixture actually BUILT as an asserted contract
(`maxDistinctAwardsOnOnePlayer`, asserted EXACTLY, never `>=`): 40 award entries spread evenly and
40 concentrated on one player draw the same rows and the same count, so the count alone cannot tell
a fixture that reaches the maximum from one that quietly went back to spreading.
See [[plan-assertions-need-reachable-alternatives]], [[a-control-must-match-the-probes-shape]],
[[absence-needs-a-probe-that-could-see-presence]], [[surprising-result-check-metric-identity]],
[[scale-test-large-data-paths]].
