---
name: merge-clean-is-not-merge-correct
description: Git conflicts on overlapping edits to the same lines, never on broken references — so a line YOUR branch adds referencing a symbol main DELETES merges with zero conflicts and breaks the build; gate the merge COMMIT, never the pre-merge branch, and never record a trial merge as evidence
metadata:
  type: reference
  scope: global
---

"No conflicts" is a statement about TEXT, not about meaning. The one case git cannot see is the most dangerous one: a line your branch ADDS that references something main DELETES. Main never saw your line, so there is nothing to conflict with, the merge is reported clean, and the build is broken.

Measured 2026-08-06: a PR on main deleted a local binding and every spread of it; the branch's new code still spread it. `git merge` reported zero conflicts, the type-checker failed with an undefined-name error and two tests threw at render. A prior session had trial-merged, seen "clean", and written that into a handoff as reassurance.

How to apply:

- **Never record a trial merge as evidence of anything.** Merge, then run the type-checker and the full suite, then re-verify the live page. The type error is the CHEAP failure mode; a client-bundle break passes the type-checker and every test — `[[verify-claims-against-artifacts]]`.
- **Gate the merge COMMIT, never the pre-merge branch.** Measured 2026-08-10: a PR was green on its own tip while main carried an expired date-bomb test; only the merge commit distinguished "the branch is fine" from "the range you would actually ship is fine". Re-pin BASE and HEAD after every merge, because a shared base can move twice in a day — `[[review-the-commit-that-is-checked-out]]`.
- **Give the merge its own review lens** whose only job is the overlap: read `base..main` and `base..HEAD` for the shared files and hunt for symbols one side removed and the other still uses. On a later zero-overlap merge the same lens returned clean, so it discriminates rather than always crying wolf — `[[codex-parallel-lenses-beat-serial-rounds]]`.
- **When a resolution adopts one side wholesale, assert the file EQUALS the authoritative one** (an empty diff against it, plus a zero count for your own now-deleted mechanism). A green suite cannot tell a correct adoption from a half-applied one that kept BOTH mechanisms, because keeping both usually passes today and only shifts behaviour later.
- **Never hand-merge a DERIVED artifact** (a golden, a lockfile, a generated schema dump): taking both sides asserts a state no build produces. Regenerate it from the merged tree by the recipe its own docblock names, then reconcile its members three ways by NAME — base, ours, theirs — so "nothing was lost" is measured. Measured 2026-09-08 over a 60-commit merge: a schema golden went base 270 rows, ours 279, theirs 272, merged 281, and 270 + 9 + 2 reconciled exactly; the row BOTH sides had edited was the only check that the source the golden derives from had auto-merged correctly. A row count alone would have passed while dropping one side — `[[counting-a-set-is-not-classifying-it]]`.

Related: `[[merging-is-restarting-production]]`, `[[close-the-reviewed-head-gate-by-measuring-identity]]`, `[[a-count-only-assertion-cannot-name-what-is-missing]]`.
