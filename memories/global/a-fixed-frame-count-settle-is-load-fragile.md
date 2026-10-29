---
name: a-fixed-frame-count-settle-is-load-fragile
description: "A browser test that waits N animation frames for state to commit reads early under parallel load — wait for the VALUES the verdict is computed from to stop changing, bounded, never fewer frames than the count it replaces"
metadata:
  node_type: memory
  type: feedback
  scope: global
---

A browser assertion that reads a value a framework commits asynchronously is usually waited out with a fixed frame count — `requestAnimationFrame` twice is the folk remedy. It is a guess about a scheduler that is not rAF: React (and any scheduler-based framework) commits on its own timing, so two frames is enough on an idle machine and not enough on one running nine workers.

The failure is the worst shape available: **one test in several hundred, red only in the full parallel suite and green every time it runs alone**, so it reads as flake and gets re-rolled. Measured 2026-09-23: adding a scroll at focus time added one commit, and a scan that waited two frames then read the fade the region carried *before* the scroll — a violation the screen did not have.

**Wait on the numbers, not on frames.** Build a signature from exactly what the verdict is computed from (the element's box, each ancestor's scroll position and the custom properties read), step a frame at a time, and stop when two consecutive readings agree:

- **Bounded** (~30 frames ≈ half a second), and a screen still moving after that is read as it stands — a scan that hangs says nothing at all.
- **Never fewer frames than the fixed count it replaces**, so the change cannot be a weakening.
- **The assertion itself is untouched.** This is why it is a strengthening: a test that was measuring early now measures late, and a genuinely violated screen still fails.


Related: [[pin-the-clock-in-clock-dependent-tests]] · [[wall-clock-ceilings-measure-the-machine]] · [[firefox-ignores-scroll-padding-on-focus-scroll]].
