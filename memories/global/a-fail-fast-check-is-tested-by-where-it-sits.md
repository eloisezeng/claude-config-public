---
name: a-fail-fast-check-is-tested-by-where-it-sits
description: For any "fail in the first second" fix the defect is the ORDERING, so a test on the refusal's wording passes for the same check placed after the expensive step — assert that the expensive step never ran, and prove it with a mutant that MOVES the check without changing a character of its text
metadata:
  type: feedback
scope: global
---

When the bug is "we discovered this too late", the fix's whole content is WHERE the check sits — so
a test that reads the refusal's message is blind to the only thing that matters. Measured
2026-10-29: a deploy spent its entire gate green, eleven of twelve minutes in a browser suite, and
then died one line into the image build because it had no credential. A credential check with
exactly the right words, placed after that gate, still costs twelve minutes and passes every
wording assertion.

**Assert the expensive step never ran.** Each refusal case checks that the gate's own record is
absent, not only that the message appeared. Give the expensive step a stub that records the
TRANSCRIPT of what had already happened by the time it ran rather than a count, so a case can name
exactly what the new check is allowed to come after, and nothing else.

**Prove it with a mutant that moves the check and changes no text.** Relocating the block past the
gate is the exact defect shape, and it is the only mutant that separates a wording test from an
ordering test: it must be killed by the never-ran assertions and by nothing else. On one such run
the three ordering assertions fired and every message assertion stayed green.

**Expect the new check to perturb the existing exact-transcript assertions**, because it is a real
new call. Update them honestly — the ones that said "nothing was asked" become "nothing was asked
but this" — rather than loosening them to tolerate anything; and put the check LAST among the
refusals that cost nothing, so every local refusal still precedes the first network call.
Related: [[a-tool-may-not-read-the-credential-it-wrote]], [[a-mention-is-not-a-property]].
