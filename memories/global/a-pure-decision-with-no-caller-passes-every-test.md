---
name: a-pure-decision-with-no-caller-passes-every-test
description: a computed verdict nothing consumes passes its own unit test, its counts, its status row and the whole suite — census the READER side and test through the body, because no test of the pure function can fail for the absence of a caller
metadata:
  type: feedback
scope: global
---

A pure decision with **no consumer** is invisible to every signal you have. Its unit test passes — the function is correct. Its counts are written and look plausible. Its status row says `active`. The suite is green. The defect is not IN a function, it is the ABSENCE of a call, and a test of the function cannot fail for that: it would have passed on day one.

Measured in one pipeline, one arc, **five instances of the same shape**, each found only by running the thing:

- A resolution step with no caller at all.
- A screen that computed a keep/remove verdict, wrote its counts to the run record — so the artifact read green — while the next step issued work from the **unscreened** set.
- A field-writer map naming `judgment` the owner of four opportunity fields that **nothing wrote**: 29 of 29 scored records stored `"unknown"` for each, leaving three live readers unreachable in production, *while the score beside them was right the whole time*, which is exactly what hid it.
- A seeded reproducible audit sampler, row writer and tally, complete and uncalled, so the measurement the specification demanded had never been taken.
- A value one step parsed correctly that the schema gave **nowhere to go**, so it was recomputed as "unknown" downstream and scored wrong in both directions.

**What this means for how to look.** The census is on the **reader** side, never the writer: ask *who calls this* and *who reads this field*, and get a count. A map, a docblock or a field-owner table that NAMES a writer is a claim, not a mechanism — nothing checks that the named writer exists. Grep for the symbol and classify every hit production / test-only / none.

A step whose verdict nothing consumes is also the thing that makes a *removal rule* dead: measure what each branch of a decision actually fired on real data, and read a branch that fired **0 times** as a question, not as a clean bill — one of mine could not fire at all, because the field it tests is never populated by any adapter.

**And what it means for the test.** Pin it through the **body** and read the **published artifact**, not the pure function. State that in the test's own comment, because the next reader will reasonably ask why it is not a unit test. Prove it by reverting the **call site alone** and quoting the value the assertion read — mine read `'strong'` where the fix gives `'probably_ineligible'`, which is better evidence than an empty field, because the wrong implementation left a *plausible* value behind.

