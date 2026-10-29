---
name: relaxing-a-wait-removes-what-it-silently-provided
description: Weakening a wait (load to domcontentloaded, a sleep to a poll, a lock to a read) silently withdraws every guarantee the expensive wait was also providing — enumerate those before the change and expect the fallout at sites that never mention the wait
metadata:
  type: feedback
  scope: global
---

A wait is almost never bought for the reason its name gives.
Before relaxing one, enumerate what ELSE it was providing, and expect the breakage at call sites
that never mention the wait at all.

Measured on discover's browser suite, taking 290 `page.goto`/`page.reload` calls off `load` and onto
`domcontentloaded`.
Three distinct classes of fallout appeared, none of them at a navigation call site:

1. **A later one-shot assertion that the wait was guaranteeing.** Three sites asserted an image's
   `naturalWidth > 0`, which only `load` had made true. The repair is to POLL the property, which
   asserts the thing decoded instead of inferring it, and is a stronger claim than the wait was.
2. **A sample point.** A counter read immediately after a navigation now samples before the page's
   own fetches land, so the page's first read is mistaken for the refetch the test forbids. Where a
   redirect makes two documents, a `waitForLoadState("load")` AFTER the navigation does NOT repair
   it, because it resolves against the FIRST document — it failed 5 of 5 where naming
   `waitUntil: "load"` on the navigation itself passed 5 of 5. Keep the escape hatch: a default
   that only applies when the call is silent lets one genuinely dependent site say so.
3. **A following operation that needed the document settled.** A history step issued into a
   still-loading document is DROPPED: `goBack` returns successfully, its own `load` wait satisfied
   by the load already in flight, and the url never changes. It failed 1 run in 3, so an isolated
   one-iteration probe exonerated it falsely (9 of 9 correct) and only running the real test three
   times per arm settled it. Fix it at the OPERATION — make the step wait for the current document —
   rather than by reverting the whole default.

Two method notes that generalise past browsers.
A defect that appears in 1 run of 3 cannot be attributed, confirmed or pinned by a single run: take
samples per arm and report the rate, and do not write a single-run regression test for it and call
it pinned.
And when a degenerate-input guard is added alongside such a change (`every()` over an empty set is
vacuously true), expect it to redden immediately on something that was already asserting nothing —
that red is the guard working, so classify what it found before weakening it.

Related: `[[a-ci-only-slowness-needs-the-codes-contribution-bounded-first]]` for bounding the code
touching it, and `[[the-effective-timeout-is-the-min-of-two-budgets]]` for deriving an outer ceiling
from the inner ones rather than writing a second literal.
