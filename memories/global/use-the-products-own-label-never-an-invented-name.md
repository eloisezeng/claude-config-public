---
name: use-the-products-own-label-never-an-invented-name
description: Name every part in a report with the product's own display label, resolved through the code the page renders from — never an invented description of what the part does, which reads as a name and matches nothing the user can find
scope: global
metadata:
  type: feedback
---

Every component, agent, step, tab or status named in a report to the user is called by the label the PRODUCT shows her, resolved through the same code the page renders from.
A plain-English description of what a part does is not a name: written in a name's position it reads as one, and she then searches the product for a thing that is not there.

**Why:** 2026-09-11 I reported on a "valuation agent" and a "buyer-evidence agent"; she replied "i don't see either on the agent page". The page and the code had never disagreed — `plugins/your-data-product/agentGuide.ts` pairs the key `appraiser` with the label "Appraiser" and `buyer-discovery` with "Buyer check" in one map, and the page takes all 26 of its names from it. I had invented a third vocabulary that matched neither, and the fix was therefore smaller than the glossary I first proposed: a second list pairing page names to code names would be a copy of a mapping that already exists in one place.

**How to apply:**
- Resolve the label through the product's own accessor (here `agentLabel(key)`), not from memory and not by reading the key. If no such accessor exists, that is the thing to build — one map, one reader.
- Where an internal key must appear at all (a log line she is quoting back, a config row), give the label first and the key only in parentheses.
- Suspect this class whenever a name in my draft is a NOUN PHRASE describing a function ("the valuation agent", "the evidence gate", "the freshness checker"). A real label is usually shorter and blander than the description I would reach for.
- The same rule governs statuses and tabs: render what the page renders, never the stored enum.

