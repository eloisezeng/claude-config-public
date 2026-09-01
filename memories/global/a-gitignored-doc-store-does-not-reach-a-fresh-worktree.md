---
name: a-gitignored-doc-store-does-not-reach-a-fresh-worktree
description: A dispatch whose charge lives under a gitignored path hands the implementer a file that is absent from its worktree; provision it or give an absolute path, and verify the read from the consumer's cwd
metadata:
  type: feedback
  scope: global
---

When dispatching an implementer into a **fresh worktree**, remember that a gitignored directory does
not travel with the branch. If the charge — the seat's only substantive instruction — lives under one
(`.superpowers/`, `docs/notes/` where ignored, a scratch plan dir), the relative path in the handoff
resolves to **nothing** at the other end.

Two outcomes, one of them silent and expensive: the seat improvises eleven fixes from the handoff's
one-line summary, or it burns its opening turns hunting the file across the filesystem. Measured
2026-09-01: an SDD implementer spent ten tool calls searching before it found the 13,949-byte charge
in the controller's worktree and read the right thing. It recovered, but only because it was
diligent; nothing in the dispatch made recovery likely.

**Do both of these:**

- Write the charge path in the handoff as an **absolute** path, not one relative to a worktree that
  may not contain it.
- **Provision the store into the worktree** and verify the read *from the consumer's cwd* before
  dispatching — `cd <worktree> && wc -c < <the relative path you wrote>`. This is
  [[verify-in-the-consumers-condition]]: a read that works from your own worktree tests your worktree.

**The git subtlety in the fix, which is the reusable part.** A `.gitignore` pattern ending in `/`
matches **directories only**, and git does not follow symlinks — a symlink is a file to git, not a
directory. So symlinking the ignored root itself (`ln -s … <worktree>/.superpowers`) leaves an
**untracked** entry that dirties `git status` and is one `git add -A` away from being committed.
Instead make the ignored parent a **real** directory and symlink the leaf inside it:

```sh
mkdir -p "$W/.superpowers/sdd"
ln -sfn "$CANON/.superpowers/sdd/<plan>" "$W/.superpowers/sdd/<plan>"
git -C "$W" status --porcelain | wc -l    # must still be 0 — assert it, don't assume it
```

Symlinking the leaf also means the implementer's report lands in the canonical store the controller
reads, so there is no copy-back step to forget.

Related: [[verify-in-the-consumers-condition]], [[vendor-what-the-code-searches-for]],
[[isolate-agents-that-mutate-the-tree]], [[verify-claims-against-artifacts]].
