---
name: an-unparsed-remainder-report-is-an-obligation
description: a parser returning an "unrecognised leftovers" list has created a duty at every consumer; until one consumes it the report is decoration, and a consumer treating unrecognised as absent is the bug
metadata:
  type: feedback
  scope: global
---

When a parser returns both what it understood AND what it did not (`{ kinds, unrecognised }`, `{ parsed, leftover }`, `{ matched, unknown }`), that second field is an OBLIGATION on every consumer, not a courtesy to the caller.
Until some consumer branches on it, it is decoration — and the failure mode is not that the report is ignored, it is that the consumer silently reads **unrecognised as absent**, which is the opposite verdict.

**Why:** the two states differ in what they license. "This names no source" means nothing is owed and the ordinary rule applies; "this names a source I have never heard of" means something IS owed and must not be acted on. Measured: `sourceKindsOf('SimplifyJobs + Handshake')` was built to report `Handshake` in `unrecognised` precisely so it could not vanish, and then `rowDisposition` read the empty known-source list as "nothing claims this row" — which on the first run would have deleted every row whose only source that build had never heard of. I wrote the reporting channel and left it unconnected, and then wrote a test ("is not listed when it names no source at all") that blessed the gap: the test's own subject was the disconnected state, so it read green over the defect.

**How to apply:** at the moment you add an unparsed-remainder field, name its consumers and make it a REQUIRED never-defaulted parameter of each one — the compiler is then the census, failing at every call site at once in CI rather than on one production path later. Write the test for the non-empty remainder in the SAME commit as the field, and distrust any test whose subject is the empty-remainder case: it cannot tell "understood nothing" from "understood nothing I know about". Related: `[[encode-the-invariant-in-the-shape-not-another-guard]]`, `[[unambiguous-status-and-logs]]`, `[[absence-needs-a-probe-that-could-see-presence]]`.
