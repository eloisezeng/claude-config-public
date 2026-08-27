---
name: re-read-cannot-tell-wrong-from-acted-on
description: "A re-read that finds the world already fixed cannot distinguish 'I was wrong' from 'I was right and someone acted' — settle it by ordering, and derive stamps from mtime ONLY where you are the sole writer"
metadata:
  node_type: memory
  type: feedback
  scope: global
  originSessionId: 0df6a83c-ebd8-4ae0-a800-24704989286b
---

When you report that an artifact is wrong, then re-read it and find it correct, **the correct state is not evidence that you were wrong.** With any other writer in play — a sibling session, a teammate, the subject of your own review — it is equally consistent with "you were right and the owner fixed it because you said so." Content cannot separate those. Only **ordering** can.

**Measured 2026-08-21, and it cost a true finding.** I told a peer its handoff file still carried a withdrawn figure. Sent **09:47:51Z**. The peer fixed the file at mtime **09:48:53Z** — 62 seconds later. I re-read it, saw the fix, concluded I had spoken from stale memory, and retracted a live and correct claim. What misled me was the fix's own hand-typed annotation "Corrected in place 09:50Z" — *later than the file's real mtime* — which read as "already done before you asked."

**Why:** the self-accusing direction feels like rigour, so it passes review and repeats. A withdrawn true finding is worse than a late one — it removes a real defect from the record *and* teaches the reporter to trust themselves less.

**How to apply:**
- Before retracting, get two timestamps: when you made the claim (your own transcript's tool-use record) and when the artifact last changed. Claim-before-change means you were right.
- Converge three — your timestamp, the artifact's, and the author's own account of why they wrote. Outside git, mtime is not just weak but **destructive**: it keeps only the last write and prior content is unrecoverable, so anything that must survive a second write belongs in the ordering triple, never in a stamp.
- **Deriving a timestamp beats typing one ONLY where you are the sole writer.** On a shared artifact mtime carries *someone else's* write, so a derived stamp is worse than a typed one — it is wrong and it arrives looking authoritative. Measured the same day: a peer about to derive its section's stamp from a four-writer file would have published my write time as its own. So: sole-writer artifact → derive from its mtime; shared artifact → derive from your own transcript or a `date -u` read in the same tool call as the write, and **state which on the line**.
- Note the reflexive trap: writing a note *about* a timestamp moves the file's mtime past the value the note certifies, so the instrument stops corroborating it. Say so on the line.
- When you fix something because a reviewer named it, tell them. Silent compliance is what manufactures their false retraction.
- **The operative remedy is not care, it is a counter-party who re-derives.** Measured over five instances across three sessions on 2026-08-21: four were caught by the other party and none by the author, and the fifth surfaced only because a published ratio was declined rather than adopted. Self-discipline did not catch these; someone else measuring did. So do not rely on this memory to make you careful — arrange for a figure to be re-derived by something that did not produce it, and when you are handed one, decline it and check the instances that decide your call.
- Decide on INSTANCES, not on a summary figure. In that same exchange both parties' aggregate ratios were wrong, in different ways (one counted non-memory files into the denominator; one read pointer LINES as distinct entries — `[[surprising-result-check-metric-identity]]`), and the decision was right anyway because it rested on the two instances checked directly. A conclusion built on instances survives a miscounted summary; one built on the summary does not.

Distinct from [[absence-needs-a-probe-that-could-see-presence]] (a probe with no discriminating power) and [[act-on-fresh-state-anchor-by-identity]] (re-validate before mutating): here the re-read is fresh AND discriminating and still cannot answer a question about the past. Pairs with [[verification-claims-are-earned-per-item]] and [[fix-the-class-not-the-reported-instance]].
