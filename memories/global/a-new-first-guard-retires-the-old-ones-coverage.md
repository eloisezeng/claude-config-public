---
name: a-new-first-guard-retires-the-old-ones-coverage
description: "adding a stronger guard IN FRONT of an existing one makes the older guard unreachable on every path its test drove, so the test now proves the new guard twice and the old guard's mutant goes quietly unobservable — reach the old guard explicitly from a state the new one cannot speak for, and expect the new guard to name the callers that were abusing the thing it protects"
metadata:
  node_type: memory
  scope: global
  type: feedback
  originSessionId: 2395b1dd-73a2-409d-8923-7d57798a0ea6
  modified: 2026-10-04T05:04:36.249Z
---

When you add a guard that fires EARLIER than an existing one, the existing one does not keep its
coverage — it loses it silently. Every test that drove the old refusal now stops at the new one,
so the suite still reads green while asserting the new guard twice and the old guard not at all.
Nothing in the diff says so: no test was deleted, no assertion was weakened, and the refusal
message the test matches may even still be a `StagingError`.

**Why:** a test names a CALL, not a guard. Which guard answers that call is a property of the
code's order, and the new guard changed it. Measured: a store-wide `openSync(path, 'wx')` lease
taken before an existing "refuse while ANY stage exists" scan. After an interrupted run the lease
is present, so the lease refuses first and the scan's own test — the one written for the
backwards-write defect it was built to close — never reached it again. Its mutant (narrow the scan
to this run's own id) would have survived, and read as "unobservable".

**How to apply:**
- Ask what the NEW guard makes unreachable before you ask whether it works. Enumerate the states
  the old guard was the only answer for, and find the one the new guard cannot speak for — the
  legacy store, the hand-cleaned directory, the record written by a previous version. That state
  is real and it is where the old guard still earns its place.
- Make the old guard's test reach it explicitly from that state (delete the lease, remove the new
  marker) and say in the test why. Then each guard has its own killing test and a mutant can be
  aimed at each.
- Re-check every `unobservable` label on the file you changed. A label is a measurement about a
  code path; moving the path expires it. Assert the label, so a labelled-unobservable mutant that
  DIES fails the run rather than passing quietly.
- Expect the new guard to red-light callers that were ABUSING the thing it protects, and read
  those reds as findings rather than as breakage. The lease immediately failed a test helper using
  `beginRun` as a hash calculator — open a run, stage one text, delete the stage, return — an
  abandoned transaction with no publish and no recovery that nothing could see before. The fix is
  to narrow the caller to what it actually needed, not to widen the guard.

Related: [[an-exclusion-set-must-not-include-the-catch-all]] ·
[[a-surviving-mutant-may-mean-the-property-is-unobservable]] ·
[[fix-the-class-not-the-reported-instance]]
