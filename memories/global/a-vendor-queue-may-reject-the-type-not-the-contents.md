---
name: a-vendor-queue-may-reject-the-type-not-the-contents
description: A third-party SDK queue can silently drop a command because of its TYPE while its contents look perfect — assert the shape the vendor requires and verify against the vendor's own network traffic, never against your own queue.
metadata:
  type: reference
  scope: global
---

`gtag.js` accepts a command pushed to `dataLayer` only as an **`arguments` object**. A genuine `Array` with byte-identical contents is read as a GTM command array instead, and the gtag command is dropped: **no request, no cookie, no console error**, and a `dataLayer` that inspects perfectly. Measured on one live page seconds apart (your-web-app, 2026-09-04): the same `js` / `config` / `event` commands pushed as Arrays produced **zero** requests to `/g/collect`; pushed as `arguments` they produced one immediately and set both cookies. The feature had shipped to production collecting nothing.

**Why:** every unit test asserted the queue's CONTENTS, and the contents were right. Worse, the helpers filtered with `Array.isArray(row)` — the exact predicate the vendor refuses — so the tests did not merely miss the bug, they *encoded* it and would have failed on the correct implementation. A comment in the source asserted the vendor's behaviour ("gtag.js reads its queue by index and length, so an array stands in") which was simply false and had never been checked against the vendor.

**How to apply:**

- For any hand-rolled integration with a third-party SDK, the accepted **type** of what you hand it is part of the contract and is invisible in the data. Pin it: `expect(Array.isArray(row)).toBe(false)` alongside `typeof row.length === 'number'`. That assertion is what a contents-only suite can never make.
- Verify a tracker, beacon or SDK against **the vendor's own traffic**, not your buffer. Reproduce Google's documented snippet verbatim in the same page and diff the two — the working control is what turns "it looks queued" into a measurement. Note that `performance.getEntriesByType('resource')` does not show `sendBeacon` traffic; read the browser's actual request list.
- A hostile-looking absence needs a control that can produce presence. "No `/g/collect` request" alone is consistent with a blocked browser, a bad id, or a kill switch — the vendor-snippet control run in the same context is what excludes all three at once. Checking that the id is real (Google serves a much larger, id-specific script for a valid measurement id than for a bogus one) rules out yet another.
- A comment claiming what a vendor does is a CLAIM. If a test cannot fail when it is false, the comment is load-bearing and unverified.

Related: [[verify-claims-against-artifacts]], [[absence-needs-a-probe-that-could-see-presence]], [[a-control-must-match-the-probes-shape]].
