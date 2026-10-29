# The replay fixture of arc 66648556

This is a derived, vendored copy of one real convergence arc, kept so that
`loop_test.py`'s `TestTheMotivatingArcIsRefusedByTheNewGates` can replay the history that motivated
the convergence-enforcement change of 2026-10-28.
It is a test fixture and nothing reads it in production.

## Provenance

The arc ran on 2026-10-26 and is the one the audit in that change's brief measured.
It declared convergence, merged and deployed while most of its findings carried no recorded
outcome, which is the history the new gates must refuse.

## What is real, and what is elided

Everything any gate under test reads is the arc's own: the ledger's events and their order, the six
`round-close` events, the review job names, each verdict's finding COUNT and each finding's
severity, and every outcome row's key.

Every prose field is replaced with `<elided: derived fixture, see README.md>`: a finding's body,
title context, file and recommendation, a command line, a log path, a working directory, an outcome
note.
This module publishes to a public mirror, so the fixture carries structure and no content.
None of the elided fields is read by `round_findings`, `outcome_coverage`, `outcomes_for_round` or
`range_verdict`, which is why the elision cannot change a verdict.

The outcome rows' `arc` field is the placeholder `<ARC>`; the test rewrites it to its sandbox arc,
because the outcome store keys on the arc and a row read under another spelling counts as nobody's.

## The control

`test_the_vendored_fixture_still_matches_the_real_arc` compares this fixture's structure against
the original job directory, field by field, and skips when that directory has been reaped.
Without it, "derived from the real arc" would be an assertion about a file nobody re-reads.

## The measured numbers

The arc holds 86 findings across 25 verdict files, but 80 across the 15 reviews its ledger
recorded, with 20 outcome rows.
The missing 6 are in `process-critique.verdict.json`, a verdict that exists on disk and was never
launched through `loop.py run`, so no gate could ever see it.
The test asserts the ledger-derived numbers, which are the ones the gates read.
