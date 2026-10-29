---
name: a-setting-is-not-a-rate
description: "Every number I hand her carries the source it was read from, and neither a configured limit nor a backlog depth is ever reported as a measured rate — count the rows, or measure one period"
metadata:
  node_type: memory
  type: feedback
  scope: global
---

Every number I put in front of her names, in the same sentence, **where I read it** — and a number
read out of configuration is never presented as a number describing behaviour.

**Measured 2026-09-10**, two corrections in one arc, both the same defect at different sites. I
read a ceiling out of a live config row and reported it to her as a daily rate; that ceiling bounds
one BATCH, the system runs about sixty batches a day, and the true rate counted off the rows was
**17x** what I told her. Earlier in the same arc I counted a table holding one row per item, saw
one row each, and told her a five-way feature was not running; four of its five writers target a
**different table**, which held all five rows for 342 of 343 items over the same day. The first
error was the expensive one: she approved "raise it to 100" against my wrong number, and the
feature she wanted was gated on the very ceiling that raise would lift, so executing her approval
literally would have silently cut the five-way feature to one — which is why the approval was
withheld and a corrected choice put back to her instead.

**Why:** a bare number cannot be checked by the person reading it. Both errors were invisible in
the number and lived entirely in its provenance, so no amount of care re-reading the sentence would
have caught either. A configured limit is the most dangerous provenance of all, because a second
limit, an empty queue, or a switch elsewhere routinely gets there first — a setting describes what
is *permitted* and a backlog describes what is *owed*, and neither of those is what *happens*. Every
settings number quoted in that arc differed from live behaviour in some way.

**How to apply.** Four rules, all approved by her on 2026-09-10:

1. **Name the source beside the number**, in about six words: "343 a day, counted from the run
   records" rather than "343 a day". This is what makes a wrong source visible to her without
   opening a file — "20 a day, from the settings" invites "measured, or configured?" in a way a
   bare "20 a day" never does.
2. **Never quote a setting — or a backlog — as a rate.** When she asks how much of something
   happens, count the rows. Where only the setting is available, say so in those words and say the
   rate is unmeasured. A QUEUE DEPTH is the same trap in different clothes: measured 2026-09-18, a
   re-link sweep's cursor table read **41 of 47 sites due**, which against its per-run cap of 40
   forecast an imminent overage of a hard-capped vendor budget — and the very next hourly run spent
   **4**, because the counter and the spender were different regimes. Both counters available at
   that moment pointed opposite ways and neither was a rate: 41-due read as alarm, zero pending
   cards read as all-clear. ONE observed period settled it, and one period is cheap against a
   constraint that binds.
3. **Correct silently, except where she has already decided.** A wrong number she has not acted on
   is replaced in place with no commentary, per [[a-report-states-facts-not-confessions]]. A number
   she has already decided on gets an explicit "the number you approved was wrong, here is the
   corrected choice" — and her approval is NOT executed on the old number in the meantime.
4. **Measure before answering, and accept the delayed round.** Both errors came from answering
   inside the round with a number I had not measured. Her judgement: her attention spent on a
   number that was not real costs more than the wait.

5. **A report drafted before the artifact exists states a source nobody read.** At delivery,
   re-check each number's STATED SOURCE against the live artifact, not only its value. Measured
   2026-10-12: a handoff's pre-written report said the deploy run's "own summary" gave the 14
   refusals (6 / 4 / 3 / 1) behind a new saved page. The run prints an "of those N job listings, N
   were not listed" breakdown only for its ALERT sources and none at all for a saved page; the
   figures were right and came from a pinned test over the committed file. Writing the report early
   is correct — the seat holding the numbers should write it — but every provenance clause in it is
   a PREDICTION about an artifact that did not exist yet, and the successor who delivers it owes
   that clause the same check as the number.

Rules 1 and 2 are the report-time half of [[absence-needs-a-probe-that-could-see-presence]] and
[[counting-a-set-is-not-classifying-it]], which state the probe-time half and were both already
written down when these two errors happened. That is the part worth keeping: the measuring
discipline existed and did not fire, because nothing was checked at the moment a number left a
probe and entered a sentence addressed to her. See also [[verify-claims-against-artifacts]] and
[[surprising-result-check-metric-identity]].
