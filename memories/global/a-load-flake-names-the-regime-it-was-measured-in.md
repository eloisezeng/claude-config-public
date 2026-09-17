---
name: a-load-flake-names-the-regime-it-was-measured-in
description: A "known flake, never evidence about your branch" note written from a LOCAL high-worker run teaches later sessions to wave off a CI red that has never happened — measured 0 occurrences of four such subjects across 104 failed CI runs; state the regime the observation was made in, because the fail-open direction dismisses the next real red
metadata:
  type: reference
  scope: global
---

A standing "ignore this red" note is one of the highest-leverage things in a memory store and one of the easiest to overstate, because the observation behind it is usually real and the SCOPE is what gets lost.

Measured 2026-09-09 (lane `four-load-flakes-were-local-not-ci`): a memory said four named test files "time out at 30 s under full-suite load, 259/259 in isolation, so never evidence about your branch", and it was being used as a standing rule. Surveying the last **500 CI runs**, **104 of which failed**, and searching every failed log for the four subjects gave **0, 0, 0**. Not one of them had ever failed in CI. The reds those runs actually contain are a different set entirely.

The note is not simply wrong. The observation was made **locally at 18 workers**; CI runs the suite at two. An 18-worker run on a laptop is a different load regime, and a per-test ceiling reached there says nothing about a two-worker runner — `[[changing-the-worker-count-moves-every-wall-clock-ceiling]]`. So the conclusion is right for the local case and unsupported for CI, and as written it teaches a session to wave off a CI red that has never actually happened. **That is the fail-open direction:** the next genuine red in one of those files gets dismissed by a rule built from a different machine.

So a flake note carries three things, not one:

1. what was OBSERVED, with the regime named (worker count, machine, isolation, concurrency);
2. what was MEASURED against the other regime, with its query and its denominator;
3. the resulting rule stated per regime — here, "at 18 workers locally these are load artifacts; **in CI a red in one of these files is a real red and must be read, not dismissed**".

The same survey's second result is the one that pays, and it only exists because the denominator was counted: of the 104 failed runs only **5** were pushes to main, and **2 of those 5** were one defect a single PR fixed.

A memory rewrite of this kind belongs in its own commit, never folded into whatever arc found it — mixing it into a performance branch makes one PR two changes.

Related: `[[a-red-suite-with-no-failing-test-lost-a-worker]]`, `[[wall-clock-ceilings-measure-the-machine]]`, `[[verify-claims-against-artifacts]]`, `[[a-setting-is-not-a-rate]]`, `[[start-local-runs-from-a-saved-copy-of-live-settings]]`.
