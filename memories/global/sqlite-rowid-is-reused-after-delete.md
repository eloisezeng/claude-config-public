---
name: sqlite-rowid-is-reused-after-delete
description: SQLite reuses a deleted row's id for the next INSERT (plain INTEGER PRIMARY KEY), so delete-then-insert can hand the new row the exact id another process already snapshotted
scope: global
metadata:
  type: reference
---

A plain `INTEGER PRIMARY KEY` in SQLite is the rowid, and SQLite assigns the next INSERT `max(rowid)+1` **computed after the delete**.
Delete the highest row and insert a replacement in the same transaction and the new row is handed the id you just freed.
(`AUTOINCREMENT` is what forbids reuse, at the cost of a `sqlite_sequence` table; most schemas do not use it.)

**Why it matters:** this silently voids the "renew a marker so a stale writer's `UPDATE ... WHERE id = ?` becomes a no-op" pattern.
The stale update lands on the *fresh* row instead of a deleted one, and the guard reads as working in every test that does not drive the real writer.
Found 2026-08-18 in the STOP-reply build: the first renewal implementation deleted-then-inserted, and only a test driving the scheduler's real `unprocessedEvents` + `markProcessed` against the pre-delete id caught it.

**How to apply:** when a new row's identity must differ from one an observer already holds, **insert before delete** inside one IMMEDIATE transaction, and write the ordering constraint into the spec so a later "cleanup first" refactor cannot quietly reverse it.
Never assume a re-created row gets a new id; pin it with a test that replays the observer's stale id through the real production writer ([[self-referential-fixtures-pin-nothing]], [[pin-behaviour-on-the-artifact]]).
