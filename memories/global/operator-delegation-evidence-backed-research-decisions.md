---
name: operator-delegation-evidence-backed-research-decisions
description: "Standing delegation (the user, 2026-08-06; launches added 2026-08-19) — act autonomously on evidence-backed research scope/panel/recipe decisions AND on launching runs pre-specified in a reviewed committed runbook within its stated envelope, with a written decision record and post-hoc notification; stop only for genuinely new spend beyond the envelope or reinterpretation of already-reported results"
metadata: 
  node_type: memory
  type: feedback
  scope: global
  originSessionId: c87848d9-3b5e-4c17-abff-4ea3a1529820
  modified: 2026-08-06T14:42:24.054Z
---

In autonomous research operation (benchmark rounds, dataset curation, experiment pipelines), proceed WITHOUT asking on decisions that are evidence-backed — where measurements on the actual artifacts single out an option — even when they change the scored objective, panel composition, or a dataset recipe.
Requirements when exercising it: write the decision record (ADR/log) BEFORE acting, cite the measurements, and notify the user afterward in the consolidated summary.

**Launch authority (added 2026-08-19):** a pilot or run pre-specified in a REVIEWED, COMMITTED runbook, within the runbook's stated envelope (partition, wall-time, tier), launches WITHOUT asking — the review that converged the runbook IS the independent check between author and launcher.
Write the launch/decision record before or at submission, re-validate ownership and state at fire time ([[shared-runbooks-reclaim-ownership-at-fire-time]]), and notify post-hoc.

Still stop and ask for exactly two classes: (1) genuinely new spend beyond the approved envelope — anything not pre-specified in a reviewed runbook, above its stated tier (e.g. a pilot runbook does not authorize the certification tier), touching a collaborator's artifacts, or usage-based credits — and (2) anything that would reinterpret results already reported to a third party (mentor, professor, paper).

**Why:** granted 2026-08-06 during the MFFP round-3 launch after four consecutive AskUserQuestion rounds (ifc_heat promotion, weak-gap handling, pfc regeneration, option-A context) in which the user picked the "(recommended)" option every time and then asked "why did u need my approval? couldn't u have guessed?".
The launch clause was granted 2026-08-19 after the C1 pilot launch waited a round-trip for a "go" whose substance the reviewed runbook already carried.
Interruptions cost her more than the delegation risks, BECAUSE the decision-record + measurement discipline keeps every call auditable and reversible.

**How to apply:** the recommendation that would have been marked "(recommended)" becomes the action; the AskUserQuestion becomes a paragraph in the post-hoc summary.
This refines [[grill-defer-domain-judgment]] for research contexts; product/business-facing scope (your company work, outward publishing) keeps its existing ask-first rules ([[feedback-privacy-business-material]]).
