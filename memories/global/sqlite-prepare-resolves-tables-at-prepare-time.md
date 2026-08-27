---
name: sqlite-prepare-resolves-tables-at-prepare-time
description: better-sqlite3 resolves table names at prepare() — an existence guard placed after the prepare never runs in time
metadata:
  type: reference
scope: global
---

`db.prepare('SELECT … FROM t …')` in better-sqlite3 **throws immediately** (`no such table: t`) if `t` does not exist. Resolution happens at prepare, not at `.get()`/`.run()`.

So this is a guard that cannot guard:

```js
const stmt = db.prepare('SELECT 1 FROM maybe_missing WHERE id = ?')   // throws HERE
const hasTable = db.prepare(
  `SELECT COUNT(*) n FROM sqlite_master WHERE type='table' AND name='maybe_missing'`).get().n > 0
… hasTable && stmt.get(id)                                            // never reached
```

Check `sqlite_master` **first**, and skip the prepare entirely when absent (hold `null` and test for it at the call site). It reads as defensive either way, which is what makes the wrong order easy to ship and easy to miss in review — the code looks like it handles the case.

Applies to any optional/late-added table: a schema that arrived in a later migration, a plugin table, a table only some deployments have.

**INDEXES resolve at prepare() too.** `FROM t INDEXED BY idx_x` throws `no such index` at prepare, so a statement built unconditionally will throw on any database lacking that index — a bespoke test fixture, a partially-migrated DB — even on the overwhelmingly common execution path that would never have run it. Build such a statement INSIDE the branch that needs it, and add the index to every fixture that reaches the code. (`NOT INDEXED` is safe: it forbids indexes rather than naming one.)

Related: [[verify-claims-against-artifacts]].
