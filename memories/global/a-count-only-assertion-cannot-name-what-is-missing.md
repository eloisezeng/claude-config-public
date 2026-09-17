---
name: a-count-only-assertion-cannot-name-what-is-missing
description: `expected 283 to be 285` is a fail-open report — it gives the next session nothing to act on; and a set-vs-set assertion whose two sides are derived from DIFFERENT trees calls the disagreement a defect, which on a PR is the checked-out merge ref versus the head sha
metadata:
  type: reference
  scope: global
---

Two defects usually ship together in one assertion, and the cheap one hides the expensive one.

**The cheap one: the message.** `expect(corpus.length).toBe(names.size)` fails as `expected 283 to be 285`. That is a fail-open report in the sense that matters — it names no member, so the next session has nothing to act on, and the entire cost of the incident is the forty minutes spent working out which two. Intersect rather than count, and make the message NAME the difference. Where dropping an absent member is genuinely correct (a DELETED file ships no snapshot API), say so in the assertion and keep a lower bound so the clause cannot go vacuous.

**The expensive one: the two sides read different trees.** Measured 2026-09-04 (lane `phase0-guard-reddens-between-a-main-delete-and-a-merge`): the name list came from `git diff --name-only <base> <SUBJECT>` where `SUBJECT` is the PR HEAD sha, and the file list came from `git ls-files` over the checkout — which on a pull request is `refs/pull/N/merge`. At main: 275 named, 0 untracked, clean. At the branch tip: 285 named, 0 untracked, clean. **At the MERGE of the two: 285 named, 283 tracked, RED.** Main had deleted two test files created after the base, so they are absent at both ends of `base..main` and never named there, but they ARE named across `base..branch` because the branch predates the deletion. The guard is not wrong about anything; it is measuring two trees and calling the disagreement a defect.

**Derive both sides from ONE tree.** On a PR that means diffing against the ref the file lister is actually reading, not against a sha that may name a different tree. Merging main into the branch made both reads agree and took the guard from red to 35 of 35 green with no edit to the guard, which is the proof that the guard was never the bug.

There is a diagnosis trap worth knowing, and it cost most of the forty minutes: run locally, the subject resolves to `HEAD`, so immediately after resolving conflicts but BEFORE committing the merge the guard is still red — `git ls-files` already reads the merged index while `HEAD` is the pre-merge commit. That red looks exactly like the CI red and has a different cause. **Commit first, then measure.**

Every long-lived branch hits this the moment main deletes any file the guard's base-relative name list covers, and the red is indistinguishable from the real violation the guard exists to catch.

Related: `[[replacing-a-list-with-a-glob-changes-the-set]]`, `[[merge-clean-is-not-merge-correct]]`, `[[a-tail-window-is-not-a-failure-report]]`, `[[a-guard-must-be-satisfiable-not-just-failable]]`, `[[counting-a-set-is-not-classifying-it]]`.
