---
name: a-destination-scoped-exists-check-leaves-the-source-replayable
description: "A copy whose NOT EXISTS is scoped to the DESTINATION is idempotent per destination and leaves the SOURCE replayable into a SECOND destination — a serializable transaction serialises concurrent copies and consumes nothing; make the source single-use with a UNIQUE key every gate reads under the same lock, and ship it in the SAME migration as the table it guards"
metadata:
  node_type: memory
  type: feedback
  scope: global
---

A copy that reads "insert every source row the destination does not already have" is the obvious
shape and it is idempotent — **per destination**. Nothing in it consumes the SOURCE, so the same
source can be copied again into a different destination, and every assertion about the first copy
still passes while it happens. The tell is that the existence check names only the destination's key.

Measured 2026-10-07 in a private frontend repo: a visitor's paid briefs were copied into the account
they signed in to by selecting `WHERE VisitorId = @visitorId` with
`NOT EXISTS (… WHERE e.UserId = @userId AND e.VentureId = v.IdeaId)`, and the contract even stated
"visitor rows are never deleted". Signing into account A and later into account B therefore copied the
same briefs twice: one person's payment became two accounts' entitlement. Three facts about that are
worth carrying:

**A serializable transaction is not a consumer.** It serialises concurrent copies, which is what it
was put there for and what every test of it asserts, and it says nothing about a replay hours later.
Reaching for the isolation level is the reflex that hides this class, because the transaction is
genuinely correct about the thing it was reasoned about.

**Make the source single-use in the DATABASE, not in the application.** A claim table mapping the
source identity to one destination, with the source id ALONE as the unique key, means the engine
refuses the second claim rather than a read-then-write noticing it. Make that key the CLUSTERED one
and it is also the index the `UPDLOCK, HOLDLOCK WHERE <source id> = @id` range lock is taken on, so
one key does both jobs and no two sources contend. Write the consume in the SAME statement batch as
the copy, so "claimed but not copied" is not expressible, and put the claim FIRST so a key violation
stops the batch before a row moves. Then every gate that admits further spending by that source
identity reads the same row under the same lock — one fact, two gates, linked by a property test, so

**The claim table ships in the SAME migration as the table it guards, and the test for "is this one
migration or two?" is the backfill.** Split in two, a database can exist with the source rows live and
no claims table, which IS the defective state — so the split creates a window in which the defect is
live rather than removing it. Worse, that window's repair cannot be written: a backfill would have to
say which destination each earlier copy went to, and the reason the defect existed is that nothing
recorded it. One file makes the state unreachable, and because the same file creates the source table,
no source row can predate the claim and **no backfill is needed at all**. Where a reviewer argues for
splitting on sequencing grounds ("the first table is wanted sooner"), the answer is that running a
knowingly-defective version sooner is worse than waiting, and the remaining cost of waiting is one
session's work.

What the second destination gets is **nothing**, and that is a product decision to state rather than
an edge case to handle: those rows were already given to the first destination, and a source identity
someone presents is never authorisation for the destination presenting it. The operation that
discovers a replay should still SUCCEED where it has other work to do — the account is real and the
session is owed, only the copied rows are not — and should log the replay without the source
identifier when that identifier is itself the credential-like value being replayed.

Related: `[[encode-the-invariant-in-the-shape-not-another-guard]]` (the decision is a three-state
union, so "claimed but not copied" cannot be constructed), `[[act-on-fresh-state-anchor-by-identity]]`,
`[[schema-index-survives-table-rebuild]]`.
