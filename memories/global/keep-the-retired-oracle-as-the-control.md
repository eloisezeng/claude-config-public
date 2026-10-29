---
name: keep-the-retired-oracle-as-the-control
description: When strengthening a weak assertion, keep the SUPERSEDED predicate in the file and report both readings — the gap is the finding, and without it "the new test passes" is unmeasured
metadata:
  type: feedback
scope: global
---

Replacing a weak oracle with a strong one proves nothing on its own: the new assertion passing says only
that the code is currently right, never that the OLD one was blind. Keep the superseded predicate in the
file as a named positive control, run both against the same perturbation, and report the pair.

Measured in one review round, five times over, each on a copy with the tracked tree's shasum asserted
unchanged:

- a per-term safety claim asserted with `events.map(e => e.id).sort()`. One event rewritten IN PLACE:
  **old PASSES, new FAILS.**
- a colour ratchet keyed on the trimmed source LINE. A legacy declaration moved onto a brand-new selector
  keeps the total at 26 AND the whole multiset of lines: **old cannot see it at all.**
- a date sweep whose oracle was `built + alreadyOver === 13`. Mutate the scope predicate's `>=` to `>`:
  **the sum PASSES at all six dates** while the identity partition fails by name at two.

The shape of the gap is always the same — the old identity is a projection (a count, a set of keys, a
line) and the defect moves within a fibre of it. So the question to ask of any assertion is not "can this
fail?" but "what can change without moving this value?", and the answer is worth writing down next to it.

A corollary for mutants: a mutant that survives may mean the property is unobservable rather than the test
weak — one here (Sync sending the render's closed-over events) survived because the re-render rebuilt those
events, so no outcome could tell the wirings apart. Record that, don't paper over it. See
[[a-surviving-mutant-may-mean-the-property-is-unobservable]], [[a-guard-must-be-satisfiable-not-just-failable]],
[[a-mention-is-not-a-property]].
