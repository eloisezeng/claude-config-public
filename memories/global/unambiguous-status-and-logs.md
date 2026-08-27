---
name: unambiguous-status-and-logs
description: When modeling state, give each enum value ONE meaning; never overload a success/status flag across semantically distinct outcomes; emit self-explanatory logs/UI that cross-check against the artifact
metadata:
  node_type: memory
  type: feedback
  scope: global
---

When you model state or emit a status / log line / UI label, make it **unambiguous**: one value = one meaning, and the reader (a human, or future-you triaging) can tell exactly what happened without guessing or cross-referencing.

**Why:** today's entire confusion came from one overloaded enum. A run's `status='succeeded'` meant **four** different things — did real work, no-op (nothing to do), *tolerated external failure* (the download failed but is handled inertly), and gated/held. A prior session read `succeeded` as "the work happened" and reported a false success to you, who had to unwind it across several turns. The ambiguity was baked into the data model, so every consumer — triage, dashboard, handoff — inherited it. This is the **producer-side** of [[verify-claims-against-artifacts]]: that rule says verify the artifact; this one says don't emit the ambiguous signal in the first place.

**How to apply:**
1. **One value, one meaning.** If you're tempted to document an enum as "`succeeded` means X — or Y, or Z," that's the smell: split it. A machine *lifecycle* (`running/succeeded/failed`, which drives retry/health) answers a different question from an *outcome* (`acted/no_op/inert/held/baseline`, what actually happened) — model them as separate fields, not one overloaded flag.
2. **A "success" that can hide a failure is a bug.** A tolerated/inert failure must be representable as *distinct* from real success — never collapse "couldn't run" into "succeeded."
3. **Logs and UI must be self-explanatory and cross-checkable.** A line announcing completion names *what* and carries the evidence (count, path, duration) so it reconciles against the artifact — not a bare "done" / "✓". Keep internal enums/jargon out of the UI; render plain-language state ([[data-product-ui-defaults]]).
4. When you find an overloaded status / ambiguous log in existing code, **fix it**, don't just route around it — [[feedback-fix-dont-just-note]].
5. **Announce/notify state must live per-ITEM, stamped only on successful delivery** (2026-07-30: three independent builders hit this class in one night). A shared "last announced" clock starves any item hidden while other sends move the clock; an announce keyed to an object's creation time re-fires immediately when its content grows. And any artifact written on an exit path (receipt, audit, log line) must join the guarded state-change's transaction and key off `changes > 0` — an artifact describing a change that lost its CAS race is a false sentence.

Ties [[verify-claims-against-artifacts]], [[data-product-ui-defaults]], [[feedback-fix-dont-just-note]], [[act-on-fresh-state-anchor-by-identity]].
