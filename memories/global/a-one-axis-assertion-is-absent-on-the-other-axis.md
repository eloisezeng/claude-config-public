---
name: a-one-axis-assertion-is-absent-on-the-other-axis
description: "\"Does it fit?\" is two questions, and a probe that reads only one dimension is not a weak assertion on the other — it is an ABSENT one that reads green forever; make the axis a REQUIRED parameter so the compiler names every call site at once, and give each axis its own positive control"
metadata:
  type: feedback
scope: global
---

A predicate with more than one dimension answers the dimension you wrote and stays
silent on the rest, and silence is indistinguishable from a pass.

Measured 2026-09-24 on your-web-app's no-scroll guard.
Two spec files, four call sites, an explicit positive control, a printed number on every
run, pass or fail — a genuinely careful scan.
Every one of them read `scrollHeight - clientHeight`.
The region's CSS meanwhile set `flex-wrap: nowrap` with `flex-shrink: 0`, so the one way
it could fail was the one way nothing looked: at 390x844 it ran **950px of content in a
358px box, 592px of sideways scroll**, while every reading in the suite said `overflow
0px` and meant it.
Desktop measured 0px, so the defect was phone-only and the decision it broke was the
decision the whole arc existed to keep.

**Why the shape matters more than the fix.** Adding a horizontal assertion beside the
vertical one fixes the instance and leaves the class: the next probe someone writes
defaults to one axis again.
Making the axis a REQUIRED argument — no default — turns the type checker into the
census: 8 × `TS2554` at once, every existing call site forced to say out loud which
question it was asking, in CI, before anything ran.
A default would have silently answered one question for all of them; this is the same
reason a required never-defaulted parameter beats a guard.

**Watch for the sibling predicate that looks like the fix and is not.**
`assertNoHorizontalScroll` already existed in the same tree and the reviewer pointed at
it — but it reads `document.scrollingElement`, the PAGE, while the finding was about an
inner region.
Calling it would have produced a green horizontal assertion that could never see the
defect. Check what a predicate MEASURES, not what it is named.

**How to apply:** when a rule quantifies over a shape (fits, overlaps, is within, is
aligned, is reachable, is covered), enumerate its dimensions before writing the probe and
make each one an explicit argument with no default.
Give every axis its own positive control — the vertical control proves nothing about the
horizontal reading, and a control that only exercises the axis you already assert is a
second measurement that happens to be green.
Generalise past geometry: a rate limiter has count AND window, a permission has subject
AND action, a cache key has value AND version. One asserted, the other absent.
