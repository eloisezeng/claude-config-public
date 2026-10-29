---
name: a-check-reading-the-pr-body-cannot-be-fixed-by-a-rerun
description: A CI step reading PR metadata from the event payload keeps failing after you fix the body, because a re-run replays the stored payload — only a fresh pull_request event carries the new text
metadata:
  type: reference
  scope: global
---

A CI step whose input is `${{ github.event.pull_request.body }}` (or any other `github.event.*`
field) reads the payload GitHub **stored when the event fired**, not the current state of the pull
request.
So when such a check fails on the body and you fix the body, two things that look like the obvious
repairs both do nothing: `gh run rerun` replays the same stored payload and fails identically, and
editing the body does not re-trigger the workflow at all, because a bare `pull_request:` with no
`types:` defaults to `opened, synchronize, reopened` and **`edited` is not among them**.

The cheap fix is to **close and reopen the pull request**: `reopened` is a default trigger type, it
builds a fresh payload carrying the corrected body, it needs no force-push, and it leaves no empty
commit in the history. Pushing a commit works too (`synchronize`), but only because the push is what
mints the new payload — not because the commit changed anything the check reads.

Two traps sit beside this one.
A rollup check can fail purely as a consequence: here the required `test + typecheck` reported
`scopeNotSuccessful` with every shard **skipped**, so the one real failure was a single
millisecond-long string parse in a different job, and reading the required check's name as the
subject would have sent me into the test suite.
And do not try to confirm the stored body through a REST read — `gh-axi api .../pulls/N --jq .body`
truncates at roughly 2–3 KB, so a line past the cut reads as absent (measured: 3,372 of 4,078 bytes,
and my `grep` for the line found nothing on a body that contained it). Read it with
`gh-axi api POST graphql --field query=…` instead — `[[gh-axi-rest-truncates-long-fields]]`.

Before pushing the corrected body, run the validator the check runs, on the text you are about to
send, **plus a control that is the exact form that failed** — a one-sided check passes for a fix
that was never needed. Measured 2026-10-28 on `your-other-project` PR #521: `repairsLineVerdict`
accepts exactly `none`, `none.` or a list of `#NNN` references, so `Repairs: none — this is a
documentation correction` parses as neither and returns `invalidValue`; the corrected bare line
returned `{filled: true, kind: 'none'}` and the control still returned `invalidValue`.
The general rule that names: a prose explanation belongs **near** a machine-parsed line, never
**on** it — `[[verify-claims-against-artifacts]]`.
