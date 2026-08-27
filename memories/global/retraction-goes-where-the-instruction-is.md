---
name: retraction-goes-where-the-instruction-is
description: A correction appended at the tail of a long record retracts nothing — put it where the wrong instruction is, append-only, and fix the whole class of sites
metadata:
  type: feedback
scope: global
---

A retraction placed only at the END of a long record retracts nothing.
A successor reads top-down and obeys the first live-sounding instruction it meets, so a correction 450 lines below three still-imperative sentences never fires.

**Why:** measured 2026-08-21. Five handoff files carried "the Fable 5 limit is SPENT — dispatch every successor with `--model 'opus[1m]'`". The claim was correctly MEASURED (the runtime's own block reason in `state.json`) and true when written at 21:12Z — it simply EXPIRED at ~21:30Z. "Measure harder" would not have prevented this. your `/login` account switch lifted the cap; a successor dispatched with no flag ran 95 Fable turns with 0 opus and 0 limit-deaths. But the briefs stayed authoritative, so every downstream session would have launched on Opus **by following its brief correctly, not by erring** — an inversion of your instruction that is invisible from outside because each session looks obedient. One file already had a tail retraction and still misled, because its three imperatives sat far above it.

**How to apply:**
- Put the correction **at each wrong instruction**, not where you discovered it. `grep -n` the whole class of files first — a claim that spread once spread everywhere; count the sites and report the count.
- **Append, never rewrite**: insert a dated retraction after the offending block and leave the original claim standing above it, so the record keeps its history and the next reader can see it was believed. Verify purely additive (0 lines deleted) against a backup.
- Carry the **measurement** into the retraction (artifact, counts, timestamp), not a bare assertion — the thing being retracted was itself a confident assertion.
- Ask what *mechanism* would make a good-faith reader do the wrong thing. A brief that says "always pass X explicitly" is that mechanism; fixing the belief without fixing the brief fixes nothing. See [[a-handoff-doc-must-not-assert-a-drop-it-has-not-made]], [[re-read-cannot-tell-wrong-from-acted-on]], [[fix-the-class-not-the-reported-instance]].
- Do not publish the **mechanism** of a recovery you did not measure either ("quota windows roll" when what happened was an account switch) — that is the same defect one layer down.
- **A quota fact has a shelf life.** An account switch can lift a limit at any moment, so never write a quota observation into a runbook as a standing instruction — stamp it with a time and have the consumer re-measure at dispatch time rather than inherit a tier from a document. A tier hand-passed into a dispatcher keeps defeating the intended default long after the condition is gone.
