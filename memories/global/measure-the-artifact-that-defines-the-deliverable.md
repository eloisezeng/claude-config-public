---
name: measure-the-artifact-that-defines-the-deliverable
description: before narrowing a locked deliverable as impossible, measure the artifact that DEFINES it, not the one that will implement it
metadata:
  type: feedback
scope: global
---
Before reporting that a settled deliverable cannot ship, measure the artifact that DEFINES it — the design prototype, the spec, the decision log — and not only the codebase that will implement it. An "it is impossible" finding derived from the implementation side is a claim about the implementation, and the defining artifact usually already answers the question the implementation could not.

**Why:** measured 2026-10-06. The user's locked decision asked for a "Read the full idea" modal on four marketing pages. I grepped the STACK, found that only one of the four rendered an idea card carrying a real id, and wrote into the plan that three pages would be left un-wired pending a content decision. Two independent review lenses refused the narrowing as a plan-versus-locked-decision contradiction. Re-measuring the PROTOTYPE took one grep and showed the premise was false: each page opens ONE FEATURED brief, the same one on all three (`Brief Solar Steam.dc.html?embed=1&preview=1`), so no per-card ids were ever needed and all four pages ship. The cost of the wrong turn was a retracted plan section, a lane filed on a non-problem, and a status report to the user that understated what she was getting.

**How to apply:** when a deliverable looks impossible, name the artifact that SPECIFIES it and grep that artifact for the mechanism before writing the word "blocked". Phrase the finding as "the prototype does X, which the stack cannot express yet" rather than "the stack has no X, so this cannot ship". Reaching for a content or product decision is the LAST step, not the first, because asking her to decide something the design already decided spends her attention on a question that has an answer. Related: [[verify-claims-against-artifacts]] · [[fetch-before-you-diagnose]].
