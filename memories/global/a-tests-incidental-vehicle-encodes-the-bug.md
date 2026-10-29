---
name: a-tests-incidental-vehicle-encodes-the-bug
description: "When a correct fix reddens a family of tests sharing one fixture value, swap the VEHICLE rather than rewrite each expectation — the value was chosen for convenience and the fix just invalidated the precondition it silently carried"
metadata:
  node_type: memory
  type: feedback
  scope: global
---

A test family that all drives one fixture value — one course code, one user id, one
feature flag, one row — chose that value because it was *convenient*, not because
the property under test is about it. The value therefore carries an unstated
precondition ("this one counts toward that row", "this account is an admin"), and a
correct fix that changes which values satisfy the precondition reddens the whole
family at once, each red wearing the title of the behaviour just removed.

**Read the batch as evidence about the VEHICLE, not about each assertion.** Ask what
precondition every red shares, find a value that genuinely satisfies it, and
substitute. One substitution preserves every assertion's intent; editing the
expectations one at a time rewrites ten tests into agreement with the new code and
destroys what they were pinning. This is the companion to
touching either side, this one says the cheapest correct repair is usually upstream
of the assertion entirely.

**Why:** a correct narrowing stopped a generic "advanced math" course tag from
opening a requirement's CLOSED course list. 8 assertions across 5 test regions in
one file and 2 in a second went red, every one of them using `ACM 100A` as a
stand-in for "a course on a row with several fallbacks" — a course that was only on
that row *through the bug*. I started rewriting them individually (rewrote one
region's expected row, then had to revert it) before asking what they shared.
`Ma 003` is genuinely on the closed list and on a second major's too, so one
substitution at 105 sites restored all 10 with their assertions byte-identical;
only a notice ordered by course code moved, which the rename alone explains.

**How to apply:** when ≥3 tests redden on one fix, diff their fixtures before their
expectations. Name the shared precondition in a comment at the vehicle's definition
so the next change knows why that value and not another. And check the substitute
against *every* list the family relies on — picking one that satisfied only the
first major's requirement would have moved the reds instead of clearing them.
