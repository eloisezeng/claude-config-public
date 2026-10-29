---
name: a-findings-stated-radius-is-a-sample-not-a-census
description: a review finding's stated blast radius is where the lens happened to look, so census the class from the artifact with the PRODUCTION predicate before sizing the fix
scope: global
metadata:
  type: feedback
---

A finding's "this occurs in X places" is its author's SAMPLE, not a measurement. A lens reads where
it was pointed, and the places it did not read are exactly the ones nobody has counted. So before
sizing, scheduling or declining a fix, census the class from the artifact itself.

Measured: a `low` finding said two padded course codes could not match their own catalogue sentence
"across four Intelligent Systems conditions". Walked over the whole document — track conditions and
cohort deltas included, which the four did not cover — it was **241** (code, condition) pairs, every
one of them un-authorable. Two orders of magnitude, and the severity had been set from the four.

**Write the census predicate as the PRODUCTION predicate, never a stand-in.** My first pass used a
substring test where the real rule matches a whole token. It counted 107 extra pairs whose sentence
names a suffix SERIES (`Ma 1abc` for `Ma 001A`) — cases the rule deliberately refuses, since
`Ma 001A` genuinely is not named in `Ma 1abc` — and turned them into 107 false failures in a suite
that had been green. A stand-in predicate measures the stand-in.

Both numbers then belong in the assertion message, because they say different things: the subjects
are why the rule exists (and prove the fix has live work to do), the refusals are the bound the
derivation leaves open. Assert the subject count so the claim is derived from the file and cannot
rot into a typed-in number — and so the next person who widens the rule sees what it was measured
against. Related: [[counting-a-set-is-not-classifying-it]],
[[verify-claims-against-artifacts]], [[a-guard-must-be-satisfiable-not-just-failable]].
