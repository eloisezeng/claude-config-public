---
name: reconcile-aggregates-against-raw-rows
description: "Every aggregate (count, total, timestamp, 'and N more') must be reconciled against the raw rows it summarizes, with a test that would fail if the arithmetic drifted"
metadata:
  node_type: memory
  type: feedback
  scope: global
---

An aggregate that reads plausibly is not an aggregate that is correct. Whenever code rolls many rows into one summary line — a count, a sum, a representative timestamp, a "…and N more" — write the test that compares the summary against the raw rows it claims to describe, and verify it fails if the arithmetic drifts.

Three defects from one review, all the same shape, none caught by tests that only asserted the rendered text:

- **A count that multiplied.** `SUM(COALESCE(payload.count, 1))` was applied to every event type, but `count` meant "multiplicity" for only one of them. Three retries of 100-item chunks rendered as "300 retries." Fix: allowlist which types carry a multiplicity, everything else counts rows.
- **A timestamp that lied.** A daily rollup stamped itself with the day-bucket start, so an event two minutes old rendered "12h ago" — and sorted below everything else that day, where a cap could truncate it away entirely. Fix: `MAX(created_at)`, not the bucket boundary.
- **A cap that hid rows the UI promised to count.** Items were dropped before the truncation counter saw them, so "…and N more" understated by the dropped amount.

**Why:** the rendered string looks right in every test that asserts the string. The failure is in the relationship between the summary and its inputs, which only a reconciliation test can see. This is the aggregate-side twin of [[verify-claims-against-artifacts]].

**How to apply:** for each aggregate, assert the invariant, not the output — displayed count plus truncated count equals rows in window; the summary's timestamp equals the newest contributing row; the sum over groups equals the total over raw rows. Seed a fixture with the *real* payload shapes (grep the actual writers — assumed payload shapes are where these bugs live), including at least one type that superficially resembles the special case but isn't. Related: [[unambiguous-status-and-logs]], [[data-product-ui-defaults]].
