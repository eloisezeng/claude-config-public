---
name: an-assertion-may-be-satisfied-by-the-path-it-excludes
description: a test's passing assertion is often not the one stating the rule — a regex over text the excluded failure path echoes back, or a broad assertion that short-circuits before the specific one runs
metadata:
  type: feedback
  scope: global
---

When a mutant dies or a guard passes, read WHICH assertion decided it, never that the test
failed. Two shapes make the deciding assertion a different one from the rule's own, and both read
green:

**A regex over text the excluded path quotes back.** `assert.rejects(p, /lookup failed/)` is the
only assertion that an upstream failure is reported AS that failure — and it survives deleting the
branch that reports it, because the error text then reaches `JSON.parse`, whose `SyntaxError` reads
`Unexpected token 'T', "The lookup failed." is not valid JSON` and matches the regex. Assert an
error by EXACT message plus constructor identity (`error.constructor === Error`), never by a
pattern the failing path can echo. Measured with `node -e` before believing it.

**A broad assertion that short-circuits the specific one.** A spec asserting an alert's full text
BEFORE asserting a button's absence never reaches the absence check, because the button renders
INSIDE the alert and joins its text content — so the mutant dies reported as WRONG COPY and the two
`toHaveCount(0)` assertions that state the rule are never exercised against a violation. Order the
SPECIFIC assertion first, but behind an explicit wait for the element, or a bare absence check on
an unrendered page passes for nothing.

**Why:** a kill is not a pinning unless the killing assertion is the one that states the rule.
Attribute per ASSERTION, not per test — `[[verification-claims-are-earned-per-item]]`.

**How to apply:** at mutation time, read the failure's own output (expected vs received, and the
line) rather than the pass/fail count. A kill by an assertion other than the rule's is a FINDING,
and its fix is ordering or exactness, not another test. Sibling shape for constants: an expectation
READ from the constant under test pins nothing — raising a cap the test imports moves the
expectation with it, while a cap pinned by a literal dies. Measured on one file: the turn limit 20
was killed, the character limit 4,000 survived every test in the same file —
`[[a-gate-may-not-read-its-verdict-from-the-gated-party]]` ·
