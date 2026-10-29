---
name: a-write-run-may-write-everything-and-commit-nothing
description: A codex `--write` run can finish its task correctly and still exit 4 with the work uncommitted, because a linked worktree's git metadata sits outside the sandbox — read the launcher's `files changed` list, never its exit code alone
metadata:
  type: feedback
scope: global
---

A `run-codex.sh --write` run that exits **4** with `WRITE RUN LEFT AN UNCOMMITTED TREE -- task
FAILED, quarantined` has not necessarily failed its task.
Measured 2026-10-26 on Codex CLI **0.162.1**: the run wrote both its files, ran its test red (naming
the exact count that failed) and green, quoted both outputs — and then died at
`fatal: Unable to create '.../index.lock': Operation not permitted`.

The cause is structural rather than incidental. A linked worktree's git metadata lives under the
PRIMARY repository's `.git`, outside the `workspace-write` sandbox rooted at the worktree — and
`--write` *requires* a linked worktree, refusing the primary checkout. `run-codex.sh:511-515` grants
the common dir as a writable root for exactly this reason, and its own comment records that grant as
"verified 2026-08-07". That is an inherited measurement against an older CLI, and it is now the
whole failure: a config key the CLI has renamed, or a single-root grant that REPLACES the default
workspace root instead of adding to it, both read identically from the outside.

**So gating a `--write` run on COMMITS is right and is not sufficient.** The gate exists because a
lane that answers with a design and stops writes nothing, exits 0 with a clean tree, and is
indistinguishable from a no-op on every mechanical signal — `[[a-write-run-may-answer-with-a-design-and-stop]]`.
This is the opposite failure wearing the same exit code: everything done, nothing committed. The
signal that separates them is the `files changed` list the launcher prints beside `commits made:`.
An empty files list with no commits is the design-and-stop failure; a populated files list with no
commits is work you already own and must review and commit yourself.

Do not route around it by pointing `--write` at the primary checkout. Try your own
`-c sandbox_workspace_write.writable_roots=[...]` naming both the worktree and the primary `.git`
(the launcher's grant is prepended, so a later one wins), on ONE small task before queueing six;
check whether the key was renamed; and otherwise accept that Codex writes and Claude commits,
knowing you have traded away the gate and must read the files.

The general shape is `[[an-inherited-environment-fact-is-a-stale-measurement]]`: a comment saying
"verified" names a date and a version, and a launcher's sandbox grant is exactly the kind of fact a
vendor CLI upgrade silently retires while every other signal stays green.
