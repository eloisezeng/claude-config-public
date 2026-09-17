---
name: a-build-dir-in-the-tree-reddens-whole-tree-guards
description: A gitignored build directory left in a checkout reddens every guard that walks the WHOLE tree, CI never has one so it reads as a branch red, and the suite itself usually recreates it mid-run — so deleting it once is not a durable repair
metadata:
  type: reference
  scope: global
---

A guard that makes a whole-tree claim enumerates DIRECTORIES; it does not match names. So any gitignored build output sitting in the checkout (`.next/`, `dist/`, `build/`, a coverage tree) is inside the claim, and a fail-closed walker reddens on the first file it cannot resolve statically. CI checks out clean and never has one, so the red appears only locally and its body names a path that has nothing to do with the diff.

Three facts, measured 2026-09-05 and 2026-09-08 on `origin/main` bytes (lane `a-local-next-build-dir-reddens-the-tree-walkers`, mirrored as a your-other-project project memory of the same name):

- **Renaming the directory is not a control.** `.next` renamed to `.next.aside` still reddened, because the walker enumerates directories rather than matching the name; the failure simply moved to another file inside. A rename looks like a control and is not one.
- **Deleting it turns the same source bytes green** — 2 files, 21 tests, exit 0.
- **The suite puts it back.** One test spawns a real `next dev` in the repo root with no `NEXT_DIST_DIR`, so the run writes the directory while it is still going: the tree was deleted, `npm test` started 03:26:27 and went fully green, and `.next/trace` records a boot at **03:28:58**, two and a half minutes in, with 90 files present afterwards.

That last one is why the same bytes give a red and then a green: it is an ORDERING race against the suite's own writer, not flakiness in the guard. Whether the next run is red depends only on whether the tree walkers reach the directory before that test does.

**So: delete it immediately before the run you intend to judge, judge THAT run, and never treat a leftover build directory as evidence about a branch.** The durable fix is at the WRITE site (point the spawned build at a scratch dist dir), not at the guard; a guard that re-reads the tree to exclude files appearing mid-walk works around the writer without stopping it.

Watch for a DERIVATIVE second signal. A guard that spawns a child suite and asserts `{ ok: true }` reports its own failure whenever the child is red for any reason at all, so seeing two guards fail together is one cause, not two — diagnose the walker and the child follows.

