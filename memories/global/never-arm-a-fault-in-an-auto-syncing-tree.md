---
name: never-arm-a-fault-in-an-auto-syncing-tree
description: A directory with an auto-commit/auto-push hook will publish any deliberately-broken file you leave in it — mutate a COPY and parameterize the tool under test by path
scope: global
metadata:
  type: feedback
---

Mutation testing, fault injection, and "comment out the guard and see if a test notices" all work by
leaving a **deliberately wrong file on disk** for a few seconds. In a directory that auto-commits on
a hook — `~/dotfiles/claude` commits AND pushes on every Stop — those few seconds are enough.

Measured 2026-08-21: while proving a pty suite could kill `exec /usr/bin/false`, a sync fired inside
the mutation window. Commit `63e1448` shipped `exec /usr/bin/false` in place of
`exec "$CLAUDE" agents --cwd "$cwd"` **to origin/main**, and the installed copy at `~/.claude/bin/`
was mutated with it. The mutation run itself was correct and the restore was byte-identical; the
damage was entirely in what a background hook captured in between.

**How to apply.** Make the tool under test take a PATH, then point it at a copy:

- Parameterize the suite (`$FLEET_BIN`, `--binary`, an env var) and **refuse to run without it** —
  a fallback to "whatever is installed" is how a suite comes to test a different file than the one
  under review, which is its own defect class.
- Copy → `sed` the copy → run against the copy → assert the tracked file is unchanged, in the same
  script. `mutate.sh` does exactly this, and it fails loudly when the expression matches nothing,
  because an unarmed mutant always survives and reads as a passing test.
- If a fault genuinely must be armed in place, disable the hook first and re-enable it in a `trap`.
- **Look for the copy the suite already makes.** A shell-function test often LIFTS the function out
  of the script under test into a scratch file (`sed -n '/^fn() {$/,/^}$/p' "$SCRIPT" > "$tmp/x.sh"`)
  so it can be called directly. That extraction is the mutation target, and it is already outside
  the synced tree — so the negative control costs nothing and arms nothing. I reverted a hook in
  place to prove a one-line parse fix was load-bearing, with a sync watcher committing every ~6
  minutes, while the suite three lines away was already testing that exact function through a copy.
  The commit that landed happened to catch the restored file, which is luck and not a method.

**Auditing after the fact:** `for c in $(git log --format=%h -N -- <file>); do git show $c:<file> |
grep -q '<mutant>' && echo $c; done`. Check the remote too — an auto-push means the window is not
local, and repair it with a commit rather than a force-push, so the record shows what happened.

The general form: **a background process that snapshots your working tree turns every transient
intermediate state into a published artifact.** The same reasoning applies to a half-written config,
a credential pasted in for one test, and a `.only` left on a test.

Related: [[stage-immediately-verify-commits-from-the-object]], [[verify-claims-against-artifacts]],
[[isolate-agents-that-mutate-the-tree]], [[config-sync-commits-onto-detached-head]].
