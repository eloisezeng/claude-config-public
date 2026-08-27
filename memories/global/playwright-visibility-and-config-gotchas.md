---
name: playwright-visibility-and-config-gotchas
description: "Three Playwright traps that make UI suites report green on broken pages - opacity-0 counts as visible, emulated reducedMotion never runs the real transition, and the config is CJS so import.meta is a SyntaxError"
metadata: 
  node_type: memory
  type: reference
  scope: global
  originSessionId: 4257b721-977d-4bf0-85a8-71cb861a8202
  modified: 2026-08-10T20:00:56.990Z
---

Three independent Playwright behaviours, each of which lets a suite pass while the page is wrong. All three hit on one feature (the media clips carousel, 2026-08-10).

**1. `opacity: 0` is VISIBLE to Playwright.**
Its visibility check is "non-empty bounding box and not `visibility: hidden`" — opacity is not consulted.
So a "only one item is shown" assertion built on `toBeVisible()` passes against a stack of N transparent items.
Fix the *component*, not the test: pair the opacity fade with `visibility: hidden`, applied on a transition delay equal to the fade duration (`transition: opacity 450ms ease, visibility 0s linear 450ms`) so the outgoing layer survives its own cross-fade and only then leaves the hit-testing and a11y trees.
Also expose a stable `data-active` attribute so assertions do not depend on styling at all.

**2. `contextOptions: { reducedMotion: "reduce" }` means the suite never exercises the real transition.**
It is the right default — it makes timing deterministic — but every duration is suppressed, so a cross-fade, a slide, or a stagger is *never actually run* by the E2E suite.
Verify motion in a separate, explicitly full-motion pass, and prefer measuring `getComputedStyle(el).opacity` on every layer at ~100ms intervals over eyeballing screenshots: a screenshot after `click()` easily lands past a 450ms transition once click and capture overhead are counted, so it looks settled when it is not.
Evidence that a cross-fade is real = two layers reading intermediate opacities *simultaneously* (e.g. 0.42 / 0.58).

**3. `playwright.config.ts` is transpiled to CJS before loading, so `import.meta.url` throws.**
`SyntaxError: Cannot use 'import.meta' outside a module`, thrown before any test runs.
This is asymmetric with `vitest.config.ts` in the same repo, which Vite loads as ESM and where `import.meta.url` is fine — so copying the idiom across configs breaks.
Use `path.join(__dirname, ...)` in the Playwright config.

Related: [[verify-claims-against-artifacts]], [[data-product-ui-defaults]].
