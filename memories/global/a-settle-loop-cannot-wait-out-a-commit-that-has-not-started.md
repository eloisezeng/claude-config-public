---
name: a-settle-loop-cannot-wait-out-a-commit-that-has-not-started
description: Waiting for values to stop changing cannot wait out an async write that has not begun — two identical samples mean stable, never finished.
scope: global
metadata:
  type: feedback
---

A "wait until the numbers stop moving" loop is the WRONG instrument for an update you know is coming.
Stability is not convergence: two identical samples say the value has not moved, never that the writer has run at all.
The quiet window BEFORE an async commit reads exactly like the quiet window after it, so the loop returns on whichever one it lands in — rarely, under load, with no artifact.

**Why:** measured 2026-09-23 in your-web-app. `scrollIntoView` moved `scrollTop` synchronously while the scroll-cue fade was React state written a commit later, so the region painted the fade it owed BEFORE the scroll, over the control the scroll had just brought in — 27.20px of a focus ring under it for exactly two animation frames.
The scan's `settle()` compared consecutive frames, and frames 0 and 1 were identical AND stale, so a commit one frame late read as "settled".
An earlier round had already widened that wait from 2 frames to 30 and only narrowed the window: 1 failure in 589, only under nine parallel workers, never alone.
Removing the flush showed the lag was a real keyboard-visible defect in ALL THREE engines (60 of 126 tests: 13 chromium, 17 firefox, 30 webkit) — the engine the flake appeared in named where the weak wait lived, not where the bug was.

A PLATFORM wait is the same defect wearing a library's name, and it reads as rigorous.
Measured 2026-10-05 in your-university_scheduler: `page.waitForLoadState("load")`, placed after an action that makes the page reload itself, resolves against whichever document is CURRENT — so it returned immediately against the PRE-reload document and the read after it raced the navigation.
A marker planted before each of the test's four triggers was still present after that wait 3 times, and the 4th threw `Execution context was destroyed, most likely because of a navigation`; after arming `page.waitForEvent("load")` BEFORE the trigger, the marker was gone all 4 times.
It passed on this machine and reddened in CI, which is the signature: a race, not a slow page.

**How to apply:** when a reading has an asynchronous input, never lengthen the wait.
Prefer (c) ARM THE OBSERVER BEFORE CAUSING THE EVENT — register the listener for the NEXT occurrence, then trigger, then await it; the listener cannot miss what it was waiting for and cannot be satisfied by the state before.
Otherwise (a) remove the gap at the source — make the write happen in the SAME event as the thing that invalidated it (`flushSync`, one transaction), which fixes it for the user too; or (b) wait on a CONVERGENCE predicate — committed state agrees with the inputs it derives from — which cannot be satisfied early.
Then prove the guard can fail: arm the fix's removal as a mutant on a copy and count what reddens.
Beware the "stricter" variant that is WEAKER — dropping the wait entirely ran the whole walk in one uninterrupted task, so the async writer never got a turn and every reading carried the pre-walk value, which read GREEN against the broken build.
Check which side of the action the wait belongs on: quiescing BEFORE and reading immediately after answers what the user sees; waiting after answers a question nobody asked.
And the CONTROL for such a wait inherits the defect: my first one built the input by hand, the app rejected it, nothing reloaded at all — so "the marker survived" meant "no event happened" rather than "the wait resolved early", and it would have read the same for a correct wait.
Drive the real producer's own output, and check that the control's two arms actually disagree.
Related: [[verify-claims-against-artifacts]], [[absence-needs-a-probe-that-could-see-presence]], [[a-guard-must-be-satisfiable-not-just-failable]].
