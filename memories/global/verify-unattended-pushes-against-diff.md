---
name: verify-unattended-pushes-against-diff
description: "Never let a loop/auto-sync push to a shared remote on the strength of its commit message — gate on the actual diff stats"
metadata:
  node_type: memory
  type: feedback
  scope: global
---

When a `/loop`, auto-sync, or any unattended session pushes to a shared remote, do not assume the commit message reflects the diff.

**Why:** an auto-pushed commit titled "docs(r5): add HANDOFF.md" (`ffb76fbfc` in playground_test) actually deleted the entire 21,163-file codebase; it sat undetected on origin/main because the message read like a routine doc add, blocking every collaborator.

**How to apply:**
- Gate auto-pushing loops on a sanity check like `git diff --stat HEAD~1 HEAD` and bail when the change size wildly disagrees with what the message implies.
- Interactive pushes to a shared remote: show `git log --stat -1` (not just the message) before pushing; don't auto-push to shared `main` without explicit per-action authorization.
- Picking up a stale repo: run `git ls-tree -r HEAD | wc -l` early — a sudden drop in file count is the first red flag.
