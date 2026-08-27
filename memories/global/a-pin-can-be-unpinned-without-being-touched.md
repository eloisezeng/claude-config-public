---
name: a-pin-can-be-unpinned-without-being-touched
description: A test that pins a region or a self-reported count can be silently unpinned by an edit that never touches the test — a new subsection widens a slice, and reconciling a count retargets the mutant that pinned it; enumerate the pins, re-anchor never retarget
scope: global
metadata:
  type: feedback
---

A pin fails open when the thing it points AT moves, and nothing in the pin's own text looks wrong afterwards.
Two measured instances of one class:

- **Widened scope.** A region read as "from heading A to heading B" was written when A and B were adjacent.
  Someone later wrote A-prime *between* them, so the slice grew to span both sections and every assertion over it could be satisfied by the new section's text.
  Measured, not theorised: the mutant renaming A's key SURVIVED, because A-prime still named it.
  The end anchor must be **the heading that immediately follows**, and that invariant itself gets a property that walks the document's real heading sequence.
- **Retargeted count.** Where a doc states counts about its own suite, reconciling a number tempts you to re-point the existing mutant at whatever number you just changed.
  That pins the new one, quietly unpins the old, and makes the mutant's NAME false.
  **Re-anchor, never retarget:** every self-count gets its own arm, in the same commit that changes it.

When either shape recurs at a second site, stop hunting instances: enumerate every pin with its scope and its target, classify three ways, and report the count — see [[enumerate-recurring-defect-classes]] and [[fix-the-class-not-the-reported-instance]].
A pin is only worth the edits it can survive, which is the same idea as [[plan-assertions-need-reachable-alternatives]].
