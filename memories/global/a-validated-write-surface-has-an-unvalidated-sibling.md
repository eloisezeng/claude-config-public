---
name: a-validated-write-surface-has-an-unvalidated-sibling
description: "Answer a bad-data finding's reachability question by hunting the path that BYPASSES the validator, not by confirming a validator exists — a raw/bulk/import write surface beside the typed one usually validates a different subset, and the keys it skips are silently unguarded"
metadata:
  node_type: memory
  scope: global
  type: feedback
  modified: 2026-09-08T13:00:00.000Z
---

The standing reachability frame — demand the WRITE PATH for any bad-data finding, and decline it
when none exists — is right, but it is asked wrongly if you go looking for *a* validator. Finding
one proves nothing. The question is whether some OTHER path writes the same field without it.

A typed surface almost always has a raw sibling: a per-key setter beside a whole-document editor,
a form beside a CSV import, an API beside an admin console, a migration beside a backfill script.
They land in the same column, and they validate different subsets — because the typed one's
validation is written per key, and the raw one's is written per *concern* (auth, injection,
one or two dangerous keys) and silently covers nothing else.

So enumerate the writers of the FIELD, not the callers of the validator: grep every site that
UPDATEs the storage, then read each one's guard and say which keys it actually covers. A guard
that iterates a named allowlist covers exactly that allowlist; everything absent from it is
unvalidated, and absence is invisible at the call site.

Measured 2026-09-08: `op:'configNumber'` rejects a non-number with a 400 and clamps through a range
table; `op:'configString'` rejects a non-string. Beside them, `op:'config'` — a "Save config"
textarea posting raw JSON — validates only its string-key allowlist, one map, and one
spend-ceiling raise, then persists the parsed object whole. Every numeric knob in the product is
therefore writable as `null`. Two config readers coerce `Number(null) === 0`, which is finite and
`>= 0`, so a pasted `null` reads as the operator's deliberate "spend nothing today" zero and
disables a lane that goes on reporting `active` and succeeding.

Note the direction of the error this corrects: I had recorded that finding as UNPROVEN and declined
to call it a bug, on the strength of having seen the typed setters clamp. That was the reachability
frame applied to the wrong path. Declining an unreachable finding is correct; declining a reachable
one because you checked the guarded route is how a real defect gets filed as a non-issue.

The fix is at the boundary, not in the readers: drive the raw surface's validation from the SAME
table the typed surface clamps with, so a key cannot be guarded on one route and open on the other
(`[[encode-the-invariant-in-the-shape-not-another-guard]]`). Patching the readers one at a time
leaves the next reader to be written unguarded.

Related: `[[the-product-may-already-own-the-write-path]]` (which route to use once a write is
needed), `[[a-blocked-write-may-be-a-no-op]]` (whether the write is needed at all), and
`[[absence-needs-a-probe-that-could-see-presence]]` (the general shape of proving a negative).
