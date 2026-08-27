---
name: github-desktop-autostashes-on-branch-switch
description: "GitHub Desktop silently auto-stashes uncommitted changes on a branch switch, so in-progress edits 'vanish' with no error — check the stash before concluding work was lost"
metadata:
  node_type: memory
  type: reference
  scope: global
---

GitHub Desktop auto-stashes uncommitted changes when you switch branches, parking them in a stash named `!!GitHub_Desktop<branch>`.
There is no error and no prompt — the working tree simply comes back without your edits, which reads exactly like data loss or a bad checkout.

A second failure mode compounds it: editing files *while* a branch switch or pull is in flight collides with the operation, and the half-written edit is what gets stashed.

**How to apply.**
When files "vanish" from a repo managed by GitHub Desktop, check `git branch --show-current` and `git stash list` **before** re-doing the work or hunting for a bug — the edits are almost always sitting in a `!!GitHub_Desktop*` stash.
Don't edit files while a switch or pull is running, and commit promptly: only uncommitted changes are exposed to this.

Also worth knowing on these repos: a session's environment banner may report `Is a git repository: false` even when the directory *is* a git repo managed by GitHub Desktop, so verify with `git` rather than trusting the banner — `[[act-on-fresh-state-anchor-by-identity]]`.
