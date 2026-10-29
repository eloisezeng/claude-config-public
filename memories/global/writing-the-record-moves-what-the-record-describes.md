---
name: writing-the-record-moves-what-the-record-describes
description: Progress-recording and read-only measurement collide on one tree — a checkpoint naming its own ship SHA is stale the moment it commits, and a mid-review write quarantines the review; snapshot a detached worktree at the SHA and keep the live tree writable.
metadata:
  type: feedback
scope: global
---

"Record progress as you go" and "measure a frozen commit" are in **direct
conflict on a single working tree**, and the conflict is invisible until it
costs a round. Both standing directives are right; what is wrong is running them
against the same tree. Two faces, one cause — writing the record changes the
thing the record describes.

**A checkpoint that names its own ship SHA is stale by construction.** Write
"the reviewed head is `<sha>`" into the handoff file, commit the file, and HEAD
is now one commit past the SHA the sentence names. There is no diligence that
fixes this from inside the sentence: the commit that publishes the claim is the
commit that falsifies it. So a handoff names the RANGE START and says
"re-resolve HEAD at launch", never a ship SHA; and a successor re-resolves
rather than trusting the text. Measured on job_hunt 2026-10-04: my owed-gates
section said `95b4ef0..a82516c`, the real range was `95b4ef0..423a9e8` — 21
commits, 38 files — and the successor caught it only because the handoff told it
to re-resolve.

**A mid-review write quarantines the review.** `loop.py` fails a read job whose
tree HEAD or `git status` moved while it ran (rc 5, output quarantined) —
correctly, because a review of a tree that moved under it proves nothing. So
"write progress into the handoff file as you go" would have voided four
concurrent verdicts on one arc. The fix is not to stop recording progress:
`loop.py snapshot` pins a DETACHED worktree at the SHA, every read job reads
that, and the live tree stays writable for the progress record. Both survive.

**And when a verdict IS quarantined, adjudicate it by MEASURING what moved —
never by discarding it and never by waving it through.** The verdict file is
written; the question is whether it is about content that moved. A review that
diffed a RANGE read immutable blobs, so the answer is a diff:
`git diff --name-only <reviewed-head> <moved-head>` against the verdict's own
`reviewed.files` manifest. Measured on job_hunt 2026-10-04, this exact
collision again, one window after the memory above was written: the move was a
one-file docs commit, the manifest named 26 files, 25 were byte-identical across
it, and the findings stood on that basis. Re-buying the review would have been
spend outside the envelope for a fact a `git diff` already carried. Record the
adjudication, not the escape — and note the recurrence is the point: knowing
the rule did not stop me running the writer against the reviewed tree, so arm
`loop.py snapshot` BEFORE the launch rather than intending to stay quiet.

The general move whenever a measurement and a bookkeeping write touch one
artifact: **give the measurement a frozen copy, not the writer a quiet period.**
A quiet period is a discipline that holds until the first interleaving; a frozen
copy is a fact. Same shape as pinning a CI run by the commit you pushed rather
than reading "the latest run" — `[[watch-the-run-you-triggered]]`.

See also `[[a-compacted-fork-forgets-it-is-a-fork]]` (stamp HEAD and
`git status` on BOTH sides of any long verification),
`[[close-the-reviewed-head-gate-by-measuring-identity]]` (the gate that fails by
construction after every fix, for the same reason this SHA goes stale), and
`[[isolate-agents-that-mutate-the-tree]]`.
