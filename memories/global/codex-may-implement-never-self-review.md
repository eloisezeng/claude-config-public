---
name: codex-may-implement-never-self-review
description: Codex may implement mechanical plan tasks via run-codex.sh --write, but the party that wrote a SHA range never reviews it — otherwise the convergence loop is theatre
metadata:
  node_type: memory
  type: feedback
  scope: global
---

Codex is allowed to write code, not just review it. **The rule that cannot bend: whoever authored a range does not review it.** Codex-implements means *Claude* reviews. A Codex verdict over Codex's own code is not a weaker verdict, it is no verdict — author/reviewer independence is the only thing the whole loop buys.

**Route to Codex** the mechanical, well-specified, high-volume tasks: one pattern across many sites, migrations, sweeps, renames, independent workstreams. **Keep with Claude** anything touching the seams a project's own instructions call out (payload readers, config defaults and their boot backfill, schema rebuilds, money/lifecycle paths) — those bugs come from project knowledge, not coding skill.

**Codex reads `AGENTS.md`, never `CLAUDE.md`.** Most of the user's repos have only `CLAUDE.md`, so Codex ran there with *zero* project instructions — it had never seen "never `git add -A`" or the pre-commit gates. `project_doc_fallback_filenames = ["CLAUDE.md"]` is now set in `~/.codex/config.toml`; verify per repo by asking Codex to quote a rule that exists only in `CLAUDE.md`. A repo where that fails is a repo where Codex must not implement.

Mutating runs go through `run-codex.sh --write`, which is read-only-by-default and refuses to start unless the target is a **linked worktree** (never the primary checkout), off `main`/`master`/`develop`, not detached, and clean. It runs **exactly once** — a killed attempt may already have committed, so a retry inherits partial state; the worktree is quarantined instead. It pins `START_SHA` and exits 4 if the run leaves an uncommitted tree.

**Linked-worktree sandbox facts (2026-08-07).** A linked worktree's git metadata lives under the PRIMARY repo's `.git`, outside Codex's workspace-write sandbox, so `git commit` EPERMs and an otherwise-perfect task strands its work uncommitted (rc=4). The launcher now auto-grants the git common dir via `-c sandbox_workspace_write.writable_roots=[...]` and exports Codex `GIT_AUTHOR_*`. Two related gotchas: a SYMLINKED `node_modules` points outside the sandbox too (Vite's `.vite-temp` write EPERMs — Codex can route around it, but budget for the flail or grant the target), and an rc=4 run with a clean allowlisted diff is salvageable — verify the transcript's mutation-red evidence, re-run its tests yourself on intact code, then commit its diff verbatim with `--author` Codex; the ledger, not the git author field, is authoritative.

Then gate the result before reading it: the whole worktree state against `START_SHA` (committed **and** staged/unstaged/untracked — `START_SHA..HEAD` alone misses uncommitted edits to tracked files, which is where out-of-scope work hides), the *exact* expected commit count both ways (a run that quietly did less passes every green gate), each hunk traced to the assigned task, the red-phase transcript actually present, and the tests re-run by you.

The authorship ledger must cover `$BASE..$HEAD_SHA` with every commit claimed exactly once — no gaps, no overlaps. Review fixes, cleanup and conflict resolutions are commits too, and are exactly the ones that go unrecorded and inherit the wrong reviewer by default.

Pairs with [[codex-exec-hang-watchdog]], [[codex-model-tiers-and-effort-routing]], [[codex-converge-loop-keeps-paying]].
