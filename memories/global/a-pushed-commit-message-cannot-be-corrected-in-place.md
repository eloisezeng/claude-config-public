---
name: a-pushed-commit-message-cannot-be-corrected-in-place
description: a number in a commit message is a claim on an append-only surface, so measure before writing it, never add counts from two passes, and never force-push to fix one
metadata:
  type: feedback
scope: global
---

A commit message is an APPEND-ONLY surface for numbers.
Everywhere else a wrong figure is corrected silently in place; once a commit is pushed the only
in-place fix is a force-push, which is forbidden, so the correction has to live somewhere the
reader may never look.

So the measurement must PRECEDE the writing, with the measured value pasted rather than typed.
Two failure shapes, both measured in one session (2026-10-14, your-university_scheduler PR1):

- **Adding counts from two edit passes.** A message claimed an axis was swept "on all 88
  candidates" — 72 regex substitutions plus 16 conversions. The passes overlapped and one also
  matched text inside the helper definitions, so 88 was never a count of call sites. Under one
  stated rule (occurrences of the six helpers' names followed by `(`, less their six definitions)
  the figure is 66, over 59 lines. A count is not a measurement until its rule is stated —
  `[[verify-claims-against-artifacts]]`.
- **Typing a figure while the real one is printing in the same turn.** A message said
  `check_cache_bust` gave "25 PASS"; the command in the same turn printed 32. Nothing was wrong
  but the number.

**How to apply:** run the command, read its output, then compose the message with that output's
value — never draft the message first and fill the number in from expectation. Where a figure is
derived, write the DERIVATION in the message beside it, so a reader can re-run the rule instead of
believing the total. A pre-drafted commit message's number clauses are predictions about an
artifact that did not exist when they were written, and must be re-checked at commit time —
`[[a-setting-is-not-a-rate]]`. When a pushed message is already wrong, state the correction in the
NEXT commit's message and in the handoff or lane the next reader actually opens; never force-push
to tidy it.
