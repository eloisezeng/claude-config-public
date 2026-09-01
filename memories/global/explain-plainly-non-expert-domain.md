---
name: explain-plainly-non-expert-domain
description: "Explain in plain language — not just business jargon, but the agent/pipeline machinery too; a status report she has to decode is a report she cannot act on."
metadata: 
  node_type: memory
  type: feedback
  scope: global
  originSessionId: 32bbc7d4-ba8d-4d7b-aaa4-f9a73c50c636
---

Explain decisions and status in plain language, with everyday analogies (store markdowns, selling a house, listing on a marketplace).
Define any necessary term inline.
This covers **two** vocabularies, and the second is the one that keeps slipping:

1. **Business/domain jargon** — never assume BIN / floor / comps / RDAP / zone-file / closeout is understood.
2. **My own operational machinery** — pipeline step and state names (`fix_review`, `awaiting_approval`, `pushed_head=""`), finding IDs, commit and file hashes, seat/job/session IDs, and coined shorthand like "gate loop", "fail-open", "the respond call declines everything it does not name".
   These are artifacts of how I work, not facts about her project.
   She should never have to learn my plumbing to answer a question I am asking her.

**Why:** she has said more than once that jargon-heavy framing confused her (the data contract, then pricing), and the same failure recurs in a second register — status reports written in pipeline vocabulary read as noise, so a real decision sitting inside one is easy to miss.
It is the same standard the project CLAUDE.md already imposes on the dashboard UI ("plain language, real names, no machine artifacts"), applied to my own prose.

**How to apply:**
Lead with what happened and what it means for her, in ordinary words.
When a decision is hers, state the question, the concrete consequence of each option, and a recommendation — she should be able to answer it without opening a single file.
Push identifiers, hashes and step names to the end or drop them; keep them only where she would need to paste one somewhere.
For technical/engineering calls, offer "I'll take the sensible default and move on" as an explicit off-ramp.
Plain does not mean vague: keep the measured numbers, lose the vocabulary.
[[present-options-abc-not-star]] [[check-memory-before-asking-user]] [[notify-on-response]]
