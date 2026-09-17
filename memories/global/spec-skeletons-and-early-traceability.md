---
name: spec-skeletons-and-early-traceability
description: Start every new spec/plan from the previous CONVERGED artifact's section skeleton (omissions are the cheapest finding class to prevent), and run the cheap traceability/coverage pass at round 1 of EVERY document stage, not only at plan time
metadata:
  node_type: memory
  type: feedback
  scope: global
---

Two round-savers for document convergence, adopted 2026-08-19 ("do this in the future"):

1. **Skeleton from the last converged artifact.** A new spec or plan in an established series starts from the previous converged one's SECTION SKELETON — every heading and required block (success/bar clause, fixed run protocol, contract block, payload shapes, guard list, citations), content blanked.
   **Why:** 4–5 of the C2 spec's review findings were pure omissions — sections the converged C1 spec already had (bar clause, certification protocol, manifest block) that the fresh-page C2 draft simply lacked.
   Reviewers charged high-effort rounds to rediscover a checklist that already existed as the prior document.
2. **Traceability at round 1 of every stage.** The cheap coverage pass (every clause names its owning task/guard/test; every task traces back; contradictions listed with both sides quoted) runs against the SPEC in its first review round, not only against the plan.
   **Why:** the Luna coverage sweep found 15 gaps at plan stage for a fraction of one Terra round's cost; pointed at the spec earlier, the unassigned-clause class ("G6 declared but no task builds it") surfaces before the expensive semantic reviewer spends rounds around it.

3. **Never cite code BY LINE NUMBER, and never trust a lint that says the citations are fine.** Measured 2026-09-07 on a tree where every citation had just been re-aimed at exactly where its `origin/main` text went, a rule requiring each citation to contain an identifier the citing line names reddens **37 of 50** — most of them in files no recent work had touched. The checker read green anyway because it content-checked only the citations making one particular claim: on one branch 24 citations went stale and CI reported 5, so **a green spec-lint is not evidence the citations are right** ([[a-mention-is-not-a-property]]). A merge makes it worse invisibly, since every citation shifts with the merged file and nothing re-aims it.
   Do not widen the checker first: widening reddens main immediately and forces a 37-citation re-adjudication under time pressure. And a code-versus-document mismatch names a FACT, never which side is wrong — some of these are the document describing code that was later removed, which is a spec question rather than a line-number one ([[codex-parallel-lenses-beat-serial-rounds]]). Cite by IDENTIFIER, and repair the drift before tightening the rule.

**How to apply:** before drafting, diff the new draft's headings against the predecessor's; run the traceability lens (cheap tier) concurrently with the first semantic review round at every document stage.
Pairs with [[eval-clauses-are-code-not-prose]] and [[codex-parallel-lenses-beat-serial-rounds]].
