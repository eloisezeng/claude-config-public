---
name: verify-the-bottleneck-before-building-the-fix
description: "Before building a throughput fix, measure which stage is actually binding — a plausible first diagnosis is routinely the wrong stage"
metadata:
  type: feedback
scope: global
---

When asked to raise throughput ("aim for 100 a day", "make it faster"), measure **which stage is actually binding** before writing any code. Instrument the real system: per-stage counts per day, per-stage queue depths, and the stage logs' own words.

**Why:** on 2026-07-23 I diagnosed a starved domain pipeline as "the appraiser rests because the standing card is full", explained it confidently to you, and got approval to build that fix. Measuring the live DB first would have shown the diagnosis was wrong in two ways: sourcing was fine (134k names/day, not dry), and the appraiser was already driving and *saying so* in its own log ("the day's card is 194 short but no scored names remain"). The binding constraint was one specific lane frozen by a full card — a related but different fix, in a different function, with a different expected effect. A second measurement pass also killed a plausible-but-wrong "AI credits exhausted" theory in one query.

**How to apply:**
- Query the funnel stage-by-stage *before* proposing a fix: intake per day, promotions per day, queue depth at each hop, and the ratio between them. The stage whose output collapsed is the one to fix.
- Read the agents' own log/audit lines. A well-instrumented system usually states its blocker in plain language; that beats inferring from code.
- Treat a first-read diagnosis as a hypothesis even when it explains the symptom — a wrong stage still produces a fix that ships, passes tests, and changes nothing in production.
- When measurement contradicts a diagnosis you already gave the user, say so plainly and correct it before building. See [[verify-claims-against-artifacts]].
- Separate "unblocks the mechanism" from "achieves the number", and tell the user which one you delivered — unfreezing a lane is not the same as the funnel yielding 100/day.
