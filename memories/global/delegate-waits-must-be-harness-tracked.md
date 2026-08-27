---
name: delegate-waits-must-be-harness-tracked
description: "A background delegate waiting on an external artifact must use a harness-tracked blocking wait and re-check the artifact on every wake — detached watcher loops and completion notifications both fail silently, stalling the pipeline for hours"
metadata:
  node_type: memory
  type: feedback
  scope: global
---

When a background agent hands work to an external process (a `codex exec` review, a long build, a remote job) and must resume when its output lands, the wait itself is load-bearing infrastructure — treat it as such.

**Why:** two failure modes have each cost a multi-hour silent stall. (1) A detached `while`-loop watcher does NOT survive host process cleanup, so the artifact lands and nobody wakes: one verdict sat unread overnight, another for ~10 hours, while the pipeline looked "in flight". (2) A completion notification is a single delivery with no retry — if the delegate is mid-turn, hits a model/API limit, or dies, the signal is simply gone. Both fail *silently*, which is the dangerous part: the coordinator sees "running" and keeps waiting instead of investigating.

**How to apply:**
- Wait with a mechanism the harness itself tracks (a `run_in_background` bounded until-loop that re-invokes you on exit), never a fire-and-forget detached watcher, and never a notification alone. Belt AND braces where the stage is expensive to redo.
- **A SUBAGENT cannot wait on its own background job: the moment it ends its turn "waiting", it is dead and nothing re-invokes it.** Never write "run in background and poll" into a subagent prompt — instruct foreground exec with a generous timeout, or keep the long command in the COORDINATOR'S own `run_in_background` (which does re-invoke the coordinator). A delegate report that says "waiting for my background job" is a FAILED dispatch: take the work back or re-dispatch, immediately — do not hold.
- **On every wake, re-check whether the artifact already landed BEFORE arming a new wait** — the commonest stall is arming a watcher for something that arrived while you were dead.
- Bound the wait and make the timeout a real event: a wait that expires must report "still absent after N", never exit quietly looking like success.
- The coordinator polls the artifact directly (file mtime, queue state) rather than trusting a delegate's "in flight" claim; a status report is not evidence — verify against the artifact the step should have produced ([[verify-claims-against-artifacts]]).
- Write those artifacts to SHARED storage, never node-local `/tmp`: on a multi-node cluster a resume can land on a different node and the evidence becomes unreachable.

Related: [[worker-liveness-must-reflect-progress]], [[background-subagent-parallel-workflow]], [[codex-exec-hang-watchdog]], [[handoff-at-boundaries-saves-tokens]].
