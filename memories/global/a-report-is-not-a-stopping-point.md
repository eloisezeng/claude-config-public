---
name: a-report-is-not-a-stopping-point
description: "Never end a turn holding approved work you only described — once approval exists, the turn that reports a finding must also start the next action, or hand it to a context that will"
metadata:
  node_type: memory
  type: feedback
  scope: global
---

When you have already approved the work ("go", "merge it", "do it"), a status report is a **checkpoint inside** the job, never the end of a turn. Ending a turn with "here is what I found, and here is what I will do next" leaves the session visibly idle while you wait — from outside, a plan and a stall are indistinguishable.

**The rule:** every turn that reports something ends in one of exactly three states, and you say which:
1. **Running** — the next action is already dispatched (a background command, a subagent, an edit in flight).
2. **Handed off** — you *dispatched* the work to a fresh context, and you name the file and where it went. Writing the handoff file is only half of a handoff: an undispatched handoff doc is not state 2, it is state 1 with nothing started.
3. **Blocked on you** — you name the single decision you need, and why no assumption is safe.

"I'll now go do X" with nothing dispatched is none of the three, and neither is *offering* to do X — "say the word and I'll dispatch one" is a permission prompt wearing a report's clothes (`[[standing-directives-are-standing-requests]]`). If a discovery invalidates the approved plan, that is state 3 — say what changed and what you need — not a licence to stop silently. If context is nearly spent, that is state 2: write the handoff and dispatch, do not stop to report the handoff you have not written.

**Why (2026-08-18, your_other_project):** you said "go" on the a large shard scale-out. Executing its first step OOM'd the production box, so I diagnosed the outage and delivered a thorough report — root cause measured, blast radius honest — and then ended the turn. Nothing was queued behind it. You next message was "why's nothing running". The report was good work; stopping after it was the defect. The diagnosis was also, by itself, enough to start the fix — I had everything I needed and chose to narrate instead.

**How to apply:** before ending any turn, ask "what is running right now?" If the answer is "nothing" and the work is not finished and not blocked on you, you are not done with the turn — dispatch the next step first, then report it as running. Pair with `[[handoff-at-boundaries-saves-tokens]]` when context is the reason you want to stop, `[[standing-directives-are-standing-requests]]` when a harness guard is tempting you to ask instead of act, and `[[report-background-progress-with-eta]]` for how to report work that IS running.
