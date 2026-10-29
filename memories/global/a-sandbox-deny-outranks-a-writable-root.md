---
name: a-sandbox-deny-outranks-a-writable-root
description: Codex 0.162.1's workspace-write sandbox refuses writes under any `.git` even when that exact path is granted as a writable root, so a `--write` run writes its files and cannot commit — gate on the launcher's file list, never its exit code
metadata:
  type: reference
scope: global
---

A sandbox DENY outranks a sandbox GRANT, so re-granting a path that is already granted proves
nothing and fixes nothing. Measured 2026-10-26 on Codex CLI **0.162.1**: a `--write` run in a
LINKED git worktree writes every file correctly, runs its test red then green, and then dies with
`fatal: Unable to create '<primary>/.git/worktrees/<name>/index.lock': Operation not permitted` —
although `run-codex.sh` already passes that exact directory as `sandbox_workspace_write.writable_roots`
and its own comment records the grant as verified against an older CLI. Passing the same roots again
on the command line, where a later `-c` wins, changes nothing.

The cause is a new permissions layer, read from the shipped binary's strings: a permission-path enum
holding the literal `/.git` beside `read` / `write` / `deny`, plus config keys `default_permissions`,
`permissions` and `permissions.filesystem.deny_read` that the launcher never mentions. Two controls
separate this from the obvious wrong diagnoses — `touch` into the same directory from outside the
sandbox succeeds, so it is not a filesystem permission; and the worktree's OWN files were written,
so it is not a missing workspace root.

**Why:** an inherited "verified working" comment is a measurement against the version that was
current when it was written, and a sandbox's deny list is exactly the kind of thing a minor release
adds. The grant was never the variable.

**How to apply:** when a write-mode agent run reports failure, read the launcher's `files changed`
list and the written files, never the exit code alone — a run that wrote correctly and could not
commit is indistinguishable from a no-op on exit status. Accept the split contract (the agent
writes, you review and commit) rather than routing around the sandbox, and drive it from a script
that takes the task's ALLOWLIST as arguments so it stages only those paths and leaves anything else
visible and unstaged. Have the agent write its intended commit message to a file INSIDE the
workspace: a scratch directory elsewhere on disk is outside the sandbox too and gets
`patch rejected: writing outside of the project`. Related: `[[a-write-run-may-answer-with-a-design-and-stop]]`,
`[[codex-may-implement-never-self-review]]`, `[[verify-claims-against-artifacts]]`.
