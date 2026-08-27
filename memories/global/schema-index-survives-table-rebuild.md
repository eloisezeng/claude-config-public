---
name: schema-index-survives-table-rebuild
description: "Every index a query depends on must survive the migration paths that rebuild its table — and an INDEXED BY hint turns a missing index from a slow scan into a runtime crash"
metadata:
  node_type: memory
  type: feedback
  scope: global
---

When you add an index that a query depends on, verify it survives **every** path that can recreate its table — not just the fresh-schema path.

The recurring failure: a schema file creates the index at boot, but a migration that widens a CHECK constraint does `DROP TABLE` → `CREATE TABLE` → recreates only *some* indexes. On any database old enough to hit that migration, the new index vanishes, and (because schema files typically run once per process, before migrations) it stays gone until the next restart. Tests pass, fresh databases are fine, and only legacy/restored databases silently degrade.

This bit twice in two days on the same repo — first `rebuildActionsWithSuperseded` dropping a new partial index on `actions`, then `rebuildEventsWithChainKind` dropping four indexes on `events`.

**`INDEXED BY` raises the stakes.** In SQLite it is a *constraint*, not a hint: if the named index is absent the statement throws `no such index` rather than falling back to a scan. That is a deliberate, useful "fail loudly" choice — but it converts a missing-index bug from "slow page" into "crashing page", so any query carrying the hint makes the rebuild-recreate gap ship-blocking rather than a performance nit.

**Why:** the rebuild path is invisible from the diff that adds the index — nothing in the new code references it, so reviewers and implementers both scope it out as "pre-existing."

**How to apply:**
- After adding any index, grep the migration code for rebuilds of that table (`DROP TABLE`, `CREATE TABLE ... _new`, "rebuild") and recreate the index there too, with the predicate copied byte-for-byte from the schema file.
- Pin it with a migration test that drives the **real boot path** on a legacy-shaped database, asserts the index exists afterward, and — when any query uses `INDEXED BY` — asserts that query actually runs post-rebuild. See [[test-migrations-through-real-boot-path]].
- Before adding `INDEXED BY` to work around a planner flip, ask whether the flip was demonstrated at realistic scale or is an artifact of a tiny fixture with no statistics; either way, the hint is only safe once the index is guaranteed present everywhere. Related: [[verify-claims-against-artifacts]], [[scale-test-large-data-paths]].
