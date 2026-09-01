---
name: a-merge-command-can-report-failure-after-succeeding
description: gh-axi/gh `pr merge` can exit NON-ZERO from a LOCAL post-merge step while the server-side merge already succeeded — never retry a merge on the command's exit code, read the wire
metadata:
  type: reference
  scope: global
---

`gh-axi pr merge` (and `gh pr merge`) does two things: the server-side merge, then LOCAL cleanup —
`--delete-branch`, which runs git in your checkout. When that local half fails the command exits
non-zero **after the merge has already landed**.

Measured 2026-08-31 on your-other-project PR #331: the command reported
`fatal: 'main' is already used by worktree` — a purely local worktree collision — while the PR was
already `merged` on the server with `mergeCommit cf5e1dbc`.

**Never conclude "the merge failed" from the exit code.** Confirm against the wire before retrying:

```
gh-axi pr view <N> --json state,merged,mergeCommit
git ls-remote origin main
```

A retry driven by the exit code is a second merge attempt on a PR that already merged — and where a
push to `main` auto-deploys, that is a second production restart. This bites hardest in repos with
many sibling worktrees sharing one `.git`, which is exactly where the local step fails.

Same shape as [[verify-claims-against-artifacts]]: a status flag is not the artifact. Related:
[[merging-is-restarting-production]], [[watch-the-run-you-triggered]].
