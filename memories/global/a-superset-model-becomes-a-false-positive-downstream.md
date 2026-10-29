---
name: a-superset-model-becomes-a-false-positive-downstream
description: an over-approximation is only safe where nothing downstream reads it as certainty; carried forward a step, "possible" becomes "definite" and the guard goes LOUD
metadata:
  type: feedback
scope: global
---

When you decline to re-implement a predicate and model it as a SUPERSET instead
("put the key back wherever the real applier COULD"), the safety claim written
beside it — "this can only ever be too quiet, never too loud" — holds for ONE
step and is false the moment anything downstream reads that model as fact. The
next step cannot tell possible from definite, so it reports a loss that never
happened. A false POSITIVE is the worse half: a false negative misses a
mistake, a false positive blocks a legitimate edit and is how a guard gets
widened by hand until it catches nothing.

So before writing "superset, therefore safe", name every later reader of the
modelled value. If any exists, the model must be EXACT or must carry its own
uncertainty. Exact usually does not mean re-implementing: DERIVE the predicate
from the one authored source and fail CLOSED — pin its normalised source text
to its twin and RAISE on anything unrecognised, so editing the original stops
the dependent instead of letting a stale copy answer. That keeps the real
prohibition (a copy that can drift silently) while dropping the approximation.

**Why:** measured 2026-10-14. A validator modelling a JS applier put an
inherited rule back wherever the applier could; on a row the applier definitely
skips, the next delta reported losing a rule the page never had — 0 problems at
the parent, 1 after the "fix". Deriving the applier's own `appliesTo` from its
source text, with an unrecognised form raising, made it exact in both
directions and the real data stayed at 0 problems over 135 sites.

**How to apply:** grep for downstream readers of any approximated value before
calling the approximation safe; prefer derive-and-fail-closed over both
re-implementing and approximating. See [[a-gate-may-not-read-its-verdict-from-the-gated-party]].
