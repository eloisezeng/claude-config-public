---
name: grill-with-docs
description: A relentless interview to sharpen a plan or design, which also creates docs (ADR's and glossary) as we go.
disable-model-invocation: true
---

Call the Skill tool twice, for "mattpocock-skills:grilling" and
"mattpocock-skills:domain-modeling".

This is a short-name alias so `/grill-with-docs` keeps working. The skills it
calls are Matt Pocock's, installed as the `mattpocock-skills@mattpocock` plugin
(https://github.com/mattpocock/skills, MIT) rather than vendored as copies —
so they update with the plugin instead of freezing at whatever was copied.
The plugin ships its own `grill-with-docs` too, reachable as
`/mattpocock-skills:grill-with-docs`; this file exists only for the short name.

## Hold every question until the fact-finding has reported

Post no round of questions while any fact-finding you dispatched for this
grilling is still running.
Wait for every one of them to report, fold what they found into the tree, and
only then put the round to the user.
This applies to every round, not only the first one.

This instruction OVERRIDES the grilling skill's rule that a running exploration
blocks only the questions downstream of it and that the rest of the frontier
should be asked immediately.
The user asked for this on 2026-09-13, and the reason is that a question written
before the measurements land is a question she may have to answer twice: the
facts routinely move the recommendation, and a round that arrives with its
numbers already attached costs her one reading instead of two.
It is the same rule as `[[ask-each-question-once-in-final-form]]`, applied to
the grilling loop.

While you are waiting, keep working and say what you have found so far.
Findings, corrections to a stale premise, and progress are all fine to report.
The numbered questions are the only thing that waits.
