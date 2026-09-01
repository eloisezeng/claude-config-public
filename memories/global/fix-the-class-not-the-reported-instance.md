---
name: fix-the-class-not-the-reported-instance
description: When a review names one instance of a defect, fix the whole class and sweep for siblings — two HIGH findings in one session were "my fix was narrower than the bug"
metadata:
  type: feedback
scope: global
---

When a reviewer reports a defect, the report names ONE instance. Fix the class, then sweep the
codebase for every sibling before calling it done.

**Why:** In a single convergence run (2026-08-03, evidence-stage fix), two consecutive review
rounds each found that the *previous* round's fix was narrower than the bug — both HIGH:

- A money breaker was reported as suppressing account-level refusals. I made the swallow match
  account errors. But the breaker had three families, so a QUOTA breaker day whose poll also
  returned quota still failed on every tick — the exact noise the fix existed to remove, moved one
  endpoint over. The fix had to be per-family, with the matcher carried beside the enum so they
  cannot drift.
- A credential leak was reported in one typed error's message. I scrubbed that message. The same
  raw vendor string reached a persisted column through a *different* path (a gone-task reason),
  which the reviewer found next round. The sweep — "what else persists vendor text?" — should have
  been part of the first fix.

The tell in both cases: the fix touched exactly the file:line in the report and nothing else.

**How to apply:** After writing a fix, ask two questions before moving on. (1) *What is the general
form of this bug?* — one member of an enum/family means check every member. (2) *Where else does
this same shape occur?* — grep for the pattern (every writer of that column, every path that
persists that value, every sibling status code) rather than trusting that the reviewer enumerated
them. Then pin the CLASS with a test, not just the reported instance. Relates to
[[feedback-fix-dont-just-note]] and [[verify-claims-against-artifacts]].

**This applies to correcting CLAIMS, not just code.** A retraction has a definition site and
citation sites, and fixing only the first leaves the refuted claim standing where readers actually
meet it. Measured 2026-08-27 (treecue §13): a round withdrew a guard's universal claim at the guard
body and recorded itself as complete, while two traceability-table rows two hundred lines away still
asserted the withdrawn claim verbatim — found only by the next pass grepping the claim's own
keywords. So after correcting any claim, grep the artifact for the claim's distinctive words
(`closed domain`, `exhaustive`) and fix every site, then say plainly that the earlier completeness
claim was overstated — see [[verification-claims-are-earned-per-item]].
