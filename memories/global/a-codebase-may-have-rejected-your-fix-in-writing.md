---
name: a-codebase-may-have-rejected-your-fix-in-writing
description: Before proposing a fix, grep for whether the codebase already documents rejecting that approach — a docblock saying "we stopped doing X because Y" is a decision record your diagnosis has not read.
metadata:
  type: feedback
  scope: global
---

A diagnosis that names the minimal fix must first check whether the codebase has already REJECTED
that fix in writing. The rejection does not live in the file you are fixing; it lives in the sibling
that took the decision, as a docblock explaining why the obvious approach was abandoned. So the
grep is for the MECHANISM you are about to recommend, across the tree, not for the file you are in.

**Why:** reading the broken file tells you what it does, never what the project already tried. A
prose decision record is invisible to the typecheck, to the tests and to a reviewer who starts from
the symptom, so the rejected approach reads as the obvious fix right up until a second reader finds
the docblock. Recommending it then reintroduces exactly the defect that docblock exists to prevent,
with the authority of a measured diagnosis behind it (measured 2026-10-17: a root-cause note for a
signed-in-treated-as-signed-out bug recommended reading identity from the browser session hook,
while `idea-details-view.ts:43-49` recorded that the component had DELIBERATELY stopped reading that
hook because on a server-rendered page the browser's answer can disagree with the one the server
already rendered for — an independent reviewer found it, not the three code reads that preceded it).

**How to apply:** for every fix you propose, grep the tree for the API or pattern you are
recommending and read any comment that mentions dropping, replacing or no longer using it; a hit is
an adjudication you must answer in writing, not a note. Treat "the server already has this value"
the same way: it is a claim about ONE route, so check it per surface — the same sentence was true for
identity and false for titles, because the list route returned ids only. Related:
[[verify-claims-against-artifacts]] · [[codex-parallel-lenses-beat-serial-rounds]] ·
[[the-product-may-already-own-the-write-path]]
