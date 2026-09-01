---
name: ask-before-regenerating-a-collaborators-artifact
description: "Before spending compute to (re)generate a baseline or dataset, ASK the human whether a collaborator already ran it — off-repo work is invisible to every local probe, so a filesystem search proves nothing about whether the run happened"
metadata:
  node_type: memory
  type: feedback
  scope: global
---

Before spending compute to generate an artifact that a collaborator plausibly already produced — a baseline at a different budget, a dataset variant, a sweep — **ask the human first**. Do not settle the question with a local search.

**Measured 2026-08-16 (MFFP).** A pilot retrained the `mf_fno_transfer_film` baseline at 2500 epochs (~5.5 of 15.3 GPU-h). The user's mentor had already trained it at that budget off-repo; the evidence was sitting in `final_error_matrix.csv`, whose film row matched the retrain to ~2.5% median. When challenged, the defence was a whole-filesystem checkpoint census (278 e200, 267 e2, zero e2500) — a probe that **cannot see a collaborator's off-repo run at all**, so it established nothing about whether the training had happened, only that its weights were not on this box. The user's instruction: ask her whether training is necessary before doing it.

**Why:** collaborators run things on their own machines and push only summaries — a CSV of scores, a table in a doc. Those summaries ARE the evidence the run occurred; treating "no checkpoint locally" as "no run exists" inverts it. The human is the only reliable index of what their collaborators have, and asking costs one message against hours of duplicated compute. This is the compute-spend face of [[absence-needs-a-probe-that-could-see-presence]]: a probe with no discriminating power is not evidence of absence, and a filesystem has zero discriminating power over another person's laptop.

**How to apply:** when a plan includes regenerating something a collaborator might own, name it in one line and ask before launching ("the mentor may already have film@2500 — do you want me to run it, or can you get their numbers?"). Ask even when a local search comes back empty, and say "not on this box" rather than "does not exist". A summary artifact whose provenance is unstated is a POINTER to an existing run, not proof of its absence — chase the provenance by asking, not by searching. When a duplicate run has already happened, say plainly that it duplicated a collaborator's work rather than defending it on the strength of the local probe.
