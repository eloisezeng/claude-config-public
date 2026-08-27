---
name: playwright-forcedcolors-fixture-noops
description: Playwright's `test.use({ forcedColors })` silently does nothing; use page.emulateMedia and assert the mode is on as the test's premise
scope: global
metadata:
  type: reference
---

`test.use({ forcedColors: 'active' })` **silently no-ops** — measured on Playwright 1.62.1,
Chromium, macOS: `matchMedia('(forced-colors: active)').matches` stays `false`.
`page.emulateMedia({ forcedColors: 'active' })` and `browser.newContext({ forcedColors: 'active' })`
both work, and sibling options in the *same* `test.use` call (`viewport`, `colorScheme`) do apply
— so the failure is specific to this one option, not to fixture options in general, and nothing
about the test's shape hints at it.

**Why it matters:** the test still passes. Forced-colors assertions are usually written as
"the fallback indicator exists", which is true whether or not the mode is on, so the test proves
nothing while reading as accessibility coverage. Worse, reading a computed value in that state
returns the *authored* CSS and invites a confident wrong conclusion about how the browser
behaves — that is exactly how "getComputedStyle is blind to forced-colors adjustment" got
written down as a fact. It is not: with the mode genuinely on, `box-shadow` computes to `none`
(CSS Color Adjustment §3.1) and `getComputedStyle` reports `none`.

**How to apply:** turn the mode on with `page.emulateMedia`, and make
`expect(await page.evaluate(() => matchMedia('(forced-colors: active)').matches)).toBe(true)`
the first assertion in the test. That premise line is the whole defence — it is what turns a
silent no-op into a red test. Generalises past this one option: any test whose subject is an
*emulated environment* must assert the environment before asserting the behaviour, or it can
pass for the wrong reason — see [[absence-needs-a-probe-that-could-see-presence]] and
[[verify-claims-against-artifacts]].
