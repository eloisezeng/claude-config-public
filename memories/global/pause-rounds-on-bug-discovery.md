---
name: pause-rounds-on-bug-discovery
description: "A bug found mid-run of an autonomous research/experiment loop is a stop-the-line event: halt launches, report blast radius, let you decide"
metadata:
  node_type: memory
  type: feedback
  scope: global
---

When a bug is discovered during an autonomous research or experiment round — a benchmark-integrity defect, an eval-layer error, a data defect, anything that could invalidate results — pause the round first, then ask you whether to fix it.
Do not let experiments keep launching while the question is open, and do not decide the fix scope alone.

**Why:** every experiment launched after the bug is found either burns compute on a question the defect has already answered, or produces results needing reinterpretation.
Case in point: your-research-project round 1's (r−1)/2 registration defect was found mid-round, the round continued, and a whole panel of "wins" turned out to be 96–100% re-learned registration artifact plus a report section of interpretation debt.
Spending the remaining budget under a known-defective reference is your call, not the orchestrator's.

**How to apply:** treat bug discovery with the same weight as a gate failure — stop orchestrator crons, hold new launches (leave in-flight jobs alone unless told otherwise), report the finding with its blast radius (which numbers move, which claims survive), and ask whether to fix now, defer to between-rounds, or continue with a caveat.
It is not a subagent-level finding to file and move past.
