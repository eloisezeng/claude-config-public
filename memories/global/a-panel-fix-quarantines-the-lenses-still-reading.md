---
name: a-panel-fix-quarantines-the-lenses-still-reading
description: "In a parallel-lens panel, fixing the first verdict's findings while other lenses are still reading moves the tree under them and quarantines complete verdicts — wait for the last lens to exit, then fix the round as one batch"
metadata:
  node_type: memory
  type: feedback
  scope: global
---

In a parallel-lens panel, **wait for the LAST lens to exit before fixing anything**, then fix the round as one batch.
Read-only lenses do not block each other, which is why they run panel-wide — but YOU are a writer, and editing the reviewed artifact the moment the first verdict lands moves the tree under every lens still running.
Each of those exits 5 and quarantines a verdict it had already finished writing.
An UNTRACKED artifact is the sharp case, because it moves the tree with no commit to notice: HEAD never changes, only the content, so nothing in the usual places looks wrong.

**Why it is recoverable, and why that is not a reason to relax.**
A quarantined envelope is a statement about PROVENANCE, not about the findings in it — and you must reproduce a reviewer's claim against the live artifact before acting on it regardless of how the verdict arrived, so the round can be salvaged by hand with nothing re-run and nothing re-paid.
Do not read that as "the quarantine does not matter": the recovery is hand work nobody needed to do, and a round whose envelope is quarantined may not be reported as a PASS.
Measured 2026-10-27 on a 594-line plan under three `terra`/`luna` lenses: the traceability lens landed first and its three findings were fixed at once, after which both remaining lenses finished with `rc=0` children and verdicts written on attempt 1, and both envelopes were quarantined `TREE MOVED` with HEAD unchanged (`b9525e88ed6c→b9525e88ed6c`).
The two lost envelopes held one CRITICAL and three HIGHs, every one of which reproduced exactly against the live document and the live code.

The procedure lives in the `codex-converge` skill beside the tree-lock rules; this is the fact that makes it non-obvious — [[codex-parallel-lenses-beat-serial-rounds]] · [[verify-claims-against-artifacts]] · [[enumerate-the-transforms-between-authoring-and-use]]
