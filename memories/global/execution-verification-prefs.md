---
name: execution-verification-prefs
description: "the user's global verification pipeline — Playwright-grounded Claude↔Codex convergence review on real fixtures, every project"
metadata: 
  node_type: memory
  type: feedback
  scope: global
  originSessionId: 8db8ef80-46cd-4f5e-8c18-e1db968b5050
---

The user's standing verification pipeline for **every project**: work is never just declared done — it converges under cross-AI review grounded in fresh runtime evidence.

**Each round:**
1. Capture fresh Playwright E2E evidence — drive the real app as an end user (screenshots, console errors, actual DOM), reflecting the current code.
2. Claude reviews the diff *plus* that evidence.
3. Codex reviews independently against the same evidence.
4. Fix, repeat until BOTH reviewers agree the observed behavior is correct AND the E2E evidence is clean — "converged" is a claim about behavior, not just code.

**Playwright vs plain convergence:** use the Playwright-grounded loop whenever the change is observable in a running UI/app — seed a local instance through the REAL code path (not hand-inserted data), and have both AIs verify via independent Playwright scripts. For work with no UI surface (backend/agent-internal logic, migrations, shell/config, library code), run the plain Claude↔Codex convergence loop until no blocking findings remain. Codex has repeatedly caught real bugs Claude-only review missed.

Supporting habits: real fixtures, never mocks (exercise the artifacts an end user actually hits); one E2E run per review round, not per micro-edit; re-verify after each meaningful slice, not as a single end gate.

**Why:** she weights quality over development cost. Grounding every round in E2E evidence catches runtime bugs *inside* the loop instead of after a "converged" review gets invalidated; a passing unit test alone is never sufficient evidence for her.

**Use the packaged skill, from the first turn.** The tracked `codex-converge` skill runs this whole arc (brainstorm → spec → converge → plan → converge → execute → review-till-converge, with the watchdogged codex launcher). Invoke it **by default at the START** of any build/fix/audit — this is not a review-time-only rule, and it does not wait for her to ask. The failure mode is reading "convergence" as a thing that happens after the work: hand-rolling the brainstorm and spec, then belatedly reaching for the skill, means the spec never got its Codex pass and the plan inherits whatever Claude alone missed. If a stage is already done solo, don't restart — enter the skill at the current stage and give the existing artifact its missing Codex pass before moving on.

Related: [[feedback-fix-dont-just-note]], [[codex-exec-hang-watchdog]], [[review-the-commit-that-is-checked-out]].
