---
name: a-gate-may-not-read-its-verdict-from-the-gated-party
description: A guard that reads its decisive flag out of the artifact it is guarding is not a guard; the flag must resolve in a source the gated party does not write
scope: global
metadata:
  type: feedback
---

When a check decides whether something is ALLOWED, the value it decides on must come from a source the checked party does not author.
Otherwise the gate is decoration: whoever is gated simply writes the flag that unlocks the gate.

**Why:** a report linter refused "win language" on any number flagged `descriptive_only` or whose `margin_class` was not `credible` — and read both flags straight out of the report's own appendix.
The report's author wrote the flag that decided whether the author's claim was permitted, and the document's own §1 promised "the prose cannot overrule the state files" while the code made that false.
It survived a dozen review rounds because the gate LOOKED rigorous and the flags LOOKED like data; one of the two flags had no producer anywhere in the codebase.

**How to apply:**
- For every gate, name the WRITER of the deciding value. If the writer is the party being gated, it is not a gate.
- Require the value to resolve through a pointer into an artifact produced by someone else (an emitter, a frozen state file), and check equality — not just presence.
- A flag nothing computes may not gate anything. Refuse it outright, and pin that refusal with a test asserting the producer set is still empty, so the refusal converts into a wiring task the moment an emitter appears.
- **A writer that EXISTS is not a writer that RUNS: count the live rows carrying the value, because a value computed rarely refuses exactly as completely as one computed never, and reads as correctly wired at every review.** Having a producer is the weaker half of the question; the share of real items that carry the value is the answer. Measured 2026-09-11: a short `.org`/`.net` purchase check skipped any name whose stored company check had no company match, and 0 of 271 stored checks carried one — a 100% refusal — because the same pull request's own prompt told the valuer to answer nothing for letters it could not expand. Six review rounds passed, and this rule was in force for two later edits of that check; both were counting refactors that never re-asked who fills the input. The count is also the test's contract: fixtures that hand-write the unlocking value make a 0%-live gate read green (measured: 4 of 40 post-merge repairs were exactly that).
- "It is emitted somewhere" is not enough: if the check reads the author's COPY of the value, the emitter is irrelevant.
- Distinguish presence from agreement, and unbacked from unresolvable from disagreeing — three distinct findings, three distinct messages.

Related: [[verify-claims-against-artifacts]], [[adjudicate-review-disputes-in-the-contract]], [[mirror-a-gate-at-its-exact-scope]], [[unambiguous-status-and-logs]].
