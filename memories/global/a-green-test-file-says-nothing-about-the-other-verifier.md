---
name: a-green-test-file-says-nothing-about-the-other-verifier
description: Per-task verification that names only the task's own test runner leaves every OTHER required verifier — the type-check, the linter, the build — unrun for the whole arc
metadata:
  type: feedback
scope: global
---

A task that ends "its spec file is green" has exercised ONE verifier.
A project usually requires several, and the ones nobody named are not merely under-exercised — they
have not run at all since the arc began, because no task's definition of done mentions them.

This is a different gap from `[[a-subset-run-is-not-a-suite-run]]`, which is about a narrowed slice
of one verifier.
Here the slice is complete and the VERIFIER is missing, so no amount of care inside the test runner
can surface it: the failing check is not a test.

**Why:** a per-task checklist is written from the task's own artifact, and the task's artifact is a
test file, so the checklist inherits that file's runner and nothing else.
The gap then survives every round of review, because a reviewer reading a diff is reading source
rather than running a compiler, and `[[answer-five-written-questions-before-implementing]]`'s
measurement already records that code review reaches 0 of the facts a diff does not contain.
It is also invisible to the task author in the most convincing way available: their file is green.

**How to apply:** write the project's REQUIRED verifier set down once, at arc setup, from what the
merge gate actually runs — the test command, the type-check, the linter, the build, each named
guard job — and make every task's done-check the whole set rather than its own file.
Run the full set at the LAST commit of the arc too, on the merged tree, and track that sha.
When a missing verifier does turn up red, fix it at each PRODUCER rather than at the call sites: one
edit there answers every consumer, where annotating consumers multiplies the work by the callers
and leaves the next consumer to find it again — `[[encode-the-invariant-in-the-shape-not-another-guard]]`.

Measured 2026-10-26 on a 25-task two-repository arc: `npx tsc --noEmit` reported **11 errors** while
all 8 of the arc's vitest files were green, across four tasks and two authors.
All 11 came from **three producers** and three edits closed them: an untyped parameter whose value
was spread into a record (making the whole return `any`, so every consumer's callback was an
implicit-any error), an untyped array parameter, and a property added by ASSIGNMENT after an object
literal — present at runtime, absent from the literal's inferred type, which is green under the test
runner and red under the compiler in the same breath.
