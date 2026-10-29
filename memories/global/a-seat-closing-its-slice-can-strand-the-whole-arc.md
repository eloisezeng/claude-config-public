---
name: a-seat-closing-its-slice-can-strand-the-whole-arc
description: a relay seat that finishes its OWN narrowed objective and closes its lane "completed" can leave the parent arc with no seat and no alert; give every handoff a done-check command and never reuse one handoff file for a second objective
metadata:
  type: feedback
  scope: global
---

A relay of handoff seats stopped one stage early and nobody was told.
The last seat finished a review fix queue, saw "everything owed is discharged", closed its lane as completed and dispatched no successor.
The arc it belonged to still had 9 of 34 plan tasks unbuilt, with 0 commits for any of them.

**Why:** three things lined up, and each is a general shape.

1. The handoff file written to START the last stage was reused for a different objective (the previous stage's review fixes) and gained a banner saying "that build is DONE".
   A file named for stage N whose first screen says DONE reads as stage N being done.
2. `handoff.sh --close <lane> completed` checks only that a lesson is named.
   It does not check that the work is done, and it does not check that the parent work has a live seat.
3. The parent lane stayed open in the ledger with no seat, listed as one undifferentiated row among 40, so the one signal that existed was unreadable.

**How to apply:**

- One handoff file carries one objective. A new objective gets a new file, named for what it is; never repurpose a file whose NAME still promises something else.
- Every handoff states a done-check as a COMMAND whose output is a count against the plan (for example, commits matching the task ids equals the number of tasks), not as prose. Run it before closing as completed, and paste its output in the close note.
- Before closing your own lane, name the PARENT objective and say which of three is true: the parent is done (show the check), a successor is dispatched (name it), or it is blocked on the user (alert her). "My slice is done" is none of the three.
- When investigating a stalled build, count commits per plan task before reading any status prose; the count took one command and settled what 2,235 lines of handoff history obscured.

Related: [[a-report-is-not-a-stopping-point]] · [[ops-lane-ledger]] · [[a-handoff-doc-must-not-assert-a-drop-it-has-not-made]] · [[verify-claims-against-artifacts]]
