---
name: stage-immediately-verify-commits-from-the-object
description: Where parallel agent sessions share one .git, the working tree can be rewritten under you — stage edits immediately and verify commits from the object, never the tree
scope: global
metadata:
  type: feedback
---

When several agent sessions work in git worktrees off one shared `.git`, a working tree can be
rewritten by a process that is not you, mid-task, with no trace in your transcript or your reflog.

**Write → `git add` IMMEDIATELY → then run tests or anything else.** The index is immune to
working-tree rewrites, so `git checkout -- .` restores your own content from it.

**Verify every commit from the object, not the tree:** `git show HEAD:<file>`. The dangerous failure
is not a lost edit — it is a commit that captured *reverted* content, so its message describes
changes it does not contain. That survives review, because reviewers read the message and the diff of
what is there, never the diff of what should have been.

Measured on `your_other_project`, 2026-08-11: one session had four coherent edits appear in its
worktree between its own; a `git stash list` entry from 2026-07-27 (`concurrent-edits-not-mine`)
showed the same signature on a different branch — recurring, not a one-off. It lost two commits this
way before switching to stage-first.

**Mostly resolved, and the answer was self-inflicted — which is the usual answer.** The RECURRENCE
was a backup taken while the file was already contaminated: `cp src/x.ts /tmp/s5.bak` mid-task, then
`cp /tmp/s5.bak src/x.ts` later, restoring the contamination and making one event look like many.
**A backup captures the state at backup time, including damage you have not noticed yet; restoring it
reintroduces that damage.** Only the four first appearances stayed unexplained, which is a far smaller
claim than the "something is semantically targeting my work" it was nearly written up as.

Two hazards found on the way, both worth acting on:

- **Namespace scratch files by session id** (`/tmp/$SESSION/...`). Two sessions independently used
  `/tmp/s5.bak` and `/tmp/s6.bak` for different files in different worktrees. With ten concurrent
  sessions, a fixed scratch filename collides eventually.
- **A non-recursive transcript glob is not an absence-proof.** `~/.claude/projects/*/*.jsonl` misses
  nested dirs AND every subagent transcript (`agent-*.jsonl`); recursive was 21,107 files. Searching
  by *worktree path* also misses writes made through Bash (`sed -i`, a heredoc, `python3 -c open(…)`),
  which carry no `file_path` field at all. Search by the injected STRING and by write-op-plus-basename.

**Every external-actor candidate was disproven by reproduction** — record that rather than reaching
for the next theory:

- Codex `-s read-only` — writes blocked (canary untouched).
- Codex `--write` — confined to `-C <workdir>` for relative AND absolute paths alike; the child's cwd
  is the target, not the caller's. Tested with two canaries from a shell sitting in a *different*
  worktree, which separates "model used a relative path" from "sandbox root is wrong". Both landed in
  the target. **This was my hypothesis and it is wrong.**
- Any Claude session's Edit/Write into the victim worktree — none, across all transcripts.
- Reflog-visible git operations, and hooks — clean.

**But `workspace-write` is NOT confined to the workspace:** a `--write` run appends a
`[projects."<path>"] trust_level` entry to `~/.codex/config.toml`. Harmless, and not this culprit
(the mystery writes are repo source), but it disproves "the sandbox only touches the workspace" as a
general claim, and throwaway worktrees permanently accrete trust entries.

Diagnostic that redirected the whole investigation: **grep every branch for a distinctive string from
the mystery edit.** If it exists on exactly one branch — the victim's — no other session authored it,
which rules out "a peer wrote into my worktree" and points inside the checkout.

Related: [[github-desktop-autostashes-on-branch-switch]] (same "files changed under me" signature,
different cause), [[verify-claims-against-artifacts]], [[fetch-before-you-diagnose]].
