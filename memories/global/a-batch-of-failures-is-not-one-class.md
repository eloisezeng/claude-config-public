---
name: a-batch-of-failures-is-not-one-class
description: a batch of new test failures sharing a plausible cause hides real defects — reproduce each one, and bisect a layout regression by holding the TEST constant and varying the BUILD
metadata:
  type: feedback
scope: global
---

When a suite comes back with N new failures and a story explains most of them, that story is a
HYPOTHESIS about each one, never a classification of the batch: reproduce every failure separately
and read its own error before touching anything.
Measured: seven browser failures, five of which plainly fit "a visitor with no account is now a
Guest" — three turned out to be REAL defects the migration merely exposed (a focus restore lost on
every modal's backdrop dismissal, a validation predicate the panel read and its own dialog did not,
a personal API call made for a visitor with no person behind it), and the handoff's named cause for
the one geometry failure was REFUTED by bisect.
Each of the three was worth fixing on its own and affected the signed-in user too, so a batch
classified rather than reproduced would have shipped three defects and weakened three tests.

**Why:** a plausible shared cause is the cheapest reading of a batch, and it is the reading that
makes every failure a test to edit rather than a defect to fix — which is exactly the direction that
loses information. A test that reddens on a correct change is evidence about the test only once you
have read what it CLAIMS; here three of them claimed something true that the change had broken.

**How to apply:** run the failures together in one command and dump each error with its own
assertion, then classify one at a time. Bisect a LAYOUT or geometry failure by holding the test file
constant and varying only the application — most runners expose an override for the built app
directory (`DISCOVER_TEST_APP_DIR` here, read by the Playwright `globalSetup`), so a second worktree
built at the suspect commit turns a bisect into one build and one run with no file copying and no
argument about the CSS cascade. Measure the SAME geometry at every width on both builds and print
the difference; the number names the cause. When the design has a prototype, grep it for the
element's own number before inventing one — the prototype sized the same card 24px taller precisely
because it already carried the control that had just been added, so the fix was its stated value
[[verify-claims-against-artifacts]].
