---
name: never-wait-on-an-event-the-subject-can-prevent
description: A test waiting on a lifecycle event the subject under test can make unreachable converts an instrument failure into a full-budget hang that reports only the wait condition
metadata:
  type: feedback
  scope: global
---

Never wait on an event the SUBJECT can prevent from ever firing — bound every wait with a budget
DERIVED from the enclosing one, and make the failure name who broke.

A browser's `load` event cannot fire on a document whose body was truncated mid-stream, so
`page.goto(url)` with no `timeout` of its own has no terminating condition left but the test budget:
the run spends it all and reports `Test timeout of 240000ms exceeded ... waiting until "load"`, a
message about the WAIT and never about the cause. Swapping to `domcontentloaded` fixes nothing,
because that event cannot fire on a truncated parse either — the defect is waiting on the subject's
own signal, not which signal.

**Why:** three sessions read this as a slow page. Measured 2026-10-27 from the Playwright trace: the
dev server severed every connection inside 41 ms 10.8 s into one navigation (the document ending
`ERR_INCOMPLETE_CHUNKED_ENCODING`, four chunks `ERR_CONNECTION_RESET`), and then **nothing happened
for 229 seconds**. One stylesheet was served 200 in 35 ms after the document's stream was cut, so
the process was alive at that instant and gone milliseconds later. The fixture had been capturing
the server's own stdout the whole time and printed it ONLY on a boot failure — thrown away in
exactly the case where it was the answer, and it checked the child's `exitCode` across boot and
never again.

**How to apply:** bound the wait (derived, never a second literal — `[[the-effective-timeout-is-the-min-of-two-budgets]]`);
watch any child process for the HARNESS's whole life rather than across setup, and print its exit
status and output tail in the failure; then classify the fault before deciding what it licenses — a
severed connection is the INSTRUMENT failing and never a product verdict, so a retry may be granted
ONLY where the fault class is transport-level AND the dependency is answering again, which keeps a
product failure from ever consuming one. Put that licence in a pure function with the refusals swept
and mutant-killed, because a rule like it rots into "retry until green" when it lives in prose.
Related: [[a-tail-window-is-not-a-failure-report]] · [[a-new-detectors-first-run-measures-the-detector]] ·
[[a-resource-freed-only-on-the-success-path-hangs-on-failure]].
