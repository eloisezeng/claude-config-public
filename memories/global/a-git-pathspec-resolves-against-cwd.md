---
name: a-git-pathspec-resolves-against-cwd
description: git ls-tree/grep path arguments resolve against the CURRENT directory, so a guard run from a subdirectory silently matches nothing and derives an EMPTY set — pass --full-tree
scope: global
metadata:
  type: reference
---

`git ls-tree <ref> <path>` resolves `<path>` **against the current directory**, not the repo root, and
prints results relative to the current directory too. Run from `web/` in a monorepo, `git ls-tree
$ref .github/workflows/` looks for `web/.github/workflows/` — matches nothing, exits **0**, prints
nothing. `git grep`, `git log -- <path>` and `git diff -- <path>` share the rule.

**Pass `--full-tree`** (which implies `--full-name`, so downstream `$ref:$path` reads still address the
right blob). `git ls-files --full-name` and `git rev-parse --show-toplevel` are the other escapes.

Why this is worse than an ordinary papercut: it turns a **derived set** into an empty one with no
error. A gate that derives "the required CI jobs" by listing `.github/workflows/` then reports
NOT-GREEN forever from a subdirectory — the permanent fail-closed such scripts are usually written
specifically to avoid, arriving by a route the author never considered. Measured 2026-09-07 in
`~/.claude/bin/ci-green.sh`: `expected_jobs=[]` and NOT-GREEN from `your-project/web` while all five checks
on the sha were green; one `cd ..` and the same sha read GREEN. It bit a hand-typed
`git ls-tree -r --name-only origin/main -- web/...` in the same repo two days later, so knowing about
it is not the fix — writing `--full-tree` is.

Control it in both directions: a subdirectory run must derive the SAME set as a root run (not merely
a non-empty one), and a ref that genuinely lacks the path must still come back empty.

Instance of the class in [[absence-needs-a-probe-that-could-see-presence]] — an empty result is
evidence only once you have shown the probe could have seen presence. Related:
[[verify-in-the-consumers-condition]], since the consumer's cwd is exactly the condition that moved.
