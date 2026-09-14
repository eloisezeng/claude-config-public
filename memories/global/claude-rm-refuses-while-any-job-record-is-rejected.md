---
name: claude-rm-refuses-while-any-job-record-is-rejected
description: "`claude rm <id>` with a discard/force flag refuses (\"couldn't verify that no other session's record names this directory\") while ANY ~/.claude/jobs record fails the loader — find those by diffing state.json folders against `claude agents --json --all`, park them, rm, restore; plus how to build the flag values"
metadata:
  type: reference
  scope: global
---

**`claude rm <id> --discard-unpushed …` or `--force-remove-worktree …` refuses with reason `records_unreadable` while any job record in `~/.claude/jobs/` is one the product's loader rejects — even a record that has nothing to do with the target worktree.**

**Why:** with either flag, `deleteJob` scans every sibling record (settled or not) to prove no other session names the worktree it is about to discard; a folder whose `state.json` exists but fails the loader (schema/size) returns null, and the scan fails CLOSED. Folders with no `state.json` at all (spare-process folders, old debris holding only `tmp/`) are skipped and are NOT the cause. Plain `claude rm <id>` on a clean worktree never runs this scan, which is why a big batch can succeed and only the dirty-worktree stragglers refuse. Measured 2026-09-10 (v2.1.268): two hand-edited `failed` records from 09-02 (`c5092014`, `d40b1ca1`, both carrying `"pid": null`, both absent from `claude agents --json --all`) blocked all seven discards; parking the two folders let all seven succeed.

**How to apply:**
1. Find rejected records: every `~/.claude/jobs/*/state.json` whose id is missing from `claude agents --json --all` is one the loader rejects.
2. Confirm none of them names the target worktree (`worktreePath`), then `mv` those folders aside, run the removals, and restore them in a `trap … EXIT` so a failure cannot strand them.
3. Flag values: the worktree id is the first 32 hex chars of `sha256(<absolute worktree path>)` (no trailing slash). `--force-remove-worktree <wid>` only covers a worktree git failed to remove and still requires no tracked changes; to discard uncommitted changes use `--discard-unpushed <HEAD sha>@<wid>` (it also deletes the local branch — check `git log <branch> --not --remotes` is empty or bundle it first).
4. Archive uncommitted files and unpushed commits (`git bundle create … <branch> --not --remotes`) before discarding; the transcript survives `claude rm` either way.

Related: [[a-deleted-bg-job-survives-in-its-transcript]], [[kill-bg-claude-sessions-via-job-state]].
