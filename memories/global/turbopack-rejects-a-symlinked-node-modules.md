---
name: turbopack-rejects-a-symlinked-node-modules
description: A git worktree needs its own real node_modules — Turbopack refuses a symlinked one; clone it with `cp -c -R` on APFS, and never replace the primary checkout's copy
metadata:
  type: reference
  scope: global
---

Setting up a git worktree for a Next.js app, the cheap move is to symlink `node_modules` at the
primary checkout. **Turbopack rejects that** — it resolves modules through the real path and the dev
server fails rather than falling back. It is also the shape that puts the tree outside a Codex
`workspace-write` sandbox, so it fails twice for unrelated reasons —
[[codex-may-implement-never-self-review]].

**How to apply:** give the worktree its own directory, cloned rather than copied. On APFS
`cp -c -R <primary>/node_modules <worktree>/node_modules` is a copy-on-write clone: near-instant and
near-zero disk until something diverges. Confirm with `ls -ld` that both paths are directories, not
links.

**And never replace the PRIMARY checkout's `node_modules`** while doing this. It is itself an APFS
clone that other worktrees and the user's own dev server resolve through; deleting and reinstalling
it to "fix" a worktree breaks the tree that was working — [[recoverable-is-not-unused]].
