---
name: extract-learnings-proactively
description: "After a batch of corrections, turn the patterns into durable rules without being asked — and ask when a fix is unclear"
metadata: 
  node_type: memory
  type: feedback
  scope: global
  originSessionId: 7a88ef9c-6357-4092-8e66-2ba2050a19aa
---

When the user gives a run of corrections or feature nudges, don't just fix each one — distill the recurring *classes* and write them where they'll fire next time (project `CLAUDE.md` for always-on rules, memory for recall). She's asked for this twice ("write any skills so you aren't making these sort of mistakes again", then "extract your learnings so I don't have to correct you as often").

**Why:** repeating the same correction is the failure mode she most wants gone; she values that I learn faster more than that I fix any single item.

**How to apply:** treat a cluster of similar complaints as a signal to codify a rule, not N one-off fixes. Prefer `CLAUDE.md` (loaded every session, overrides defaults) for project rules and a terse memory for cross-cutting style. If any fix she requested is ambiguous, ask rather than guess. Pairs with [[check-memory-before-asking-user]] and [[dev-pipeline-plan-subagent-converge]].

**Codify as an always-on rule, not a skill, when it should apply every time** — see [[codify-as-rules-not-skills]]. Most of the user's historical TO-DO corrections were product-expectation gaps (missing features), not verification skips, so the fix was an always-on CLAUDE.md section, not an enforcement skill.
