---
name: codify-as-rules-not-skills
description: "When deciding where to put guidance: prefer always-on instructions over invoke-when-remembered skills for always-relevant rules, and test a proposed skill against a no-guidance control first"
metadata: 
  node_type: memory
  type: feedback
  scope: global
  originSessionId: 7a88ef9c-6357-4092-8e66-2ba2050a19aa
---

For anything that should apply *every time*, codify it as an always-on instruction (CLAUDE.md / Working directives), not a skill. A skill only fires when invoked; an instruction is always loaded, so for design constraints and "verify before done" the instruction is strictly more reliable. Reserve skills for genuine procedures run at a discrete checkpoint.

**Why:** on 2026-06-27 a proposed dashboard-verification skill tested **redundant** — following the writing-skills Iron Law, a no-guidance control (fresh agents, no project rules) already self-verified UI changes thoroughly (cross-view consistency, enum collisions, filter/sort keying, live render). The model already had the instinct; a skill would have enforced behavior it already does, while being less reliable than always-on rules. The real fix was an always-on CLAUDE.md section, not an invoked skill.

**How to apply:** before authoring any discipline/verification skill, run the no-guidance control the writing-skills Iron Law demands — if the control doesn't exhibit the failure, don't write the skill. And classify the need: always-relevant → instruction; discrete invoked procedure → skill. Pairs with [[extract-learnings-proactively]].
