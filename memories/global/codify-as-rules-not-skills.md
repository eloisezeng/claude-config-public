---
name: codify-as-rules-not-skills
description: "When deciding where to put guidance: the TRIGGER decides, not the format — a skill needs a recurring moment a session recognises, and guidance with no such moment must be an always-on instruction"
metadata: 
  node_type: memory
  type: feedback
  scope: global
  originSessionId: 7a88ef9c-6357-4092-8e66-2ba2050a19aa
---

The format never decided whether guidance fires; the TRIGGER does.
Before choosing a home, name the moment the guidance must fire at, in the words a session will already be thinking while it works.
A moment that RECURS and is RECOGNISABLE ("at the start of any build, fix or audit") earns a skill: the procedure and its measured facts go in the skill body, and ONE line in `CLAUDE.md` names that moment.
A moment you cannot name — "periodically", "when relevant", "before shipping" — earns no skill, because nothing will invoke it; put it in an always-on instruction or accept that it will not fire.

**Why:** measured 2026-09-13 over 2,240 transcripts. Only 228 sessions (10.2%) invoked any skill; **64 of the 83 skills offered per session have ZERO invocations**, and `codex-converge` alone is 179 of all 345 invocations. `repo-housekeeping` HAS its trigger line in `CLAUDE.md` and still has zero — its trigger says "periodically", which is no moment. The one skill that fires is the one whose trigger names something that happens constantly. Both halves of the old reasoning moved: skills fire even less reliably than feared, AND "an instruction is always loaded" is no longer true — `CLAUDE.md` went 3,815 B/14 directives (2026-06-27, when this rule was written) to 71,066 B/145, the global index 5,090 B to 28,315 B against a hard 20,000-char budget, and `[[measure-what-reaches-context-not-disk]]` measured 56% of memories reaching NO session for months.

**Cost, which is the reason to move anything at all:** a skill costs only ONE listing line in a session — name plus description, mean 248 B across the 83 offered in this root, on top of a fixed 2,754 B header — and its BODY is free until invoked — `codex-converge`'s 78 KB body costs nothing per session. `CLAUDE.md` costs its full 71,066 B every session, 94.6% of it the 145 working directives at a mean 463 B each. So a procedure-shaped directive with a real moment belongs in a skill; a constraint that must colour every turn does not, whatever it costs.

**How to apply:** (1) name the moment, or route to an always-on instruction; (2) never write a trigger vaguer than the one you would accept as an alarm; (3) run the writing-skills no-guidance control ONLY for DISCIPLINE skills, where a fresh agent might already have the habit — EXEMPT skills whose content is measured facts the model cannot know (a billing rule, a repo's shard count), since no control can exhibit ignorance of a number you measured yourself. Pairs with [[extract-learnings-proactively]] and [[measure-what-reaches-context-not-disk]].
