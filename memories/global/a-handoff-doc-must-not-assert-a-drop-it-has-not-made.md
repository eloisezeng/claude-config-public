---
name: a-handoff-doc-must-not-assert-a-drop-it-has-not-made
description: "A handoff document that says 'I DROP the job' before the writer has actually stopped creates two live seats on one irreversible runbook; write the CONDITION, hand over explicitly, and settle a contested seat by artifact"
metadata:
  node_type: memory
  type: feedback
  scope: global
---

A handoff block that asserts **"I DROP the job on dispatching you"** is almost always written *before* the writer
has finished its last task. The successor reads it literally — correctly — and tells every peer the predecessor is
gone. Meanwhile the predecessor is still alive and still writing. On 2026-08-21 that produced **two live sessions
believing they owned the merge decision on a PR whose merge restarts production**, and it was caught only because a
third session measured both transcripts 50 s apart instead of believing the document.

**Why:** stated intent is not an accomplished fact, and a handoff document is read as a record of facts. The seat is
the dangerous part: one merge, one deploy, one irreversible action is available, and two seats racing it is the
failure mode. The wording is the defect — not either session.

**How to apply:**
- Write the CONDITION, never the past tense: *"I drop the moment X is committed"*, naming X so the artifact shows
  when it landed. Never write a drop you have not made.
- A handoff moves WORK, not authority. Authority transfers only on an explicit two-sided exchange: the successor
  claims the seat, the predecessor confirms it in one word, and both write the settlement into the runbook.
- Resolve a contested seat BY ARTIFACT, never by any document's claim or by a `ListAgents` row: read each candidate's
  `state`/`tempo`/`updatedAt` and take two transcript-size samples ~50 s apart. Growth is life; a document is not.
  [[verify-claims-against-artifacts]], [[absence-needs-a-probe-that-could-see-presence]]
- While a seat is contested the invariant is **NOBODY acts on the irreversible step** — settle first, then act. Say
  which criterion decided it; the freshest context window should hold the seat, because the irreversible stretch is
  the one that must not run out of room. [[handoff-at-boundaries-saves-tokens]]
- If you are the one who wrote the misleading sentence, correct it in the document where it lives, in place and by
  APPEND — a verbal correction dies with the session that spoke it.
  [[re-read-cannot-tell-wrong-from-acted-on]]
