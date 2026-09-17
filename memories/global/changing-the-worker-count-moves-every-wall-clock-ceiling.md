---
name: changing-the-worker-count-moves-every-wall-clock-ceiling
description: Changing a suite's worker count silently retimes every wall-clock ceiling it was sized against — a CPU-bound sweep asserting nothing about time reads the MACHINE, and the resulting reds are reproducible (5/5, 5/5, 2/5), not flakes; fix the contended class with a named shared constant, never by raising the global default
metadata:
  type: reference
  scope: global
---

A parallelism change does not touch a single ceiling's text, and it moves all of them. Every test whose assertion is about an OUTCOME but whose runtime is CPU-bound now shares its cores differently, so its wall clock reads the machine — `[[wall-clock-ceilings-measure-the-machine]]`. This is true in both directions: raising the worker count squeezes each sweep, and cutting it from a large local default to a small CI-matching one changes which of them are near their limit.

Measured 2026-09-09 over six full-suite CI samples at two workers on two vCPUs, plus a serial control (lane `contended-sweep-budget-and-the-real-size-of-the-maxworkers-saving`):

- Serial-to-worst-parallel ratios for the affected sweeps: **3.1x, 2.1x, 1.7x**.
- **Reds counted by FILE over five samples: 5/5, 5/5, 2/5.** Two of the three are 100%, so this is a reproducible red on a required check, not a flake rate — the serial base rate was 8.8% (5 of 57) and is a different phenomenon.
- The load-sensitive class was then collapsed into ONE named constant stated by five tests in three files, so the next occurrence is one edit rather than a hunt.

**Do not raise the global default timeout instead.** A census helper read the config's `testTimeout` as the number every stated budget must strictly clear, so raising it 30 s to 90 s retroactively invalidated a 90 s teardown budget and left about six hand-derived budgets silently TIGHTER than the default they had been sized against. One line, a dozen-file blast radius. Name the contended class instead.

**Price the saving before buying the lever.** The same measurement found the change worth far less than the memory index claimed: job duration 2,055–2,256 s against a serial median of 2,526 s, an **11–19% cut** (35–38 billed minutes a run against 43), where the proposal had projected a ~0.6x multiplier. The cause is in the same numbers — SUMMED per-file work ROSE from 1,736 s serial to 2,381–2,610 s under contention, and mean concurrency reached only 1.24–1.28 of a possible 2. Two workers on two vCPUs buy far less than 2x, and a bigger runner makes the worker cap a no-op by construction.

Expect the change to make the REMAINING load-sensitive files more likely to redden, not less, and say so: the files that did not appear in this sample are the next candidates for the same constant, and that is the honest open edge.

Related: `[[a-blind-poll-sleep-bills-the-fast-path]]`, `[[the-effective-timeout-is-the-min-of-two-budgets]]`, `[[a-load-flake-names-the-regime-it-was-measured-in]]`, `[[preflight-the-cost-before-you-pay-for-it]]`.
