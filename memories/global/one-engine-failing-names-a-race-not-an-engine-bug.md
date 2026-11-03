---
name: one-engine-failing-names-a-race-not-an-engine-bug
description: A UI assertion failing on ONE browser engine of three is almost never that engine being wrong — it is a race or an emulation gap the other two had enough slack to absorb, so measure what the failing engine saw before touching the layout
scope: global
metadata:
  type: feedback
---

When a cross-engine UI test fails on one engine and passes on the other two, the tempting reading is "that engine lays out differently" and the tempting fix is to loosen the assertion or nudge the CSS.
**Both are usually wrong: the defect is shared by all three and only one of them lost it.**
Dump what the failing engine actually saw — the boxes, the element's own state attributes, the event it received — before changing anything.

Two measured shapes, both from one arc:

**A transform counts as scrollable overflow, so a geometry assertion taken mid-animation reports the animation.**
A board whose later rows arrive by a 10px fade-UP reported `scrollHeight 590` against `clientHeight 580` — exactly the translate — while its own `data-settled` attribute was still null.
Settled, the same board at the same viewport reported zero.
Chromium and firefox passed only because their board had more than 10px of slack to absorb it, so one engine's font metrics were the whole difference between green and red on a latent race in all three.
The fix is to anchor on the screen's own published "I have finished" signal, never on a restated schedule and never on the first frame that renders.
A screen that assembles over seconds needs such a signal, and a harness that waits for anything else is photographing a race.

**A device emulation can simply not deliver an event.**
Firefox under Playwright's `devices['iPhone 13']` fires `mousedown` and `click` and **no `pointerdown` at all**, reproducibly — while the same firefox at a plain 390x844 viewport does fire it.
So a dismiss handler bound to `pointerdown` alone left the panel open for ever on one engine of three.
Listen for every gesture-start event (`pointerdown`, `mousedown`, `touchstart`) and make the handler idempotent, so a gesture delivering two of them acts once.
The general rule: a one-engine event failure is a question about the EMULATION, not the engine, so reproduce it under the same `test.use(devices[...])` the failing test uses — a probe on a plain context measures a different browser.

Related: `[[a-fixed-frame-count-settle-is-load-fragile]]`, `[[pin-the-clock-in-clock-dependent-tests]]`.
