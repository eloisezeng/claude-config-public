---
name: a-linked-config-file-can-become-a-copy
description: A config path the installer SYMLINKS can silently become a regular file — edits then reach only this machine, and re-linking discards them; check readlink before trusting an edit, and merge before you re-link
scope: global
metadata:
  type: feedback
---

`~/dotfiles/claude/install.sh` symlinks `ITEMS=(CLAUDE.md AGENTS.md bin skills/…)` into `~/.claude`.
Measured 2026-08-26: `~/.claude/CLAUDE.md` was a **regular file**, not that symlink, and 12 working directives written into it since 2026-08-22 existed on this machine only.

**Why it stayed invisible.**
Each of those directives has a memory BODY under `memories/global/`, and that directory *is* edited in the repo and *is* a `sync.sh` WatchPath, so the bodies all pushed normally.
Only the one-line imperatives in `CLAUDE.md` diverged, and nothing compares the two halves — a memory whose body is in the repo reads as fully saved.
The same shape hides any linked path that has been replaced by a copy: the edit lands, the file is loaded, and nothing fails.

**How to apply:**
- Before trusting that an edit to a path the installer manages has reached the repo, run `ls -l` / `readlink` on it. A regular file where a symlink belongs is a one-way divergence, not a warning — `[[verify-claims-against-artifacts]]`, and the same instinct as reading the file the PROCESS runs in `[[an-armed-watcher-holds-its-boot-config]]`.
- **Repair is ordered, and the order is the whole safety property.** `diff` the live file against the repo copy, land the live-only content in the repo first, and only then restore the link (`ln -sfn <repo>/CLAUDE.md ~/.claude/CLAUDE.md`, or re-run `install.sh`). Re-linking first silently replaces the live file with the repo's older one; nothing is backed up and nothing says a word.
- Re-linking a file other sessions are actively reading is a live change to their instructions, so it belongs with the merge that carries the content — not slipped in beforehand.
- The general form: **an edit reaches the repo only while the path is still the link.** Where the two halves of one fact live in different files (a directive line and its memory body), a partial sync looks exactly like a complete one — `[[extract-learnings-proactively]]`.
