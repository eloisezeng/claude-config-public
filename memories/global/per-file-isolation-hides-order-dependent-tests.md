---
name: per-file-isolation-hides-order-dependent-tests
description: Per-file test isolation is not a speed knob — it is what HIDES shared-state contamination, so turning it off does not expose a few bad tests but a population (311 measured); union 61 files / intersection 0 is the signature, and one of the hidden tests made a real paid API call
metadata:
  type: reference
  scope: global
---

A fresh sandbox per test file is usually read as a performance setting with a percentage attached. It is not. It is the thing that keeps an order-dependent suite green, and switching it off reveals how much contamination the suite has been carrying.

Measured 2026-09-09 over fourteen full-suite runs, seven per side, at `--maxWorkers=2`, with the flag passed on the CLI so the config file was never edited (lane `the-suite-has-311-order-dependent-tests-that-only-isolation-hides`):

- Isolation ON: 1,079 files, 23,368 tests, 6 of 7 runs clean.
- Isolation OFF: **every** run failed, and the failing set was a different random subset each time — union over 8 runs **61 distinct files, intersection 0**, per-run counts 12/20/26/14/18/15/10/10, and 37 of the 61 failed in exactly one run.
- **311 tests** failed at least once. All 311 are green in all 7 isolated runs, and every one of them also PASSED in at least one unisolated run.

**Read the union-versus-intersection shape before you read the count.** A large union with an empty intersection is the signature of shared-state contamination; it is not a list of bad tests somebody could pair off and fix. No member of it is a stable, attributable defect, so bisecting one is wasted work.

Three classes explain almost all of it, and the third is the one that costs money: the module registry defeating `vi.mock` factories; a leaked module-level singleton read after another file has already migrated; and **a unit test making a real outbound HTTPS call to a vendor API** — present in 6 of 6 unisolated runs and 0 of 6 isolated ones, reading as an auth error only because no key was set on that machine. On a runner that HAS the key, that is real paid egress from a unit test. Isolation off also leaked to disk twice in 8 runs, once modifying a TRACKED data file.

So the mock that isolation makes redundant is load-bearing for SPEND, not only for correctness, and the saving is small anyway: ~2.6% of the suite, bounded by three order-matched seed pairs whose deltas were +0.6%, −6.6% and +19.4% — the noise is as large as the effect, because the failures themselves cost time. Fixing the contamination first would raise the ceiling to ~7%.

Related: `[[a-red-suite-with-no-failing-test-lost-a-worker]]`, `[[changing-the-worker-count-moves-every-wall-clock-ceiling]]`, `[[no-extra-cash-without-permission]]`, `[[a-subset-run-is-not-a-suite-run]]`.
