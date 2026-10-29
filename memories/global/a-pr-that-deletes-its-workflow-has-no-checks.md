---
name: a-pr-that-deletes-its-workflow-has-no-checks
description: "A pull request that deletes a `pull_request` workflow reports NO checks — the workflow runs as defined in the MERGE ref, so it deletes the job that would report on it; a settle detector deriving its expected jobs from the BASE then reads NOT-GREEN forever"
metadata:
  node_type: memory
  type: reference
  scope: global
---

A `pull_request` workflow runs **as defined in the pull request's merge ref**, not as defined on the base branch. So a pull request whose whole point is to delete that workflow deletes the job that would have reported on it, and arrives with **no checks at all**. That is the correct outcome, not a broken one, and it is not the same fact as [[conflicted-pr-gets-no-ci]] — nothing is conflicting and nothing is misconfigured.

Two consequences worth knowing before the pull request is opened, because both look like failures:

- **A fail-closed settle detector says NOT-GREEN, permanently.** A detector that derives the expected job set from the base branch's workflow file (the right design everywhere else — see [[control-a-settle-detector-on-captured-output]]) will list jobs that can never register. Measured 2026-09-23: `workflows=['check.yml (base only)'] expected_jobs=['check','current','e2e'] → VERDICT: NOT-GREEN -- workflow jobs never registered`. Read that and say what replaces the signal; do not route around it, and do not widen the detector to make it green.
- **Checks from GitHub *apps* still run**, because they are not workflow jobs. A secret scanner or similar will report on the same head and is real evidence — keep it in the merge's evidence list.

The merge's evidence is then: the local run on that exact commit, the commit status attesting it (see [[a-pre-push-hook-cannot-attest-its-own-commit]]), whatever app checks did run, and the ordinary mergeability facts. Say the absence out loud in the pull request body, so the next reader does not wait for a tick that cannot appear.

The push to the default branch after such a merge runs nothing either — the branch loses its own direct watcher. That is the accepted consequence, and what replaces it (a pre-push hook on every branch, a deploy-time gate) has to exist before the deletion lands, not after.
