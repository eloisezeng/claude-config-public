---
name: a-settle-detector-unions-superseded-attempts
description: a CI settle detector that unions every check-run on a sha turns one failed attempt into a PERMANENT false red, because nothing retracts a completed failed check-run
metadata:
  type: reference
scope: global
---

A detector that reads "every check-run attached to this sha, all must be green" is correct for CONCURRENT duplicates and wrong for SEQUENTIAL attempts, and it cannot tell them apart without the run id or `run_attempt`.
The consequence is worse than a false red: it is a PERMANENT one, because a completed failed check-run is never retracted, so the first failure locks that sha at NOT-GREEN for ever and every later reopen or re-run adds a success the rule cannot credit.
The next session then has no settle signal at all on the one commit it needs one for.

Measured 2026-10-31 on `your-other-project` pull request #544 at head `c1398df0`: three `pull_request` events on one byte-identical commit (two reopens to refresh a stale body payload), the third green on all eight jobs, and `~/.claude/bin/ci-green.sh` still printed `VERDICT: NOT-GREEN` naming four check-runs from the two superseded attempts — 17 check-runs for 8 names.

**Settle it from the authority that actually gates, which is not the aggregate.** GitHub read `mergeable: MERGEABLE` and `mergeStateStatus: CLEAN` at the same moment, because required-check evaluation takes the LATEST check-run per context NAME. Only `statusCheckRollup.state` agreed with the script, and that aggregate is the very thing such scripts exist to distrust — so an aggregate agreeing with your detector is not a second measurement.
The test for whether overriding it is honest rather than a re-roll is whether you can NAME the fix for every red it cites; here each was a missing pull-request-body declaration line, both present by the green attempt.

Fix such a detector by reducing to the newest check-run per name (by `started_at`, or the owning run's `run_number`/`run_attempt`) and applying the all-green rule to that set, still failing closed when two check-runs of one name are genuinely concurrent, which the run id distinguishes. It needs both controls: a sha with a superseded failure must read GREEN, and one with a real concurrent failure must still read NOT-GREEN.

Related: [[watch-the-run-you-triggered]] · [[control-a-settle-detector-on-captured-output]] · [[a-gated-deploy-step-makes-the-image-check-unsatisfiable]]
