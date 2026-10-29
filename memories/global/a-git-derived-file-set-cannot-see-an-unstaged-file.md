---
name: a-git-derived-file-set-cannot-see-an-unstaged-file
description: A guard whose file set comes from `git ls-files` is structurally BLIND to a brand-new file until it is staged, so the scoped run that covers that guard passes and the commit lands red — run the git-derived guards AFTER `git add` and before `git commit`
scope: global
metadata:
  type: feedback
---

A repo-wide guard almost always derives its subject set from version control rather than from a hand-typed list, because a hand-typed list silently misses additions.
`git ls-files` is the right source for that.
**But the set it returns is the set of TRACKED files, and a file you just wrote is untracked until `git add`.**
So a guard over `git ls-files` is blind to exactly the file the commit is adding — the one file that needs checking most — and it reads green.

This is the authoring-to-use transform class (`[[enumerate-the-transforms-between-authoring-and-use]]`) with `git add` as the transform.
The guard does not act on the file you authored; it acts on the index.

**Measured 2026-10-04, job_hunt stage-4 item 5.**
A new test file `tests/weak-assertions.test.ts` planted positive controls as SOURCE STRINGS, one of which contained `import { CLOSED_SET } from '../src/domain/thing.ts'` — a module that does not exist.
`tests/guards.test.ts` resolves every relative import by scanning each test file's TEXT (it does not know a specifier is inside a string literal) over `git ls-files`.
The scoped pre-commit run INCLUDED `guards.test.ts` and it passed with 25 tests, because the new file was untracked.
`git add -A && git commit` staged it, the commit landed RED, and it surfaced only on the next item's test run.

**How to apply**

- Re-run the git-derived guards **after `git add`, before `git commit`** whenever a commit ADDS a file. A clean scoped run before staging says nothing about the file being added.
- Expect the same blindness from any set derived from the index: `git ls-files`, `git diff --cached`, a tracked-file credential scan, a tracked-file link checker.
- Suspect this whenever a guard was green pre-commit and red one commit later with no intervening edit. The new file is the trigger, not the cause.
- Where a guard scans TEXT rather than an AST, a specifier/pattern inside a string or template literal is a hit. Make planted controls name things that really exist, or exempt the plant structurally — and prefer the real name, because the exemption is the thing that goes stale.
