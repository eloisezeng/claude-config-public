---
name: a-computed-custom-property-is-the-ancestors-value
description: "CSS custom properties INHERIT, so reading one off getComputedStyle is reading whatever ancestor last set it — never the element's own value; a scan that reads --x off a descendant accuses it of its container's state, and the artifact that spends the value is the only thing that says whose it is"
metadata:
  node_type: memory
  scope: global
  type: reference
---

`getComputedStyle(el).getPropertyValue('--x')` answers for the nearest ancestor that set `--x`,
not for `el`. Custom properties inherit by default, so every descendant of the element that set
one computes it as its own. A measurement that reads one as "this element's value" is therefore
not a measurement of that element at all, and it reads perfectly plausible numbers.

**Why:** a custom property is a value in the cascade, and the cascade inherits. Nothing about the
read says where the value came from. Measured 2026-10-28 in chromium, webkit and firefox: a
scroll-region fade was published as `--cue-top` / `--cue-bottom` on the scrolling element, and the
mask that spends them was declared on that element alone. Five text spans several levels inside one
such region each computed a 32.0px bottom fade — their container's — and a scan reading it as
theirs accused each of them twice over: of painting a fade with nothing beyond it, and of resolving
a fade it never painted. The class was latent across all seven regions in the app.

**How to apply:**
- Ask whose value it is before you read it. If the answer is "the element that OWNS this feature",
  gate the read on something that identifies that element — the class or attribute the rule which
  sets it is keyed on — rather than on the property's presence.
- Prefer reading the ARTIFACT that spends the value (the resolved `mask-image`, `background`,
  computed length) over the variable: an element that paints nothing has no fade whatever it
  inherited. But check first that gating on the artifact does not retire a check you have for
  "resolved it and never painted it" — that pair needs the variable AND the artifact.
- `@property { inherits: false }` fixes it at the source and is the better CSS, but it makes the
  reading depend on per-engine `@property` support. Where the reader is a test instrument running
  across several engines, fix the instrument; where the inheritance is a product defect, fix the
  CSS.
- The same shape holds for anything inherited that a scan reads per element: `font-*`, `color`,
  `visibility`, `direction`. A per-element reading of an inherited value is a reading of its
  ancestor.

Related: [[a-new-first-guard-retires-the-old-ones-coverage]] ·
[[a-new-detectors-first-run-measures-the-detector]]
