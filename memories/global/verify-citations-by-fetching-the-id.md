---
name: verify-citations-by-fetching-the-id
description: A citation whose arXiv ID/DOI resolves can still be fabricated — check the fetched title and authors against the claim, and the mechanism attribution against the abstract
scope: global
metadata:
  type: feedback
---

Never treat "the identifier resolves" as verification.
Fetch the record and compare the **title, author list and claimed mechanism** against what the citing text asserts; a fabricated entry typically pairs an invented author and title with a *real* ID, so an existence check passes and the error survives every later review.

Build bibliographies from machine-fetched metadata (arXiv Atom API, Crossref `/works/{doi}`, DBLP, Semantic Scholar `/paper/batch`, OpenAlex), never from recall, and assert caller-side what those APIs cannot: the key's surname matches the record's first author, the key's year matches the emitted year, no ID is used twice, and every hand override carries a written reason.
Write a venue into the bibliography only when an authoritative source (DBLP, Crossref, arXiv `journal_ref`) or two independent indexes back it; otherwise cite the preprint and record the unconfirmed hint in a side report rather than promoting it silently.
Vendor the API responses next to the generator so the bibliography rebuilds byte-identically offline.

**Why:** on the MFFP Interp4Discovery paper, `beggs2025pdecond` — invented author, invented title, real ID 2509.09599 — sat in 12 places across 5 model families including the headline model, and its *mechanism* claim ("FiLM-via-LayerNorm") was also wrong, so it could not simply be re-pointed at the true paper.
Machine metadata is not automatically right either: Crossref dropped a coauthor from Kennedy & O'Hagan, and one DOI recalled from memory resolved to an unrelated clinical-trials paper.

**How to apply:** when a task involves citations, fetch every ID before writing anything that depends on it; when a cite attributes a *mechanism*, read the abstract and split the claim if the paper does not support it; correct the fabrication in the source tree, not only in the new document, and say plainly which files changed and what that invalidates.
Related: [[verify-claims-against-artifacts]], [[codex-claude-convergence]], [[absence-needs-a-probe-that-could-see-presence]].
