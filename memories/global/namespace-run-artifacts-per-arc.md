---
name: namespace-run-artifacts-per-arc
description: Parallel agent arcs share one session scratchpad, so generic run-log names (spec-r1-run.log) silently clobber each other and destroy the evidence needed to audit a round's tier, depth, or scope
scope: global
metadata:
  type: feedback
---

Several agent arcs running in one session share a single scratchpad directory.
Generic per-round artifact names — `spec-r1-run.log`, `verdict.json`, `plan-r2-run.log` — collide across arcs, and the loser is overwritten with no error.

**Why:** run logs are the ONLY artifact that proves which model and reasoning effort a round actually used (the banner), what range it read, and whether it completed.
Once clobbered, that round's depth is permanently unverifiable — you cannot later distinguish a genuine xhigh review from one that silently ran at the base config.
Found 2026-08-18: an arc auditing its own rounds could recover the banner for every round except spec r1–r3, whose logs a sibling arc had overwritten; a separate round in that same arc turned out to have run at effort `none` and nobody had noticed for hours.

**How to apply:** namespace every run artifact by arc AND round — `<feature>/r3/lens-correctness.{log,json}`, not `r3-run.log`.
Never write two concurrent arcs to the same path.
Because the log is the evidence, treat "the log is gone" as "that round proved nothing", and re-run rather than inferring depth from the flag you passed ([[verification-claims-are-earned-per-item]], [[codex-model-tiers-and-effort-routing]]).
