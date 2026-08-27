---
name: no-extra-cash-without-permission
description: "Never spend extra-usage credits without explicit permission — binds the DEFAULT workflow's burn rate (model tier, fan-out, session length), not just rogue loops"
metadata:
  node_type: memory
  type: feedback
  scope: global
---

Do NOT consume usage-based billing ("extra usage credits") on top of the base plan without explicit permission.

This binds in two places, and the second is the one that gets missed:

- **Discrete actions** — autonomous loops, scheduled wakeups that re-fire the model, agent fleets, heavyweight context reads, hours-long polling. Ask before starting.
- **Steady-state burn from sanctioned work** — a default review-convergence arc is itself a fleet dispatcher. Run as instructed on the top model tier, it outspends any rogue loop. A workflow being requested does not make its burn RATE authorized.

**Why:** credits engage **silently**. There is no prompt when a plan limit is crossed, and a single response's `usage` block cannot tell you which side of the line you are on.
Because there is no gate at spend time, the gate has to sit at configuration time — before the fan-out, not during it.
The expensive burns are rarely the dramatic ones: ordinary sanctioned work at the top tier, in long sessions, with wide fan-out, costs more than a runaway loop, and nobody notices because every individual turn was authorized.

**How to apply:**

- Default: assume no credit budget exists. "Go ahead" authorizes that action, never a rate.
- **Model tier is the largest single lever** — the top tier can be several times the price per token of the tier below it. Route review lenses, verifier passes, and mechanical subagents down; reserve the top tier for long-horizon autonomous work that earns the premium. State the tier before a fan-out; do not inherit it.
- Cap fan-out width, and hand off at task boundaries ([[handoff-at-boundaries-saves-tokens]]) — in a long session, cache re-reads dominate the bill, so every extra turn re-pays for the whole accumulated context.
- Prefer one-shot foreground checks over scheduled-wakeup polling; for a long batch job, hand over the artifact path plus the harvest command and let the job notify you ([[long-job-completion-email]]).
- Credits are usually **org-scoped**, and an ordinary member typically cannot switch them off. Find out whether you can before assuming a hard stop exists; if you cannot, the only control you have is the one above.
- Read the current state from the client's own config (an `extra_usage` field and whatever records why it is disabled), and derive per-day actuals from the local session transcripts, deduping by message id so a resumed session is not counted twice.
