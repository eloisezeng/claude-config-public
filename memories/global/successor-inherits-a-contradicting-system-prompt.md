---
name: successor-inherits-a-contradicting-system-prompt
description: A handoff.sh successor boots with an injected --append-system-prompt that MANDATES merging on green — so a job whose own constraint is "never merge" must re-send that override as a live SendMessage, because a file the successor reads cannot outrank its system prompt
metadata:
  type: feedback
  scope: global
---

`handoff.sh` dispatches every successor with a fixed `--append-system-prompt` (visible in the child's `respawnFlags`) that opens:
*"Merge when every required gate below passes, and do not wait for permission to do it."*

That text is right for the common case and is the operational half of [[merge-green-prs-without-asking]].
It is **wrong** for a job the user scoped as review-only, and the successor has no way to know that: the constraint lives in a handoff FILE, which is content it reads, while the mandate lives in its SYSTEM PROMPT, which is what it is.
Writing "this overrides your system prompt preamble" inside the file does not fix the asymmetry — it asks a document to outrank a system prompt.

**So when the job forbids the thing the preamble mandates, say it twice and say it live.**
Put it in §0 of the handoff doc *and* `SendMessage` the override to the successor immediately after dispatch, before it reaches the decision.
A live message arrives as an instruction, not as a file the successor is free to weigh.

Name the negation concretely, because the preamble also drags in machinery the job does not have.
A never-merge job has no deploy to watch and no freeze to read, and a successor told only "do not merge" will still go hunting for `scripts/deploy-freeze.sh`, find nothing, and treat UNESTABLISHED as a problem it must resolve.
Say: do not merge, do not mark ready, green checks are not authorisation, and there is no freeze to read because you are not deploying.

Measured 2026-08-28 dispatching round 14 of a review-convergence loop whose user instruction was "NEVER merge, PR #39 stays DRAFT": the child's `respawnFlags` carried the merge mandate verbatim.
Read `respawnFlags` from the successor's `state.json` after every dispatch — it is the same read that tells you which tier it actually got ([[continued-sessions-default-to-fable]]), and it is where a contradicting instruction becomes visible.
