---
name: the-effective-timeout-is-the-min-of-two-budgets
description: "A test driving a child process has TWO wall-clock budgets (the spawn's and the runner's) and the MINIMUM wins — so a deliberate 60 s spawn timeout under a default 5 s test budget is a ceiling nobody chose"
metadata:
  type: feedback
scope: global
---

`spawnSync(cli, args, { timeout: 60_000 })` inside a plain `it("…", async () => {…})` does **not** give that test 60 seconds. The runner's own per-test budget also applies — vitest and jest both default to **5000 ms** when no config overrides it — and the ceiling that actually fires is the **minimum of the two**. The author's deliberate number is dead code, and the number that governs is one nobody picked, which means it measures the machine rather than the code — `[[wall-clock-ceilings-measure-the-machine]]`.

The tell is a suite that goes red **in batches, in different files each run**, with the runner's opaque timeout (`Error: STACK_TRACE_ERROR` in vitest's JSON reporter) rather than the child's own output or a `spawnSync ETIMEDOUT`.

**Why:** measured 2026-08-28. Adding two unrelated test files made six pre-existing tests fail — 12 failures across 9 full-suite runs with them, 0 across 9 without. That evidence frames the new files as the cause and they are only the **trigger**: they shifted worker scheduling. On a *quiet* run the affected tests already sat at 34–96% of the default, the worst at **4820 ms of 5000**. Three sub-shapes appeared, and only the first is obvious: (a) a generous spawn budget under the inherited default; (b) spawns with **no** timeout at all, so nothing was ever chosen; (c) a *test* spawn borrowing a **production** constant (a 3 s probe ceiling) for scratch children whose subject was never that ceiling.

**How to apply:**
- **Derive the outer budget from the inner**, never write it as a second literal: `const TEST_BUDGET_MS = CHILD_TIMEOUT_MS + 30_000` and pass it as `it(name, fn, TEST_BUDGET_MS)` / `beforeEach(fn, TEST_BUDGET_MS)`. The ordering then stays true by construction when either number moves. Two independent literals drift.
- Pick the bound **far above the work, not tuned near it** — a ceiling close to the measurement is just the machine's speed written down again.
- **Enumerate by AST, not by symptom** — `[[enumerate-recurring-defect-classes]]`, `[[fix-the-class-not-the-reported-instance]]`. Resolve each `it` callback *transitively through file-local helpers*, because the spawn is nearly always inside one (`runHelper`, `runCli`) rather than inline; a file-level answer over-approximates by more than an order of magnitude (one file had 54 budget-less tests and almost none spawned). Resolve identifiers and simple arithmetic too, or a correctly-derived budget reads as "inherited default" and the analyzer will report your own fix as broken.
- **Do not fix a spawn whose ceiling is the product's real behaviour.** Where the test drives the shipped code end-to-end, the production constant IS the subject — leave it and say so in the diff.
- Prove the clean report is a measurement, not a blind probe: revert each budget in a scratch **copy** and require the analyzer to light up, asserting the tracked files byte-identical in the same script — `[[absence-needs-a-probe-that-could-see-presence]]`, `[[never-arm-a-fault-in-an-auto-syncing-tree]]`.
- Confirm the fix with an **interleaved** A/B, never a sequential N-then-N: a machine that quietens over ten minutes produces the "fix worked" result on its own.
- The fix is test-only, so it costs no production diff — which removes the usual reason to route it to a separate branch.
