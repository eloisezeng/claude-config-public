---
name: merging-is-restarting-production
description: Where a push auto-deploys onto one machine, merging IS restarting production — a GATE LIST, never a hold: check in-flight work AND other actors in your window, enforce the freeze mechanically, then merge when the gates pass
metadata:
  type: feedback
scope: global
---

**This rule is a GATE LIST, not a hold.** When every gate below passes, merge — do not wait for permission, and do not treat "the merge will deploy" as a reason to stop, because that is the normal, expected consequence of merging ([[merge-green-prs-without-asking]]). What follows is how to know the gates passed; a green PR left unmerged out of deploy anxiety is its own failure, and the successor charter in `hooks/handoff.sh` states it the same way.

On any repo where a push to the default branch auto-deploys, and especially where the deploy **replaces** a single machine, **a merge is not a local decision — it is a decision to restart production.** Long-running work on that machine (a migration mid-write, a detached sweep, a batch job) dies with no controlled abort.

**Why:** on 2026-08-11 this fired three times in one afternoon on one repo. My own merge rebooted the box **13 seconds** after a live migration's process exited, and restarted a worker another session had deliberately stopped. (I first recorded that margin as 37s — the gap from its last *write*. The process ran ~24s past its last write finishing work, and killing it there would still have been damage. **Measure the margin from process lifetime, not from write activity**; the write-based number flattered it by 3x, and I only learned better because a reviewer said so.) I had been merging for hours inside a verbal "merge freeze" I had never received, because a broadcast only reaches sessions that are listening *before* they act. Then, while testing the fix, I set a two-minute drill freeze seconds before another session merged — the same reasoning error twice in one session.

**How to apply:**
- Before merging, check for in-flight work on the target — running jobs, fresh heartbeats, active migrations — not just that CI is green and the branch is current.
- **Also account for other actors acting inside your window.** State checks answer "is anything running now"; they do not answer "will someone start something in the next two minutes". On a shared repo, an action with a window needs acknowledgement, not just an announcement.
- Enforce with a **mechanical interlock**, never a convention: a job the deploy `needs:` that reads a freeze marker from the default branch and fails before the deploy tool is invoked. That is what protects the session who never heard anything.
- Build the interlock out of what the actors can actually operate. Check permissions first: Actions repo variables and branch protection both need scopes agent tokens routinely lack (403 / admin). A file on the default branch works because everyone can push. **An interlock the people who need it cannot operate is not an interlock.**
- Put the protocol in the repo's agent instructions file, not only in the tool. The mechanism is half the fix; being read at session start is the other half.
- Surface the freeze at *merge* time too (a PR check that goes red), so it is seen while deciding rather than discovered afterwards. Note whether it warns or truly blocks — hard-blocking needs branch protection, which is the human's call.
- A refused deploy does not retry itself: the default branch ends up ahead of production. The unfreeze step must deploy the backlog, and the workflow should accept a manual dispatch.

Related: [[watch-the-run-you-triggered]], [[fetch-before-you-diagnose]], [[verify-claims-against-artifacts]].
