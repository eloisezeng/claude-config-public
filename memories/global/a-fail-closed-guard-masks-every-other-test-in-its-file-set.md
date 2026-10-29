---
name: a-fail-closed-guard-masks-every-other-test-in-its-file-set
description: A guard that refuses on an unknown input returns ITS refusal in place of every other test's expected error, so N files redden with one cause that names a file none of them is about — diagnose from the count of distinct error TEXTS, not the file list.
metadata:
  type: feedback
  scope: global
---

A guard built to fail CLOSED on an input it does not recognise does not merely redden its own test.
Every other test that drives the same pipeline now gets THAT refusal in place of the error it was
asserting, so a run reddens across unrelated-looking files and each one's message names a subject
none of them is about.

**Diagnose from the count of distinct error TEXTS against the count of failing files, not from the
file list.** One text across five files is one cause; five texts across five files is five.
A file list invites you to open five files and find five theories.

Measured 2026-10-27: adding four columns to two SQLite tables reddened eight files with sixteen
`AssertionError`s and ZERO timeouts. Five of them were `scripts/live-slice/{classify,probe,load,
export,bundle}.test.ts`, every one failing on `expected [Function] to throw error matching
/deadline passed/ but got 'unclassified columns: actions.exec_ow…'` — their own expected refusals
replaced by the column classifier's, which fires before any row is read. One override row and a
regenerated golden fixed all five. A sixth file (`cmMeta`) was a pure cascade of the suite's own
failure, and a seventh was a hand-written byte-identical fixture.

Two corollaries worth carrying:

- **The blast radius of a schema or payload-shape addition is the set of guards that ENUMERATE
  fields, and a typecheck cannot see any of them.** Before adding a column, grep for the goldens
  and classifier tables that name columns; expect each to be its own small repair with its own
  documented recipe, and satisfy the recipe rather than widening the guard.
- **A regenerated golden must be serialized in the committed file's own KEY ORDER, and the
  added/removed line counts are the whole evidence.** The same regeneration in the wrong key order
  gave a 1,240-line whole-file reformat in which every table read as changed; in alphabetical order
  it gave a 28-line pure insertion with zero removals. A reformat and a real change are
  indistinguishable at review time, so the count is what you report.

Related: [[a-build-dir-in-the-tree-reddens-whole-tree-guards]] ·
[[a-rename-sweep-takes-its-census-from-the-guard]] ·
[[a-red-suite-with-no-failing-test-lost-a-worker]] ·
[[a-guard-must-be-satisfiable-not-just-failable]]
