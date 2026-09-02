---
name: organize-stray-handoff-and-todo-scratch
description: fleet-managed repos accumulate handoff.sh dispatch docs/control files and per-round TO-DO scratch at repo root — archive or track them once their lane closes, never delete outright without checking disposition first
metadata:
  type: feedback
  scope: global
---

A repo worked by `handoff.sh` dispatches accumulates root-level clutter over weeks.
This includes `.handoff-*.md` docs, `.dispatch`/`.dispatch.flock`/`.dispatch.watch.*`/`.dispatch.alert.*.flock` control files, and `*-artifacts/` scratch directories.
Some projects also accumulate their own per-round feedback scratch (the your-project repo's convention is `TO-DO-N.md`, git-ignored via `.git/info/exclude` so it never shows in `git status`).
None of it is visible to a casual glance, since it's either untracked (`??`) or locally excluded.
After a few weeks of fleet work this can reach 100+ files.

**Established convention (your-project repo, 2026-09-02, ~130 files, landed as PR #62):**

1. For each `.handoff-*` doc/dispatch group, determine disposition before touching it.
   Check `~/.claude/ops/lanes/*.md` for a `pointer:` referencing it, check the doc's own STATUS line, and cross-check any named branch/PR via `gh pr list --state all`.
   Only archive once every referenced PR is merged (or explicitly closed) and no ops lane still needs the file.
2. Substantive docs (`.md`, `.md.dispatch`) → move to `~/.claude/ops/archive/<repo-name>/`, stripping the leading dot.
   This matches the existing archive precedent (`~/.claude/ops/archive/your-project/clickable-counts-r3.handoff.md` predates this cleanup).
   Pure control/lock/watch/alert files and `*-artifacts/` scratch dirs → delete outright, nothing references them once the dispatch is closed.
3. **Before moving a file, `grep -rl` its old path across `~/.claude/ops/lanes/*.md` `pointer:` fields and repoint every hit to the new archive path.**
   A lane's `pointer:` is its record-of-truth; moving the file without repointing breaks the lane's audit trail.
   This matters most for lanes still `status: open`, not just closed ones — an open investigation whose pointer silently breaks is a lost thread.
4. Project-specific scratch that seeded a real deliverable (e.g. this project's root `TO-DO-N.md` verbatim-feedback files, one per round) doesn't belong in `~/.claude/ops/archive/` — that directory is for handoff/dispatch records, not project content.
   Give it a **tracked** home inside the project instead (e.g. `docs/<convention>/todo-source/`), with a short README explaining what the files are and where the derived artifacts (specs/plans) live.
5. Ship the reorganization as its own small, isolated commit/PR — it touches nothing but scratch/doc paths, so it's mechanically safe to merge on green without turning it into a bigger refactor.
   If the local checkout's `main` turns out stale relative to `origin/main` (check with `git fetch origin main --quiet && git rev-list --left-right --count origin/main...HEAD`), don't push from local main directly — cherry-pick the commit onto a fresh branch off `origin/main`, open a PR, and merge once green instead.

**Why:** discovered when asked to "organize the files e.g. handoffs and TO-DOs" on `your-project`.
130+ untracked root files, all safe to archive, but 6 ops-lane files pointed directly at one of them, 2 of those lanes still open.
Missing step 3 would have silently orphaned two live investigation threads.

**How to apply:** run this sweep periodically on any fleet-managed repo, not just when asked — root-level `.handoff-*` clutter is a signal the repo hasn't been swept in a while.
See [[fleet-burn-budget]] for the adjacent finding that handoff docs are also the single biggest read-cost line item, a second reason to archive them out of the working tree rather than leave them for every future session to `ls`/`git status` past.
The reusable procedure is packaged as the `repo-housekeeping` skill (`~/dotfiles/claude/skills/repo-housekeeping/`).
