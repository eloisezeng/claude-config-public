---
name: persisted-drafts-need-rerender-at-review
description: A change to a generator never reaches text already persisted for human approval — re-render at the REVIEW surface, never at the consumption point
metadata:
  type: feedback
scope: global
---

When generated text is persisted and later approved by a human (an approval card, a queued message, a draft awaiting review), the stored bytes are a **snapshot**. Shipping a change to the generator does not reach them, and usually nothing else will either — dedupe logic typically skips an item that already has a record, so it is never regenerated.

Symptom: one surface showing two generations of the same template side by side.

**Why:** 2026-07-31, your-other-project. The user: "not all current outreach emails are using correct template." One inbox card held 12 emails — 4 on the current template, 8 on the previous one. The consolidation fold merged later cards into the oldest byte-for-byte, so the fold was exactly where the two templates met. A carded lead was never re-proposed, so nothing would ever have refreshed those words, and every future copy change would have split a card the same way.

**How to apply:**
- Whenever you change how generated text is produced, ask: is there persisted output of the old version still awaiting a human? Sweep it.
- Re-render at the **review** surface (where it is stored and read), **not** at the consumption/send point. The human approves specific words; rewriting them after approval breaks the guarantee the approval makes. The review surface is the last moment the text is still yours to change.
- Only re-render what is **deterministic**. LLM-authored parts have no source to re-render from — leave them and say so.
- Read every input **live** at re-render time (the price from its own table, not the snapshot's copy), and move values that must agree in one object.
- Make it a **correctness** re-stamp, not a freshness one: rewrite only when bytes actually differ, or you churn any content-hash/fingerprint the approval flow depends on and 409 a decision in flight.
- Handle **every shape the record has ever had**, including legacy ones. "We never RESHAPE a legacy row" is a different promise from "we never REFRESH one" — conflating them leaves the oldest rows as the ones a copy change can never fix.

Related: [[verify-claims-against-artifacts]], [[assert-complete-message-not-substring]].
