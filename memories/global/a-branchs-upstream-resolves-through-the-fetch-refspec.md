---
name: a-branchs-upstream-resolves-through-the-fetch-refspec
description: git resolves `@{upstream}` and `%(upstream:remotename)` through the remote's FETCH REFSPEC, not from the branch's own config, so a deleted tracking ref or an edited refspec makes a correctly configured branch report "no upstream" — read `branch.<b>.remote`/`branch.<b>.merge` and fetch with an explicit refspec
metadata:
  type: reference
  scope: global
---

`branch.<b>.remote` and `branch.<b>.merge` are what a user sets and what `--set-upstream-to` writes, but neither `git rev-parse @{upstream}` nor `git for-each-ref --format='%(upstream:remotename)'` reads them directly: both map the configured merge ref through the remote's fetch refspec to a remote-tracking ref, and report nothing when that mapping fails.

Two ordinary states break the mapping, and each one is permanent for any tool that trusts it:

- the tracking ref is gone (`git branch -dr origin/main`, a pruning accident), so `@{upstream}` is an "ambiguous argument" error — and the fetch that would recreate it is exactly what the tool was about to run;
- the fetch refspec no longer covers the branch (a hand-edited `remote.origin.fetch`, a `--single-branch` clone later used for another branch), so `%(upstream:remotename)` is empty on a branch whose own config is perfectly set.

The second one is the nastier of the two: the tool then reports "this branch follows no upstream" and advises `--set-upstream-to=origin/main`, which writes config that is already there and changes nothing. Measured 2026-09-17 on the memory-store refresher: the case reached me only because a mutation battery flagged an explicit fetch refspec as untested, and chasing that "decorative" line found a store that would have stopped following `main` for ever while reporting a repair that could not work — `[[a-surviving-mutant-may-mean-the-property-is-unobservable]]` in reverse.

So a tool that must keep a checkout on its branch reads `git config branch.<b>.remote` and `branch.<b>.merge` itself, compares `merge` to its own `refs/heads/<b>`, and fetches `+refs/heads/<b>:refs/remotes/<remote>/<b>` explicitly rather than by name. It then works from `refs/remotes/<remote>/<b>` instead of `@{upstream}`, and neither a missing tracking ref nor a foreign refspec can stall it. Related: `[[a-tracked-store-resolves-only-on-its-branch]]`, `[[project-memory-lives-in-the-project-repo]]`.
