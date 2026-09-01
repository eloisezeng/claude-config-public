---
name: codex-claude-convergence
description: "For research/report deliverables, run a Codex↔Claude adversarial fact-check loop until no material errors remain"
metadata: 
  node_type: memory
  type: feedback
  scope: global
  originSessionId: f48ed380-1822-4dec-8d20-3376643d59af
---

When you ask for a research report or fact-heavy deliverable, you want a **Codex ↔ Claude convergence loop**: Claude drafts, then Codex adversarially fact-checks (paper attributions, arXiv IDs, reported numbers, company/product facts, internal consistency), Claude verifies each flag **against primary sources** and revises, repeating until Codex returns SHIP / no material errors.

**Why:** you explicitly asked to "do codex <-> claude convergence until report is comprehensive and doesn't have mistakes." Cross-model checking catches errors one model misses — but Codex's flags are themselves sometimes stale-training-data errors (e.g. it insisted an arXiv paper had an old title/authors that the live page had since changed), so every disputed claim must be re-verified against the live source, not trusted blindly in either direction.

**How to apply:** dispatch each round through the watchdogged launcher per [[codex-exec-hang-watchdog]] (never bare `codex exec`), as a read-only `--cd <dir>` review with the prompt on stdin. Ask for a terse severity-tagged issue list (CRITICAL/MODERATE/MINOR/OMISSION) + a SHIP / ONE-MORE-PASS verdict. Adjudicate every disputed fact with a primary-source fetch before editing. Related: [[execution-verification-prefs]] (the code-review sibling of this loop), [[visualize-in-browser]] (matplotlib, not lavish, for research figures).
