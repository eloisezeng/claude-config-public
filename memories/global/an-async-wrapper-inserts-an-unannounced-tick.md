---
name: an-async-wrapper-inserts-an-unannounced-tick
description: `async`, `await`, `.then` and a promise-returning helper each insert an event-loop tick the source text does not announce, so a test distinguishing two orderings one microtask apart passes under BOTH once a fixture is tidied into `async` — and a fixed number of `setImmediate` turns or a flat sleep is a bet on machine speed, not a synchronisation primitive
metadata:
  type: reference
  scope: global
---

Where a production ordering matters within a single microtask — settle the caller's promise BEFORE signalling abort, so a cooperative worker settling inside its own abort listener cannot win the race — the only tests that can see the difference are fixtures that settle on the tick the author assumed.

**An `async` wrapper settles one microtask LATER than a bare promise**, which is enough for the scheduler's own settle to land first no matter which order the production code used. Under an `async` fixture both orderings pass, so the test reads green while pinning nothing. Measured 2026-09-11 (lane `an-async-test-agent-hides-a-reject-before-abort-ordering-bug`): the fixtures' `run` is deliberately not `async`, and a comment above each is the entire defence. A future author tidying them into the surrounding house style, or copying one as a template, retires the pin with no failing test and no diff line that looks wrong.

**Pin the microtask budget with a positive control, not with a shape guard.** Run the same fixture against a deliberately reordered copy of the production cutoff and assert it records the WORKER's outcome instead of the timeout. That makes the sensitivity executable, and it fails when someone makes the fixture `async`, because then both arms agree. A static guard asserting the fixture declares `run` as non-`async` is cheaper and worth nothing on its own: it tests the SHAPE rather than the property — `[[a-mention-is-not-a-property]]`.

**The sibling shape: a fixed number of event-loop turns used as a wait.** `await new Promise(r => setImmediate(r))` to "let the other task reach its await" suffices only while every await ahead of the observed side effect resolves synchronously. Measured 2026-09-01: two such sites were green on macOS and crashed a mutation-harness child on three CI legs of one run; a positive control that deleted one wait outright reproduced the CI failure on macOS. A flat `setTimeout` sleep is the same bug in wall-clock spelling — one site slept 400 ms for a spawned grandchild to appear in the process table and failed under full-suite load with `expected 1 to be greater than or equal to 2`.

Draining one task's own microtasks with a single immediate turn IS the right primitive; waiting for ANOTHER task's side effect is not. Convert the second kind to a bounded wait on the observable CONDITION, with a budget inside the runner's own per-test timeout so a genuine hang reports its own reason rather than an opaque timeout. Bounding patience makes no test weaker: the thing that used to fail still fails.

Related: `[[wall-clock-ceilings-measure-the-machine]]`, `[[pin-the-clock-in-clock-dependent-tests]]`, `[[the-effective-timeout-is-the-min-of-two-budgets]]`, `[[a-surviving-mutant-may-mean-the-property-is-unobservable]]`.
