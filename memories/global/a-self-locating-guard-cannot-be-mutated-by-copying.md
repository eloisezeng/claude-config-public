---
name: a-self-locating-guard-cannot-be-mutated-by-copying
description: A guard that derives its own scan root from import.meta.url changes SUBJECT when copied, so a copy-based mutation harness reddens its baseline instead of testing it — mutate the file at its own depth in a scratch repo outside the tree; and a rewrite that resolves back to the REAL source makes the mutant read SURVIVED on a run that tested nothing.
metadata:
  type: feedback
scope: global
---

A guard that locates its own corpus relative to itself — `REPO =
dirname(fileURLToPath(import.meta.url)) + '/..'`, then `git ls-files` with that
as `cwd` — is not a pure function of its text. **Copying it changes what it
scans, which changes what it asserts.** So the standard mutation move (copy the
subject and its test into a scratch dir, rewrite the imports, run vitest there)
cannot host it, and the failure is silent in the direction that matters: the
copy scans the wrong root, finds zero files, and the BASELINE goes red — at
which point a harness that classifies on test colour would read every mutant as
KILLED on no evidence at all. `mutate.py` catches this (it refuses with
"the baseline suite was not green"), but only because it checks; the lesson is
that a red baseline here means *the subject moved*, not *the branch is broken*.

Both obvious placements fail, from opposite ends:

- a copy one level DEEPER (`tests/mutation-*-tmp/`) resolves the root to
  `tests/` and scans nothing;
- a copy at the right DEPTH (repo root) resolves correctly but falls outside the
  runner's include glob (`tests/**/*.test.ts`), so vitest finds no test file and
  exits 1.

**The way through: a scratch repo outside the worktree.** Materialise it from
`git ls-files` (which captures the STAGED content, so stage first), symlink
`node_modules`, `git init` it so the guard's own `git ls-files` works, edit the
copy there, and assert the tracked files' sha256 unchanged in the same script.
That keeps the "never arm a fault in a tree that auto-commits" rule while
mutating a file at its own depth. Measured on job_hunt 2026-10-04: three
placements tried, ~6 tool calls, before the scratch repo worked for three
separate items.

Three neighbouring facts worth keeping with it:

- `mutate.py`'s rewrites are plain substring replacement — `--rewrite` on the
  TEST copy, `--src-rewrite` on the SOURCE copy. The PREFIX form
  (`--rewrite='../src/=../../src/'`) is for the test's OTHER imports, and it is
  the WRONG form for the subject's own specifier: from
  `tests/mutation-*-tmp/`, `'../tools/=../../tools/'` resolves back to the
  repo's REAL `tools/`, so the baseline and the mutant both ran unmutated source
  and the mutant read **SURVIVED** — a vacuous run shaped exactly like a
  measurement of the property. The subject needs `'<specifier>=./<basename>'`,
  because the source copy sits in the copy-dir itself; the two chain in order
  when both are needed. So this failure mode has BOTH directions: a red baseline
  (subject moved, fails closed) and a survived mutant (subject never loaded,
  fails OPEN). Before recording any SURVIVED, arm a mutant that MUST die in the
  same configuration and confirm it does — distrust hardest the plumbing you
  configured ninety seconds ago to confirm what you expected
  (`[[absence-needs-a-probe-that-could-see-presence]]`). A `'./=…'` rewrite is
  too greedy and corrupts the paths the earlier rewrites already produced; name
  each `./x.ts` instead.
- `vitest -t` is REGEX-matched, so a test name holding `/*` or `/` can select
  more than one test and `mutate.py` fails closed with `multi-select`. Name
  tests without regex metacharacters when a mutant will filter on them.
- When the property under test is genuinely unobservable from the outside,
  extracting the pure decision is what makes it testable rather than a cleverer
  mutant. A totality refusal reached only through a `sort` comparator cannot be
  driven at n = 1 while it lives inside the caller that always supplies n ≥ 2;
  pulled out as a named pure function, n = 1 is reachable and one ordinary test
  kills the old shape — `[[churn-concentration-names-the-missing-seam]]`.

See also `[[never-arm-a-fault-in-an-auto-syncing-tree]]`,
`[[verify-in-the-consumers-condition]]` (the same class one level up: a check run
where a fallback exists tests the fallback), and
`[[a-mention-is-not-a-property]]`.
