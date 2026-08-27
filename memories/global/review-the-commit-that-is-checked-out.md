---
name: review-the-commit-that-is-checked-out
description: when a reviewer is pointed at a commit SHA, re-resolve HEAD at launch and re-check it when the verdict lands — an amend mid-review voids the verdict in BOTH directions
scope: global
metadata:
  type: feedback
---

When dispatching a review at a **commit** (rather than a working tree), never hard-code the SHA into the prompt. Resolve HEAD at launch, and re-resolve it when the verdict lands — if HEAD moved, the verdict is void and must be re-run, not reported.

**Why:** I made this mistake twice in one session (2026-07-29), the second time roughly two hours after writing the first one down as a lesson. Remembering it did not work; the guardrail has to be mechanical.

It fails in **both** directions, which is what makes it dangerous:

- **A HIGH that is already closed.** The reviewer reports a defect I fixed in the amend. Cheap to detect — I go to verify it and find the fix already there — but it burns a full round and invites arguing with a correct reviewer.
- **A "NO HIGH FINDINGS" that is VOID.** Far worse, and silent. The clean verdict describes a commit that lacks the very fix it should have judged, and it *looks* like convergence. I nearly reported one as evidence the change was sound.

**How to apply:** use a launcher that substitutes a `__HEAD__` token from `git rev-parse` at dispatch time and compares `HEAD` before/after, refusing the result if it moved (`.run-codex-on-head.sh` in the your_other_project repo is the reference implementation, wrapping the watchdogged launcher). Reviewing the uncommitted working tree does not have this problem — the hazard is specific to naming a commit and then rewriting it.

Corollary: when a reviewer's finding cites code you believe you changed, **check which SHA it read before assuming it is wrong**. Same evidence discipline as [[verify-claims-against-artifacts]] — the reviewer may be right about a commit that no longer exists.

Related: [[codex-exec-hang-watchdog]], [[verify-claims-against-artifacts]], [[execution-verification-prefs]]
