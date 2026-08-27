---
name: mark-fixture-data
description: Mark placeholder/stub data that is shaped like real data with a FIXTURE marker
metadata: 
  node_type: memory
  type: feedback
  scope: global
  originSessionId: bc8819fd-f806-4d1c-a2d4-bb5677f23ee6
---

When introducing stub/seed data that *looks* like real data (plausible rows, real retrieval logic around it), mark it explicitly — e.g. `// FIXTURE — replace via <ingest path>` on the loader, or a `_comment` field in a JSON data file.

**Why:** you agreed this is important. A stub shaped like real data is more dangerous than an obvious one — nothing forces the swap, and it can silently drive wrong behavior. Concrete instance: `plugins/your-data-product/data/comps.json` held 8 synthetic comps that looked real, with a comment "Retrieval is real data" (true of the algorithm, misleading about the dataset). It went unnoticed through dry-run (no real outcomes ever tested it) until run against the live feed, where every domain clustered to the same 2 comps. See [[da-comps-namebio-retailstats]].

**How to apply:** when you write fixture/seed data or a default provider meant to be replaced, add a visible FIXTURE marker naming the real source, and don't write comments that imply the data is real when only the surrounding code is.
