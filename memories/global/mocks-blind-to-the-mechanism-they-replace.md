---
name: mocks-blind-to-the-mechanism-they-replace
description: "A mock can be structurally incapable of seeing the behaviour under test, when the thing mocked IS the mechanism that produces it — count assertions against it are confidently meaningless"
metadata:
  type: feedback
  scope: global
---

When a test replaces a component and then asserts about behaviour that component itself implements,
the assertion cannot fail — however many cases you enumerate. Not a weak test: a **structurally
blind** one, and it reads as thorough while it does it.

Measured (2026-08-11, your-data-product registrar): money commands must never be re-sent, because the
vendor has no idempotency. Two retry layers were found and fixed, with tests stubbing `fetch` and
asserting "exactly one fetch" across network errors, timeouts, 429 and 5xx. A third path — **native
`fetch` following redirects by itself**, 20 hops, and a 307/308 preserving the method — put one
`purchase()` on the wire TWICE and resolved successfully. `vi.stubGlobal('fetch')` replaces the very
machinery that follows redirects, so no mocked-fetch test in that file could ever have seen it. It
took a real HTTP server on a real socket. A fourth path (a process-global undici dispatcher) sat
below even that, and was answered with a build-failing source guard rather than a completeness claim
the module could not back.

**Why:** enumerating more failure shapes against the same mock feels like diligence and buys nothing
once the mock is the mechanism. The tell is that every case exercises the same seam.

**How to apply:** ask what the mocked thing *does on its own* — redirects, retries, connection reuse,
caching, timeouts, protocol upgrades. Any behaviour it owns is invisible to a stub of it, so that
behaviour needs a real socket, a real process, or a guard at the boundary that cannot be stubbed.
Prefer enforcement at a CHOKE POINT (an allowlist inside the one shared call path) over flags each
call site must remember — the flag shape is fail-open, and the next command written the obvious way
silently reinherits the bug. Related: [[self-referential-fixtures-pin-nothing]],
[[verification-claims-are-earned-per-item]].
