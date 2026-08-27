---
name: an-existential-release-rule-is-fail-open
description: "A gate phrased \"open when A review/check says clean\" is fail-open the moment two of them can cover the same artifact — quantify it universally over the covering set"
metadata: 
  node_type: memory
  scope: global
  type: feedback
  originSessionId: feeae9cb-a234-4e07-b363-8b83813352b1
  modified: 2026-08-24T02:26:28.049Z
---

A release rule phrased existentially — "open when **a** review names a clean commit", "ship when **a**
green run exists" — is reachably fail-open as soon as two pieces of evidence can cover the same
artifact. Reviewer 1 files a clean review; reviewer 2 reviews the same bytes and files a HIGH. The
existential opens on the first while the second stands. Write it as **at least one covering witness AND
every covering witness clean**. That is strictly narrower and cannot deadlock, because a witness that
stops covering (the code moved on) drops out rather than blocking forever.

Two things fall out of getting this right, both learned by writing the property before the code:

- **Distinguish clauses that BLOCK from clauses that FILTER.** A blocking clause (a high/medium finding)
  closes the gate universally. A filtering clause (the diff since the reviewed commit is dirty) removes
  that witness from the covering set instead — so "making that input worse" is monotone in *neither*
  direction: it can also OPEN the gate, when the witness it removed was a stale blocker. That is correct
  — a finding filed against code that has since changed must not veto a newer clean review — but it will
  look like a bug and it will break a naively-written monotonicity property. The invariant worth pinning
  is that the verdict depends on the covering subset alone.
- **A gate that can never open reads CLOSED identically to a correctly-closed one.** Force both sides
  against real data before believing either. Build the positive case as an unreferenced `git commit-tree`
  object — a real tree, a real parent, no ref moved and nothing pushed — and assert the gate opens on it;
  see [[absence-needs-a-probe-that-could-see-presence]] and [[verify-claims-against-artifacts]].

Ship the rule as a pure function with the facts passed in as data, per
[[eval-clauses-are-code-not-prose]]; the ambiguity above is exactly what one more round of prose
wordsmithing will not find.
