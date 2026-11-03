---
name: a-closed-round-cannot-accept-a-retrospective-row
description: an append-only ledger with a close operation admits nothing afterwards, so work registered late leaves a downstream gate unsatisfiable with no override — register at launch
metadata:
  type: feedback
  scope: global
---

Register work with its ledger AT LAUNCH, never after it finishes.
An append-only ledger that has a `close` operation refuses every later row for a closed period by design, and the gate downstream of it is the one that discovers the omission — at which point the honest row can no longer be filed where it belongs and the gate has no override.

**Why:** the close is what makes the period's accounting trustworthy, so admitting a late row would seal a period over work no artifact accounted for.
That property is correct and is the reason the gate is worth having; it also means the cost of launching work outside the scheduler is not paid at launch, when it looks free, but at the gate, by whoever is trying to ship.

**How to apply:** launch every reviewed/measured job through the scheduler that ledgers it (`loop.py run --track T --round N --kind K -- <cmd>`), so the row exists before anything can close.
When you inherit the omission, do not reach for the two routes that look available and are not: recording into the closed round is refused outright, and a `one-off`-style track accepts the row but is explicitly never accounted, so the gate still refuses.
File such rows on a purpose-named parallel track (`<track>-retro`), let each artifact's own NAME carry its true period, put the reason in the row's note, and say in the shipping artifact that you did it — a workaround that is legible is a different thing from one that is hidden.
Keep the real track's period count honest rather than inventing a period that never happened.
Related: [[a-precondition-guard-cannot-gate-the-last-step]] — the same shape one level up, where the artifact a merge requires is obtainable only by closing everything.
