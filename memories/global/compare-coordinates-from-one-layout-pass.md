---
name: compare-coordinates-from-one-layout-pass
description: A geometric assertion that subtracts two separately-read boxes measures two MOMENTS as much as two positions, so under load it reports the element MOVING as a misalignment, and every wait-longer fix fails because the page really is settled by the time anyone looks.
metadata:
  node_type: memory
  scope: global
  type: feedback
---

Read every co-ordinate you are going to COMPARE inside one layout pass — one `evaluate`, one
`getBoundingClientRect` batch — never as two or three separate `boundingBox()` calls.
Each call is its own round-trip to the page, so subtracting two of them yields the difference
between two positions AND two moments; while anything is still reflowing, the moment term
dominates and the assertion reports motion as misalignment.

**The signature is a failure that looks impossible, which is why it survives several review
rounds.** Measured 2026-10-09 on a private frontend repo: two identical flex siblings under
`align-items: center` read a stable 6px apart in roughly half of full-suite runs. They cannot be
6px apart, and they never were — the row moved 6px between the read of one box and the read of the
next, right after a viewport switch to 390px.

**Three measurements that each look like a dead end name it together:**
1. The bad value is STABLE and survives a long poll, so the layout being read is SETTLED. That is
   what rules out a mid-reflow page — and, misread, is exactly what makes the bug look impossible.
2. It fails at one call site only, the one immediately after a resize, navigation or mount.
3. It does not reproduce with the spec ALONE; it needs full-suite parallel LOAD.

A load-sensitive geometric failure that survives polling is a READ straddling a reflow, not a page
that is wrong. Polling cannot fix it and is the trap: a poll that compares two separately-read
boxes re-measures the same straddle on every retry, so it reads as "the cure did not work" and
sends you hunting CSS. A `document.fonts.ready` wait fails for the same reason.

Control the fix in BOTH directions, because a single-pass read is also the easy way to make the
assertion vacuous: plant a real misalignment (a `margin-top` on one control) and require the
assertion to redden, then remove it and require the suite to green with the stylesheet unmodified.
Expect the planted value to arrive ATTENUATED — a 6px margin read as 3px, because
`align-items: center` absorbs half of it — so assert on the tolerance being exceeded rather than on
the number you injected.

`[[a-subset-run-is-not-a-suite-run]]` because this class is invisible to every isolated run.
