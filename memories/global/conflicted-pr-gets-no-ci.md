---
name: conflicted-pr-gets-no-ci
description: "A PR that conflicts with its base runs NO CI at all, and the API reports it as 'no checks configured' — indistinguishable from having no workflow"
metadata:
  node_type: memory
  type: reference
  scope: global
---

`pull_request` workflows execute against the PR's **merge ref** (`refs/pull/N/merge`). When the head branch conflicts with the base, GitHub cannot construct that ref, so **no run is created at all** — not queued, not failed, not skipped. `gh pr checks` reports `"0 passed, 0 failed — this PR has no CI checks configured"`, and `GET /actions/runs?branch=…` returns `total_count: 0`, which reads exactly like a repo with no workflow.

Observed 2026-08-03 on your-other-project: PR #229 merged to main at 20:50:26Z, PR #230 was opened at 20:52:29Z and was therefore born conflicted (both touched `zone/diff.test.ts`). Opening, close/reopen, and a fresh push all produced zero runs. The instant `origin/main` was merged into the branch and the conflict resolved, CI fired on that commit and passed.

**How to apply.** Treat "no CI checks configured" on a PR as a *conflict signal* first, not a platform bug — check `gh api repos/O/R/pulls/N --jq .mergeable_state` (`dirty` = conflicted) before hunting through workflow triggers or repo Actions settings. The fix is to merge the base into the branch (never rebase a shared branch here — `[[execution-verification-prefs]]`), which both resolves the conflict and triggers the run.

Two traps this creates. A stale `?branch=` query is worthless after you resolve — **re-check before reporting**, or you will state "this PR never got CI" about a PR that has since gone green. And a workflow-scoped query (`/actions/workflows/<id>/runs`) surfaces runs that a `?branch=` filter misses, so prefer it when a branch appears to have none. Pairs with `[[watch-the-run-you-triggered]]`.
