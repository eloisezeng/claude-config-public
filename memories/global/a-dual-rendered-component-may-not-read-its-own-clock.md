---
name: a-dual-rendered-component-may-not-read-its-own-clock
description: A component that renders on both the server and the client may not read its own clock — pass it in as a REQUIRED never-defaulted parameter, because a default lets the next call site reintroduce the bug with every test green
scope: global
metadata:
  type: feedback
---

`Date.now()` inside a `'use client'` component is a hydration-mismatch **class**, not one bug. Such
a component renders twice — once on the server for the SSR html, once in the browser at hydration —
against two different clock readings. Any derived string that is not stable across those readings
("2m ago", "in 5h 20m", a countdown, a "today"/"yesterday" label) disagrees whenever the two
readings straddle a boundary, React reports a mismatch and **regenerates the whole subtree**. It is
not a test artifact: it fires on any slow render, which means production under load.

**The fix is a required parameter, and that is the enforcement mechanism** — not a style choice.
`relTime(at, nowMs)` with no default reddens every call site at once in CI (measured: 12 `TS2554`
plus ~40 `TS2741` in one `tsc` run, which is also how you *enumerate* the sites — the compiler is
the census). A defaulted clock leaves every existing site green and lets the next one reintroduce
the defect on one page, invisibly. Render from `nowTick ?? initialNowMs`, where `nowTick` starts
`null` and a 1s effect fills it in: the SSR snapshot until the browser takes over.

Three traps, each measured:

- **Seed the clock at the JSX site, not inside a props builder**, when that builder is also an API
  payload. A server clock has no business in a JSON response.
- **Read it from the MOUNT props, never from polled state.** A merge like
  `mergeAgentsState(prev, next) => ({ ...next, agents })` takes `next` from an API payload that
  carries no clock, so the field is `undefined` from the first poll onward — a bug that appears
  30 seconds after load and never in a test that does not poll.
- **A re-render counter is not a clock.** `const [, setTick] = useState(0)` bumped every second,
  while the label still calls `Date.now()`, forces the re-render *and* keeps the mismatch.

**An e2e pass is weak evidence for this class** — it needs a runner slow enough to cross the
boundary — so pin it deterministically: mount the SAME props at `NOW` and at `NOW+59s` and require
identical markup, plus a positive control on the FIXTURE proving those two readings genuinely
disagree (without it the pair passes on a component that reads the wall clock, and asserts
nothing). Control the component itself with the one-token pre-fix mutant.

Pinning a clock also **exposes latent wall-clock dependencies in existing tests** — a freshness
assertion matching `/…ago/` silently required today's date to be past a fixture's timestamp, because
a relative-time helper that clamps the future renders "just now". Pin later than every fixture and
say so. See [[pin-the-clock-in-clock-dependent-tests]] and
[[strictmode-latches-a-dispose-on-cleanup-resource]] — the same shape of defect, invisible to the
unit suite and caught only by driving the real page.
