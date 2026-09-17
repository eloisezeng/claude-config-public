---
name: a-worktree-needs-its-own-node-modules
description: Symlinking a worktree's node_modules to the parent checkout redirects @scope/* workspace resolution to the PARENT's source, so typechecks and tests verify the wrong tree while reading green
metadata:
  type: feedback
scope: global
---

In an npm/pnpm/yarn **workspaces** repo, `node_modules/@scope/pkg` is a symlink into the
checkout's own packages. So pointing a git worktree's `node_modules` at the parent checkout
(`ln -s ../../../node_modules`) silently redirects every `@scope/*` import to the **parent's**
source. `tsc -b` still builds the worktree's own `dist` from the worktree's relative project
references — but any consumer that imports through the package name reads the parent. The two
disagree and nothing says so.

Measured: after renaming a shared union member, `tsc -b --force` reported **0 errors** across a
worktree whose client had 4 now-impossible comparisons. A planted `const x: number = "s"` in the
same file DID error, so the file was being read — the type just arrived from the wrong checkout.
The tell was the resolved type printing the OLD union.

**Why:** a worktree exists to isolate a change, and this defeats it in the one direction that
matters — the change is invisible to its own consumers, so every green check is about the parent's
code. It reads green hardest right when the worktree has diverged most.

**How to apply:** run a real `npm install` inside the worktree (workspace links are relative, so
they then point at the worktree's own packages) — never symlink `node_modules` to the parent to
save time. Verify with `readlink -f node_modules/@scope/pkg` and check the path contains the
worktree, not the parent. Before trusting a clean typecheck after a rename, confirm the compiler
can SEE the change: `grep` the old name and require the error count to match the hit count — a
positive control on an unrelated line proves only that the file is read, not that the type came
from the right tree. Same class as [[measure-what-reaches-context-not-disk]] and
[[a-linked-config-file-can-become-a-copy]]: the artifact that ACTS is not the one you authored.

**The MIRROR-IMAGE half-repair is worse than no repair, because it moves the symptom instead of
removing it.** Measured 2026-09-05: a worktree whose `node_modules` held only a `.bin` link into the
shared checkout and no packages made the `tsx` spawn SUCCEED, so the child then died on
`Cannot find module '<worktree>/node_modules/tsx/dist/cli.mjs'` — a different error, a different
failing set (60 tests across 6 files) and no `ENOENT` anywhere to match the documented signature, so
it did not read as the known class at all. A bare `node_modules/*` glob is how you get there: it
matches no dotfile, so it links every package and NOT `.bin`. Enumerate with a lister that sees
dotfiles, link `.bin` AND the packages, then positively control it by re-running the exact failing
subset on the SAME bytes before attributing anything to a diff. Note also that a real red can hide
inside the phantom set — one repair turned 11 phantom files into one genuine failure the noise had
been masking — so repair the worktree BEFORE concluding a suite is phantom-red end to end.
A red whose count MOVES between runs of identical bytes is measuring the machine:
[[a-red-suite-with-no-failing-test-lost-a-worker]] and
[[a-build-dir-in-the-tree-reddens-whole-tree-guards]] are the same family.
