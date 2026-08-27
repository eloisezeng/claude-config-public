---
name: test-migrations-through-real-boot-path
description: "migration tests that call migrate() directly on hand-built fixtures miss the real boot path; test the actual open/boot function against a legacy-shaped DB FILE, and never put schema statements that assume post-migration shape ahead of the migrator"
metadata: 
  node_type: memory
  type: feedback
  scope: global
  originSessionId: 6b190d34-ff15-4456-ac7d-34c8e19e5f52
---

A live app crash-looped at boot with 2,168 tests green: `openDb()` exec'd `schema.sql` BEFORE `migrate()`, and schema.sql contained `CREATE INDEX IF NOT EXISTS ... (new_column)` for a column only `migrate()` adds — fine on every fresh test DB, fatal on the real legacy DB (`SQLITE_ERROR: no such column`). The migrate tests seeded legacy shapes by hand and called `migrate(db)` directly, so the schema-exec-first boot path was never exercised.

**Why:** "IF NOT EXISTS" only suppresses the already-exists error — index creation still validates columns against the CURRENT table shape, and CREATE TABLE IF NOT EXISTS no-ops on existing tables, leaving them in their historical shape. Any bootstrap file exec'd before the migrator may only reference shapes that exist in EVERY historical version.

**How to apply:**
- For every schema change, add/extend a regression test that drives the REAL boot entrypoint (`openDb()`/equivalent) against a legacy-shaped DB **file** (pre-change table shapes), not just direct `migrate()` calls on fixtures — assert no throw and the post-state (columns+indexes present).
- Indexes (or any DDL) on migrated-in columns belong in the migrator ONLY, guarded idempotently; the bootstrap schema keeps the column in CREATE TABLE for fresh DBs.
- When reviewing deploy-safety, trace the actual boot ORDER (bootstrap exec vs migrator vs plugin installs) — "additive + idempotent + guarded" is not sufficient if a statement runs before the guard that makes it valid.
- Pairs with [[verify-claims-against-artifacts]] and [[scale-test-large-data-paths]] (same class: the green suite proved the wrong path).
