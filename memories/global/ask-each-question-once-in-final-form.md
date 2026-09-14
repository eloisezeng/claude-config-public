---
name: ask-each-question-once-in-final-form
description: Put each question to the user ONCE, in its final form — hold any question whose premise rests on a pending fact until the fact lands, and never re-show an answered question as open
scope: global
metadata:
  type: feedback
---

Every question put to the user (a grilling round, a design Q&A, a Lavish review page) is shown once, in its final form.
A question whose premise depends on a fact a running helper, probe, or measurement will return is not asked until that fact is in hand.
An answered question never reappears as an open question.

**Why:** 2026-09-11, a grilling session: I posted a four-question round while a fact-finding helper was still tracing the bug's origin.
Its report contradicted Q2's premise (I had said a written rule already existed when the bug was written; the rule came nine days later), so I re-posted a corrected Q2.
She replied "why do u keep correcting ur questions. i just want to see final version of questions."
Earlier, a Lavish page re-rendered a question she had already answered, and she found that equally redundant.

**How to apply:**
- Before posting a round, list each question's premises and name the source of each fact. A premise resting on a pending result waits for it; ask only the questions whose premises are already measured.
- A smaller round now plus the dependent questions once the facts land beats a full round that later needs revising.
- If a posted premise proves wrong anyway, fold the corrected fact into the next round's question text a single time; do not re-post the round as a separate correction.
- Show answered questions only as a one-line "confirmed: <answer>", in the terminal or on a Lavish page (track answered `data-lavish-question` keys there).

Related: [[grill-defer-domain-judgment]], [[present-options-abc-not-star]], [[a-report-states-facts-not-confessions]], [[brainstorm-in-lavish]].
