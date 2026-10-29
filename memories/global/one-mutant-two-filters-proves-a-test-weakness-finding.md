---
name: one-mutant-two-filters-proves-a-test-weakness-finding
description: For a finding that says "this test cannot see the defect", the proof is ONE source mutant run twice — filtered to the old test it must SURVIVE, filtered to the new test it must be KILLED — which measures the finding itself where a comment-only control measures only the harness.
metadata:
  type: feedback
scope: global
---

A comment-only control answers "is this harness capable of reporting SURVIVED?"
That is worth having and it is not the finding. When the accepted finding is
*this test cannot see the defect it was written for*, the control that measures
the FINDING is the same source mutant pointed at the OLD test.

So run one mutant twice, one `mutate.py` invocation per command, same `old`/`new`
edit, different `-t` filter:

- filtered to the test the finding named: **expect SURVIVED** — that IS the
  finding, now a measurement rather than a reading.
- filtered to the new test: **expect KILLED**, attributed to that one name.

Measured on job_hunt 2026-10-04, finding F6: removing the `process.pid`
component from `temporaryPath` survived `gives every WRITE in one process its own
temporary` and was killed by `gives every WRITER its own temporary: two
processes…`. One source edit, two verdicts, and the pair says both "the fix is
pinned" and "the old test could not have pinned it" — which no comment-only
control can say.

Two side-effects worth keeping:

- **It also proves the harness reached the subject.** That run drove a CHILD
  process importing the module through a specifier rewritten by `mutate.py`; had
  the rewrite missed, the child would have imported the real unmutated source
  and the mutant would have read SURVIVED. The KILL is the evidence the rewrite
  landed, so the vacuous-run class (`[[verify-claims-against-artifacts]]`) is
  closed by the same measurement.
- **Where the harness cannot run** (a test whose file set is derived from the
  tree reddens `mutate.py`'s baseline in its copy dir), the honest substitute is
  the same shape by hand: add the control, run it, QUOTE the pre-fix value it
  read, fix, re-run. Claim "reproduced before and after" and not
  "mutation-verified" — `[[verification-claims-are-earned-per-item]]`.

See also `[[a-surviving-mutant-may-mean-the-property-is-unobservable]]` for the
opposite reading of a survival, and `[[a-mention-is-not-a-property]]` for the
partially-broken-mutant rule that settles which predicate you actually wrote.
