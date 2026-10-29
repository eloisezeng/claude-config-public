---
name: a-deploys-artifact-is-not-a-lazily-triggered-effect
description: name which STAGE owns the artifact you verify — a deploy ships code, and a lazily-triggered migration produces nothing until the next run opens the store
metadata:
  type: feedback
scope: global
---
"Verify against the artifact" needs a second question: WHICH STAGE produces that artifact.
A deploy's own artifact is the running image plus the shipped source — grep the deployed file on the box, do not merely match an image label.
A schema change reached through a LAZY opener (`globalThis.__x ??= open()`, a per-run connection, a first-use cache) is the NEXT stage's artifact, and it appears when that stage runs, which can be many hours after the deploy.
Reading its absence as a failed deploy, or forcing it by hand to make a report read complete, both attribute one stage's output to another.
Prove the laziness empirically rather than from the code: measure the store AFTER the process has restarted and is beating, and let the unchanged schema be the evidence.

**Why:** measured 2026-10-28 landing PR #520. Deploy run `40736719613` pinned to merge `5dcb8f3f` succeeded on every step, the only running image was `gh-5dcb8f3f…`, and the box's own copy of `zone-db.ts` contained `migrateAddedSnapshotColumns` four times — yet `/data/zone.db` still read 9 columns with no `last_verified_at`, because `getZoneDb` is `globalThis.__zoneDb ??= openZoneDb()` and nothing at worker boot opens that store. The next open was a daily agent ~13.5 h out. The handoff's own expected after-state was wrong in the same way for a second reason: `origin/main` had none of the four added columns, so the table goes 9 → **13**, not 9 → 10 — derive the after-state from the BASE's code, never from the count someone wrote down.

**How to apply:** before verifying a deploy, write down the stage that owns each artifact you plan to read, and read only that stage's own output as evidence about it. Measure the BEFORE state first, or the after-measurement proves nothing. Quantify what the deferred step will actually do before considering forcing it (here: both earlier migrations were already applied live, so the pending open was four `ALTER TABLE ADD COLUMN` in one `BEGIN IMMEDIATE`, no table rebuild) — then still prefer handing it forward with the exact probe and the expected reading over an unrequested production write. Related: [[verify-claims-against-artifacts]] · [[a-human-gated-stage-proves-itself-in-the-unapproved-child]] · [[watch-the-run-you-triggered]].
