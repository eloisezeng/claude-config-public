---
name: git-add-partial-failure-stages-the-rest
description: "A git add that errors on a gitignored path still stages every other path in the same command, so the next commit silently carries files you thought were rejected"
metadata: 
  node_type: memory
  type: reference
  scope: global
  originSessionId: 4257b721-977d-4bf0-85a8-71cb861a8202
  modified: 2026-08-10T20:01:11.269Z
---

`git add a.ts b.ts ignored/c.json` does **not** behave atomically.
It stages `a.ts` and `b.ts`, then errors on the ignored path and exits non-zero.
The natural reading of a non-zero exit — "that add did nothing" — is wrong, and the successfully-staged paths sit in the index waiting for the next `git commit`, which picks them up even if that commit names entirely different files.

Observed 2026-08-10: an `add` naming a fixture under a gitignored `/data/` also named a scratch asset in `public/`. The command failed loudly on `data/`, the scratch asset stayed staged, and the *next* commit shipped it.

**Habit:** after any `git add` that exits non-zero, run `git status --short` before committing, and re-stage deliberately. Reading the commit's own `--stat` afterwards catches it too — which is how this one was found.

This is also why "stage only the files this task touches, never `git add -A`" needs a verification step, not just intent: the failure mode here is an add that *looks* like it was rejected.

Related: [[verify-claims-against-artifacts]], [[verify-unattended-pushes-against-diff]].
