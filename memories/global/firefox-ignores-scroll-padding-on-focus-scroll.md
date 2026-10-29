---
name: firefox-ignores-scroll-padding-on-focus-scroll
description: "Firefox does not apply scroll-padding to the scroll a FOCUS causes — it centres the control instead; only an explicit scrollIntoView resolves the padding in all three engines"
metadata:
  node_type: memory
  type: reference
  scope: global
---

`scroll-padding` on a scroll container defines the optimal viewing region a scroll-into-view aims at, and it is how a design keeps a keyboard-focused control clear of a sticky header, an edge fade or its own focus ring — with no cost in layout.

**Chromium and WebKit honour it for the scroll `el.focus()` causes. Firefox does not.** Measured 2026-09-23, one page, `#s { height:200px; overflow-y:auto; scroll-padding:30px }`, a 24px button parked 10px below the scrollport's top edge (visible, but inside the padding band):

| engine | `el.focus()` | `el.focus({focusVisible:true})` | `scrollIntoView({block:'nearest'})` |
|---|---|---|---|
| chromium | scrollTop 390→370, gapTop **30** | 30 | 30 |
| webkit | 30 | 30 | 30 |
| firefox | 390→**312**, gapTop **88** (centred) | 88 | **30** |

So the padding is resolved for an *explicit* `scrollIntoView` in every engine, and only there is the behaviour portable. Centring happens to give more room at a top edge and less at a bottom one, so the symptom shows up as a ring clipped at whichever edge the content runs to.

**Fix by asking explicitly**: on `focusin`, `target.scrollIntoView({ block: 'nearest', inline: 'nearest' })`, gated on `target.matches(':focus-visible')` so a mouse click near an edge still scrolls nothing. Keep the CSS `scroll-padding` — the explicit call resolves against it, so the number stays written once. `nearest` is the operative part: `center` or `start` moves a control that was already clear.

Two traps when measuring this: `el.focus()` is a **no-op on the already-focused element**, so a probe that focuses the same control twice reads "no scroll" for the second engine it tests and proves nothing — use a fresh page per reading. And in a real app the region's fade is usually React state written from the scroll, so a reading taken a fixed two frames later can see the PRE-scroll fade under parallel load — see [[a-fixed-frame-count-settle-is-load-fragile]].

Reached from the suite as a Firefox-only red; confirmed as a real defect with a keyboard Tab walk, and controlled by stubbing `Element.prototype.scrollIntoView` to a no-op at runtime, which made the violations reappear — a green probe you have not controlled is not evidence ([[absence-needs-a-probe-that-could-see-presence]]).
