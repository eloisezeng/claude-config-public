---
name: a-frozen-page-clock-disables-in-page-waiting
description: freezing a page's clock stops the page making progress at all, so every in-page wait, retry and start-up step is unavailable to the test
scope: global
metadata:
  type: reference
---

Freezing a browser page's clock (Playwright `page.clock.pauseAt`, and any equivalent fake-timer
install) does not merely stop the page's own timers.
It stops anything that decides when to continue by reading the clock, which includes React's
scheduler handing a slice of hydration back to the browser, so a page can stop finishing its
start-up entirely and sit half-rendered for as long as the test allows.

Two consequences that read as flakiness rather than as this:

- A harness wait that polls INSIDE the page (`locator.waitFor`, which runs on animation frames)
  can never be satisfied on such a page.
  Moving the poll to the test process (`expect.poll`) fixes the POLLING and not the page: the
  condition still never becomes true.
  A bigger budget is the wrong fix, and the proof costs one measurement — a 30 s budget that
  expires at 30 s on an idle machine says the marker never arrives, where a tight budget failing
  under load says only that it was late.
- An `expect(locator)` assertion on such a page has no working retry either, so it reads the
  server-rendered placeholder and goes on reading it.
  Waiting for the page's data call to be ANSWERED does not help, because rendering the answer is
  the work the frozen clock has stopped.

Expect the failures to rotate among the frozen-clock tests and to disappear when each spec is run
on its own, since what finishes before the freeze takes hold in a given document is a race.
The fix is to let the page hydrate BEFORE freezing (install the fake clock without pausing, pause
afterwards, and watch that `pauseAt` fast-forwards to its target and fires every timer in between,
which moves any interval count the test asserts).
Failing that, run those specs with one worker, and know which configuration your CI uses before
you call a local red a defect: `workers: process.env.CI ? 1 : N` means a four-worker local run is
not the run that gates the merge.
