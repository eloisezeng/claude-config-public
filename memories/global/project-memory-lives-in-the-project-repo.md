---
name: project-memory-lives-in-the-project-repo
description: per-project Claude memory belongs in the project's own repo at .claude/memory/ (tracked) with the harness path as a SYMLINK, not copied into the config repo — one home per fact, and the local .git/info/exclude rules it relies on do not travel with a clone
metadata:
  type: feedback
  scope: global
---

The user, 2026-09-02: "shouldn't the project memories go in the your-project repo not the claude-config?"
She is right, and the reasoning generalizes to every private project repo.

Per-project memory is project documentation.
It belongs at `.claude/memory/` **inside the project repo**, tracked, so a clone carries it, it versions next to the code it describes, and a memory that goes stale shows up in the same diff neighborhood.
The config repo (`claude-config`) keeps only `scope: global` memories.

What a clone cannot do is put it where Claude Code reads: that path is `<config-root>/projects/<abs-path-with-every-/-replaced-by-->/memory/`, derived from the clone's absolute path.
So make the harness path a **directory symlink** into the clone — never a copy.
A copy gives one project two homes that drift apart silently.
`sync-memories.sh` will not fight this: `find -P -type f` does not descend a symlinked directory (verified with a `-L` control that DID see the file).

Three traps, all measured on the your-project repo:

- **Two config roots orphan memory.** Three your-project memories sat under `~/.claude` while every session read `~/.claude1` (`CLAUDE_CONFIG_DIR`). They went unseen for ~5 weeks, and one was an OPEN decision awaiting the user. Link every root the machine uses at the same target, and when you find memories under an unused root, fold them in rather than leaving them.
- **`.git/info/exclude` does not travel with a clone.** Making `.claude/` a tracked directory means the harness runtime state under it (`worktrees/`, `checkpoints/`, `mailbox/`, `scheduled_tasks.*`, `agent-registry.json`, …) must be excluded by NAME in the tracked `.gitignore`. Control it both directions with `git check-ignore -v`, which names the matching FILE — a rule still in `info/exclude` looks green locally and is absent on the second machine.
- **The project repo does not auto-commit.** `claude-config` has a launchd watcher; a project repo does not. A memory written mid-session sits uncommitted until someone commits it. It is visible in `git status`, but it is a manual step — say so rather than assuming the sync that exists for global memories.

Before deleting the old copy, enumerate its dependents and assert the dangling-symlink count is unchanged in the SAME script that deletes — `[[recoverable-is-not-unused]]`.
Secrets are the opposite case and never move: commit name-only `.env.example` templates derived from the config loader that validates them, and hand-carry the values — `[[a-gitignored-doc-store-does-not-reach-a-fresh-worktree]]`.
