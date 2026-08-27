---
name: test-the-mechanism-you-advertise
description: "If a product tells users \"do X to get Y\", there must be a test that doing exactly X produces Y — the instruction is a contract"
metadata: 
  node_type: memory
  type: feedback
  scope: global
  originSessionId: 69d878c0-e5d6-4004-bc3f-04971ad0be1c
  modified: 2026-08-10T17:55:12.238Z
---

When a product **tells a user to do something specific** — reply STOP, type DELETE to confirm, send
`/reset`, click the link within 24 hours — that sentence is a contract with a person outside the
system. Pin it with a test that performs **literally what the text says**, byte for byte, and
asserts the promised outcome.

The failure is quiet and survives review, because the code around it looks careful. Measured
2026-08-10: outreach emails ended "simply reply with the word STOP", while the inbound parser's
opt-out regex required an object after the verb (`stop emailing`, `stop contacting`). A bare `STOP`
matched nothing — in **any** letter case, since the pattern already carried `/i`, so "it's a
lowercase bug" was the wrong diagnosis and would have fixed nothing. The regex had thoughtful
comments, a deliberate false-positive guard, and its own tests; none of them tried the one input the
product instructs people to send. 282 contacted leads had been told to reply STOP; the opt-out table
had zero rows, ever.

**Why:** tests are written from the implementer's model of the input space, and the advertised
instruction lives in a different file — a template, a docs page, a UI string — so nothing forces the
two together. The user-facing sentence is the specification, and it is the one nobody runs.

**How to apply:** grep the templates, UI copy, and docs for imperatives aimed at users; for each,
write a test whose input is the exact advertised string and whose assertion is the promised effect.
Where the copy is configurable, derive the test's input from the same constant the product emits so
the two cannot drift. When the mechanism is legally or ethically load-bearing (opt-out, consent,
deletion, cancellation), also check whether it has *ever* fired in production — a feature that has
never once succeeded live is indistinguishable from one that cannot.

Related: [[verify-claims-against-artifacts]], [[feedback-spec-stated-rules-exactly]].
