---
name: act-on-fresh-state-anchor-by-identity
description: Before any irreversible/mutating step, re-validate the state you decided on AT ACT TIME and anchor selections by stable identity (ids), never by position/index into mutable data
metadata:
  type: feedback
  scope: global
---

# Act on fresh state; anchor by identity, not position

**What happened (2026-07-16, your-other-project):** I verified "funsubs.com is item #3" on a pending buy card, then — 45 minutes later — approved `selectedIndices:[3]`. In between, a background agent folded two new names into the same card, shifting every index. Item #3 had become jumperco.com, and the system bought the wrong domain with real money. My earlier verification was true when I made it and worthless when I acted on it.

**Why:** Any state that another process can rewrite (queues, cards, lists, files, DB rows) can drift between your read and your act. A positional reference (index, line number, ordinal) silently rebinds to different content; a check done minutes early is a hypothesis, not a fact, at act time.

**How to apply:**
- Reference mutable collections by **stable identity** (domain name, primary key, hash), never by index/position, whenever the action mutates or spends.
- Re-read and re-verify **immediately before** the irreversible step — same script/transaction, not a separate earlier step ([[verify-claims-against-artifacts]] extended to act-time).
- Prefer **compare-and-swap**: send a fingerprint (hash/version) of the state you decided on; have the mutator reject on mismatch (HTTP 409 / conditional UPDATE ... WHERE status='expected' with a changed-rows check). Build this into any human-in-the-loop approval surface you design — the human's render is a snapshot too.
- When an API accepts an explicit payload (editedPayload-style), prefer it over a selection into server state — it pins exactly what you intend regardless of rewrites.

**The limit: fresh ≠ informed. Re-reading at act time is worthless when the fact has not been ingested into the store you re-read.**
Measured 2026-08-18 (your-other-project): the outreach send path re-checks `da_suppressions` twice, the second time against the live row "immediately before the provider call" and deliberately past the MX await — textbook act-time validation.
It still mails people who replied STOP, because the row is written by an event-driven agent that runs *after* the executor in the same tick, so both checks read a store that has not learned yet.
So before trusting an act-time guard, ask **what pipeline stage turns the real-world fact into the row you are reading, and has it run?**
A guard is only as fresh as its slowest ingestion path; where the answer is "not yet", no amount of re-reading closes it — the fix is to ingest before acting (or to read the un-ingested source), never a later re-check.
Say plainly which class a design closes and which it leaves open, and size the residual window.
