---
name: config-sync-commits-onto-detached-head
description: The claude-config auto-sync commits onto a detached HEAD when a rebase is interrupted, landing git conflict markers as CONTENT in the always-loaded instruction files
scope: global
metadata:
  type: reference
---

`~/claude-config` (symlinked into `~/.claude`) is kept current by an auto-sync that commits on a timer. If a `git rebase main` is ever interrupted, the repo stays on `(no branch, rebasing main)` and **the sync keeps committing onto that detached HEAD** — indefinitely, with `main` frozen at the pre-rebase commit.

The visible symptom is worse than a stale branch: because the rebase's conflicts were never resolved, the sync `git add`s the conflicted files verbatim, so `<<<<<<< HEAD` / `=======` / `>>>>>>>` markers get **committed as file content** into `CLAUDE.md` and `memories/global/MEMORY.md` — the two files loaded into every session. They read as broken, ambiguous instructions and can sit there for days unnoticed.

**Why it matters:** found 2026-08-18 with markers dating from 08-17, on a rebase interrupted 08-16 — 12 sync commits stacked on the detached HEAD, `main` 10 behind `origin/main`.

**How to apply:**
- If `CLAUDE.md` or the memory index shows conflict markers, check `git -C ~/claude-config branch` for `(no branch, rebasing ...)` before editing anything — the markers are a symptom, not the bug.
- Resolve the marker text immediately (it is live the moment it is on disk, since these files are read from the filesystem). These conflicts are usually **additive** — each side lists a different memory or directive — so the correct resolution is the UNION, not a choice. Only a genuine same-line rewrite needs judgement.
- Do NOT `rebase --abort` to tidy up: it discards every sync commit made since the rebase began, plus uncommitted work. Name the line first (`git branch <rescue> HEAD`) so nothing can be garbage-collected, and back up uncommitted files, then let you decide between `--continue`, resetting `main` to the rescue ref, or something else.
- The sync script itself needs a guard that refuses to commit while `.git/rebase-merge`/`rebase-apply` exists, or while HEAD is detached — otherwise it will re-create this state.
