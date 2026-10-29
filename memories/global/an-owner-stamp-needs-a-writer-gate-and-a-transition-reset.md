---
name: an-owner-stamp-needs-a-writer-gate-and-a-transition-reset
description: Stamping cached per-user state with its owner closes only the reload path; the writer must also be unable to run before the identity resolves, and a change of identity must RESET rather than relabel
metadata:
  type: feedback
scope: global
---

Binding cached per-viewer state (a `sessionStorage` snapshot, a client cache, a draft) to its owner
takes THREE mechanisms, and shipping only the first leaves the hole open while reading as fixed:

1. **A refusal rule** on read — "this snapshot belongs to someone else, so you may not have it".
2. **A writer that CANNOT run before the identity is known.** Otherwise the owner is stamped from
   whatever the identity reads as in the frame before it resolves, which is usually "nobody".
3. **A reset when the identity CHANGES from one settled value to another.** The stamp is rewritten
   by whatever effect keeps it current, so an expiry or a sign-out relabels the previous person's
   data as the new one's instead of removing it.

**Why:** a nullable id (`user?.id ?? null`) gives the SAME answer for a settled visitor, an
unresolved session, a logout in flight, and a session read that ERRORED, and those four need three
different treatments. A refusal rule alone is correct only for the reload path, where the page
starts with the new identity already in hand. Measured on one arc: the stamp was added and
reviewed, and a second review then found a session expiring under an OPEN tab rewrote the member's
query and rows under a null owner — restorable by anyone — while a 503 from the session endpoint
read as a settled visitor and DELETED the member's saved state, replacing it with an empty one.
Neither needed a lost response or a reload.

**How to apply:** parse the identity once into a discriminated union
(`unresolved | visitor | member(id)`) rather than a nullable id, and give the writer a parameter
type that EXCLUDES the unresolved case so the compiler names every call site at once instead of a
guard the next caller forgets. Make the read rule return three answers — restore / **hold** /
discard — because "not yours" and "not known yet" need opposite handling: refusing deletes, holding
does not. Treat a FAILED identity read as unresolved, never as "nobody". Gate the write on a piece
of STATE holding the viewer currently being served, not a ref, so the write effect can see inside
the very commit the viewer changed in that the data on screen belongs to the previous one. Test the
full truth table over (stored owner) x (viewer state) and assert every disposition is reachable.
Reproduce both the expiry and the failed-read paths in a browser before fixing.

Related: [[encode-the-invariant-in-the-shape-not-another-guard]],
[[a-validated-write-surface-has-an-unvalidated-sibling]].
