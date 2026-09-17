---
name: a-red-suite-with-no-failing-test-lost-a-worker
description: A suite can exit 1 with ZERO failing tests when a worker process dies before its next file — the file-level status still reads "passed", so the obvious probe finds nothing; histogram the ASSERTION statuses to name the lost file, and never treat one such red as evidence about the branch
metadata:
  type: reference
  scope: global
---

A full-suite run reporting `Test Files 983 passed (984)`, zero failed tests, and exit **1** has not found a defect in your branch. One worker fork died before running its next file, so that file's tests never ran at all. The only clue in the default reporter is `Worker forks emitted error / Worker exited unexpectedly`, which names nothing.

**The file-level `status` in the JSON reporter is useless here** — every file, including the one that never ran, reports `passed`. So the obvious probe (filter `testResults` on `status !== "passed"`) returns zero and looks like the run was fine. Histogram `testResults[].assertionResults[].status` instead: a healthy run is `{passed, skipped}` only, a run with a dead worker adds a **`pending`** bucket, and every member of that bucket belongs to ONE file. Measured 2026-09-04: 10 `pending`, all 10 tests of one file, which passed alone in 2.88 s — that file is the VICTIM, not the culprit.

**The rule: a single red full-suite run with zero failing tests is not evidence about the branch under test.** The same measurement took five samples on one machine: byte-identical trees went RED twice and GREEN once (two runs reconstructed and sha256-verified identical, disagreeing), a comment-only null mutant padded to the same byte count went green, and clean base went green. Take two samples per side before attributing a red to a diff, and record that you re-ran rather than re-rolling quietly until green.

Two plausible hypotheses were killed and are worth not re-deriving: the sequencer reshuffling files by SIZE (controlled for with the byte-matched mutant, then retired outright by the identical-bytes disagreement), and "something in the new tests". No OS crash report was written in any window, so the worker was not a segfault — it exited.

The REPORTING half is separable and worth fixing first, whatever the cause: a run that loses a file should name the file. A red with no cause is an unreproducible red with no artifact — `[[a-tail-window-is-not-a-failure-report]]`. Do not paper over it with a retry, which converts a lost file into a deliberate silent skip.

Same family as `[[a-build-dir-in-the-tree-reddens-whole-tree-guards]]`, `[[a-worktree-needs-its-own-node-modules]]` and `[[a-load-flake-names-the-regime-it-was-measured-in]]` — the red is about the checkout or the machine, not the branch. Related: `[[per-file-isolation-hides-order-dependent-tests]]`, `[[a-subset-run-is-not-a-suite-run]]`.
