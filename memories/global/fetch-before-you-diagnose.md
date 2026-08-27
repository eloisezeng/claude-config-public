---
name: fetch-before-you-diagnose
description: Fetch and read the code at origin/HEAD before diagnosing or building — a stale local checkout makes you re-diagnose and re-fix what a teammate already merged
metadata:
  type: feedback
scope: global
---

`git fetch` and read the target file **at `origin/HEAD`** before investing in a diagnosis or a build — not merely before creating the branch.

**Why:** on 2026-08-10 a full root-cause investigation of a production dashboard outage (profiling, live-DB probes, EXPLAIN, a measured 635× index-plan finding) was carried out against a working tree three commits behind `origin/main`.
The exact fix had already been merged by a sibling session as PR #254 and had finished deploying six minutes earlier.
The diagnosis was correct and independently reproduced, but the build was pure duplicate work; the worktree, the branch and the green baseline all had to be thrown away.
A stale checkout does not announce itself — the code reads as broken, because locally it is.

**How to apply:**
- Before diagnosing: `git fetch origin <base> && git log --oneline -5 origin/<base> -- <the file you suspect>`. A commit message naming your symptom means stop and read it first.
- Read the suspect code from the fetched ref (`git show origin/main:path/to/file`) or from a worktree at that SHA — never assume the local copy is current.
- When the symptom is live/production, also check whether a fix is merged-but-undeployed before writing any code: that turns a "build" into a "verify the deploy landed", which is minutes instead of hours.
- Says nothing about whether your diagnosis was wrong — reproduce and report it anyway; it is what verifies the merged fix actually cures the symptom.

Related: [[watch-the-run-you-triggered]] (confirm the deployed artifact carries the change, don't trust the green tick), [[review-the-commit-that-is-checked-out]].
