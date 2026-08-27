---
name: verification-claims-are-earned-per-item
description: "Mutation-verified" and similar claims are assertions — earn them per item, never per round, and correct an overstatement in place
metadata:
  type: feedback
scope: global
---

A sentence like "all of this round's fixes are mutation-verified" is an assertion about evidence,
and it is only true for the items actually verified. Writing it over a batch, when most of the
batch was verified and a few were not, converts a gap into a documented falsehood — and the record
is exactly what a later reader trusts instead of re-checking.

Measured on the 2026-08-10 AI-budget branch. I wrote that claim over a round of twelve fixes; three
of them (cap-reading conversions in chat preflight, chat money summary, and a health warning) had
NOT been mutation-verified, because no fixture in those files had the state the fix depended on, so
reverting any of them left the suite green. The next round's counter-party lens found the
overstatement *in the convergence record itself* and filed it as a HIGH. It was right to.

**How to apply**
- Track verification per fix, not per round. If a fix has no mutation that kills a test, it is
  unverified — say so beside it rather than letting a batch sentence cover it.
- When a claim turns out to be overstated, **correct it in place with a note saying it was
  overstated when written**, rather than quietly making it true and leaving the original sentence
  standing. A record that silently self-heals teaches nobody, and the correction is the part with
  information in it.
- Beware the shape that causes this: a fix whose behaviour only differs in a state no existing
  fixture creates (an overdue row, a null column, a second connection). The suite stays green under
  the mutation because the scenario never arises, not because the code is pinned.
- A mutation that fails to kill a test is a claim about the MUTATION too — check it actually
  changes behaviour before recording the test as weak. One "surviving" mutation was masked by a
  `useEffect` that immediately re-derived the value.
- **A "killed" verdict is meaningless unless the test was GREEN immediately before the mutation.**
  A matrix that only records the post-mutation result cannot tell "the guard has teeth" from "the
  suite was already red". Assert the filtered baseline passes per item, and record the count beside
  each kill (`killed … (baseline 1 green)`); log `BASELINE-RED` as explicitly meaningless, not as a
  kill. Measured 2026-08-18: an interrupted matrix left a mutation on disk, the next run copied the
  poisoned file into its own backup, so every "restore" restored the mutation — all 8 kills were
  vacuous and I reported them as verified. It surfaced only when the FULL suite came back red.
- **Verify the backup/reference the matrix restores from, at the moment it is taken.** Two runs
  sharing one artifact path is what corrupted it; give each run its own paths and an exclusive
  lock, and grep every mutation site for cleanliness before trusting the tree — a `git status`
  check cannot see a mutation inside a file that is already modified.

Related: `[[verify-claims-against-artifacts]]`, `[[self-referential-fixtures-pin-nothing]]`,
`[[codex-parallel-lenses-beat-serial-rounds]]`.
