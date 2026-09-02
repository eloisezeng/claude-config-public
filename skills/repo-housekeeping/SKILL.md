---
name: repo-housekeeping
description: Sweep a fleet-managed repo's root for stray handoff.sh dispatch clutter (`.handoff-*.md`, `.dispatch*`, `*-artifacts/`) and per-round scratch (e.g. `TO-DO-N.md`), verify disposition against PRs and the `~/.claude/ops/` lane ledger, then archive or delete accordingly. Use this whenever the user asks to "organize", "clean up", or "tidy" a repo's loose/handoff/TO-DO files. Also apply it proactively — unprompted — whenever a repo root visibly has more than a handful of `.handoff-*`/`.dispatch*` files, even while doing unrelated work in that repo.
---

# Repo housekeeping (fleet scratch cleanup)

A repo worked by `handoff.sh` dispatches accumulates root-level clutter over weeks.
This includes `.handoff-*.md` docs, `.dispatch`/`.dispatch.flock`/`.dispatch.watch.*`/`.dispatch.alert.*.flock` control files, and `*-artifacts/` scratch directories.
Some projects also accumulate their own per-round feedback scratch (the your-project repo's convention is `TO-DO-N.md`, often git-ignored via `.git/info/exclude` so it never shows in `git status`).
None of this is visible to a casual glance, since it's either untracked (`??`) or locally excluded.
After a few weeks of fleet work this can reach 100+ files.

This is the general procedure. The worked example is the your-project repo's 2026-09-02 pass — see the global memory `[[organize-stray-handoff-and-todo-scratch]]` and the project memory `~/code/your-project/.claude/memory/your-project-repo-housekeeping-2026-09-02.md` (project memory lives in the project repo, not under a config root).

## Procedure

1. **Enumerate.**
   `git status --porcelain=v1 | grep '^??'` for untracked clutter.
   `git check-ignore -v <suspect files>` for anything hidden by `.gitignore` or `.git/info/exclude` — read `.git/info/exclude` directly too, it's local-only and won't show up in a shared `.gitignore` diff.
   Group files by dispatch or round: same basename prefix before `-r2`, `-r3`, etc., or the same `TO-DO-N` number.

2. **Determine disposition per group before touching anything.**
   Read the `.handoff-*.md` doc itself — it usually states its own STATUS line.
   Check `~/.claude/ops/lanes/*.md` for any `pointer:` field referencing the file or its dispatch group.
   If the doc names a branch or PR, verify with `gh pr list --repo <owner>/<repo> --state all --json number,title,headRefName,state`.
   Only proceed once every referenced PR is merged (or the doc/lane is explicitly closed) and no ops lane still needs the file as its `pointer:`.
   A `status: open` lane is a hard stop on deleting anything it points to — archive it instead, and see step 4.

3. **Archive or delete.**
   Substantive docs (`.md`, `.md.dispatch`) that record real decisions or findings → move to `~/.claude/ops/archive/<repo-name>/`, stripping the leading dot from the filename.
   Pure control/lock/watch/alert files (`.dispatch.flock`, `.dispatch.watch.*`, `.dispatch.alert.*.flock`) and `*-artifacts/` scratch directories → delete outright, nothing references them once the dispatch is closed.
   Project-specific scratch that seeded a real deliverable (e.g. a `TO-DO-N.md` round file that fed a spec under `docs/`) doesn't belong in `~/.claude/ops/archive/` — that directory is for handoff/dispatch records, not project content.
   Give it a **tracked** home inside the project instead (e.g. `docs/<convention>/todo-source/`), with a short README explaining what the files are and where the derived artifacts live.
   Leave any live, untriaged backlog file (e.g. a root `TO-DO.md` with no round number) exactly where it is.

4. **Repoint ops-lane pointers before or as part of the move.**
   `grep -rl '<old absolute path>' ~/.claude/ops/lanes/*.md` for every lane file whose `pointer:` targets a file you're about to move.
   Repoint each one to the new archive path (`perl -pi -e 's{<old path>}{<new path>}'` works fine for this).
   Verify afterward with `grep -n 'pointer:' <each file>`.
   This matters most for lanes still `status: open` — a still-open investigation whose pointer silently breaks is a lost thread, not just a stale link.

5. **Ship it as its own small commit/PR.**
   This kind of change touches nothing but scratch/doc paths, so keep it that way — don't fold in unrelated fixes.
   If the local checkout's `main` is behind `origin/main` (check with `git fetch origin main --quiet && git rev-list --left-right --count origin/main...HEAD`), don't push from local main directly.
   Cherry-pick the commit onto a fresh branch off `origin/main` instead — a job worktree via `EnterWorktree`, or `git worktree add`, keeps this from touching the shared checkout's HEAD — open a PR, and merge once green.
   It's mechanically safe to merge on green without asking: docs-only, no code/build/test paths touched — see `[[merge-green-prs-without-asking]]`.
   Once merged, fast-forward the local checkout's `main` to `origin/main` rather than leaving it permanently diverged.

## When NOT to use this

Don't fold in unrelated code fixes, don't delete anything still referenced by an open PR or an open ops lane, and don't touch a repo's live untriaged backlog file (a `TO-DO.md` with no round number, or equivalent) — this skill is for closed-out dispatch scratch only.
