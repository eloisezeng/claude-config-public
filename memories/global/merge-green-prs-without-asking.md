---
name: merge-green-prs-without-asking
description: The user 2026-08-19 — never block a green PR on her approval; merge whenever mechanically safe, with interlocks and post-merge verification unchanged
scope: global
metadata:
  type: feedback
---

The user, verbatim (2026-08-19, after PR #301 sat green waiting on her word): **"don't ask for my approval to merge. always merge if possible."**

**Why:** Approval-gating merges was my practice, not her ask — it converted finished work into an open item on her plate. Her standing autonomy directives ([[standing-directives-are-standing-requests]], [[a-report-is-not-a-stopping-point]]) already meant approved work runs to completion; this closes the one exception sessions kept carving out.

**How to apply:**
- "If possible" means **mechanically safe**, not unconditional: required checks green on the current head, freeze/interlock signals clear (🟢 CLEAR, not UNKNOWN), no deploy or box-side long-running work in flight ([[merging-is-restarting-production]]), no conflict, and the head you merge is the head that was reviewed ([[review-the-commit-that-is-checked-out]]). If any of those is red, fix or wait — that is "not possible", not a reason to ask her.
- Post-merge duties unchanged: watch the deploy run pinned by YOUR merge SHA and verify the deployed artifact carries the change ([[watch-the-run-you-triggered]]).
- This supersedes the older await-her-word practice recorded in many session memories and handoffs; where a handoff says "hand back unmerged / stop before merge", merge instead once green — unless the PR belongs to another live session (don't grab a sibling's work).
- Decisions that remain hers are unchanged (new spend beyond approved envelopes, product/aesthetic picks) — but don't block the merge on them: ship the recommended default and make her pick a cheap follow-up.
