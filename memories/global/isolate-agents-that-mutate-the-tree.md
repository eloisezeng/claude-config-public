---
name: isolate-agents-that-mutate-the-tree
description: An agent that mutates the working tree (mutation testing, --write implementations) needs its own worktree; sharing one checkout makes concurrent agents see phantom flakiness
scope: global
metadata:
  type: feedback
---

Any agent that MUTATES the shared checkout — mutation-testing a suite, a Codex `--write` implementation, a refactor sweep — must run with `isolation: "worktree"`.
Read-only reviewers can share a checkout safely; writers cannot.

**Why:** three agents once reported three different results for the same suite (636 pass, 7 fail, 7-then-16 fail) because a mutation-testing agent was applying and reverting production-code mutants in the same tree while the others ran tests.
The symptom is indistinguishable from flaky tests, and it sends you hunting a nondeterminism that does not exist.
The same session had a second, independent shared-state hazard from the same root: a `git commit` by one agent sweeps whatever a sibling has staged.

**How to apply:**
- Mutating agent → `isolation: "worktree"`. Read-only reviewer → shared checkout is fine, and cheaper.
- Tell read-only reviewers explicitly that they are read-only, and tell every agent which files a sibling is editing concurrently so they treat them as out of scope.
- While ANY agent is live, commit with `git commit -o <paths>` and review `git diff --cached --name-only` first — never a bare `commit` that commits the whole index ([[stage-immediately-verify-commits-from-the-object]]).
- Before diagnosing "flaky", ask what else was touching the tree in that window; timestamp the runs and compare against when siblings were active.
- **"Nothing is running" is a claim about parents, not about processes.** Killed and completed test runners leak worker processes that reparent to launchd (`ppid=1`) and keep burning CPU for the better part of an hour, so `ps` shows load with no owner and every later run silently measures a busy box. Sweep `ps -eo pid,ppid,command` for the runner's worker binary with `ppid == 1` — never "is my runner running?" — and make it MECHANICAL: a gate that must run alone refuses to start while any orphan is live, rather than reporting a perturbed number. Control the predicate on a synthetic orphan row, since a check that silently matches nothing reads identical to a clean box.
- A suite result is only meaningful if you can name what else was running. Re-run serially before you believe a discrepancy ([[verify-claims-against-artifacts]]).

Related: [[background-subagent-parallel-workflow]], [[codex-parallel-lenses-beat-serial-rounds]], [[codex-may-implement-never-self-review]].

This applies to YOURSELF, not only to delegates. A mutation-testing loop that rewrites a tracked file and restores it is the same contamination: in a repo whose code identity is a content hash over the tree, a concurrently-running suite sees `code_rev` change mid-run and the identity-dependent tests (checkpoint-resume, lineage gates) fail in a way that looks exactly like flakiness. Two such failures in MFFP round 4 were traced to precisely this, and the clean re-run on a stable tree confirmed it. Serialize the mutation loop against the full suite, or give it its own checkout.

**And in an auto-synced repo the mutant is PUBLISHED, not just local.** `~/dotfiles/claude` has a Stop
hook that commits *and pushes* the working tree on a timer. Mutation-testing `hooks/handoff.sh` in
place on 2026-08-21 put the mutant on `origin/main` for eight minutes (`5174a66` 14:52:48 → `cd01507`
15:00:48) — every sibling session that pulled in that window got it. It was benign only by luck: the
mutant happened to be the *previous* default. Before mutating a tracked file in a repo that
auto-commits, copy the file out, mutate the copy, and point the test at it — or accept that you are
shipping the mutant to everyone who shares the tool. Check for the hook (`git log --oneline -3` showing
`auto: sync config`) before you assume an edit is local.
