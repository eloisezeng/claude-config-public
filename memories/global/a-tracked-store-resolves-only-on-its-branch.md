---
name: a-tracked-store-resolves-only-on-its-branch
description: a symlink pointing into a git-TRACKED directory resolves only while a branch containing it is checked out, so a sibling's branch switch silently empties it — land such a store on the DEFAULT branch and verify the branch you commit to is not stale
metadata:
  type: feedback
  scope: global
---

Moving Claude's project memory into the repo (`[[project-memory-lives-in-the-project-repo]]`) makes the harness path a symlink into a **tracked** directory. That directory exists only on branches whose commit contains it. So the link's validity is a property of *whatever branch happens to be checked out*, not of the repo.

Measured, your-web-app-2026, 2026-09-04: I committed the store to the branch that was checked out (`deploy/fly-docker`), verified every link green, and pushed. Minutes later a parallel actor checked out `main` in the same shared clone. Git removed the tracked files, and the symlink went dangling — memory silently loaded **nothing**, which is strictly worse than the plain folder I had replaced. Every check I had run was still true when I ran it.

Two rules:

- **Land a branch-tracked store on the DEFAULT branch**, never on whatever is checked out. Before treating the current branch as the live one, measure it: `git rev-list --left-right --count origin/main...HEAD` said `75 1` — main was 75 commits ahead and my branch's only unique commit was my own, i.e. I had committed onto a stale branch and read it as current. `git status` looks identical either way.
- **A shared clone has other writers.** Anything you verify about its working tree is a snapshot, not a latch — the same class as `[[a-state-guard-is-a-snapshot-not-a-latch]]`. Do the work in your own worktree, and prefer a repair tool that is idempotent and *re-runnable* over a one-shot migration, so the next actor's branch switch is a nuisance rather than data loss.

The recovery that matters: make the tool that creates the link also **fold** a pre-existing real directory into the store — dropping files the store already has identically, moving in ones it has never seen, and aborting with both copies intact on any genuine difference. Then the broken intermediate state repairs itself on the next run instead of needing a human to reconcile by hand — `[[recoverable-is-not-unused]]`.
