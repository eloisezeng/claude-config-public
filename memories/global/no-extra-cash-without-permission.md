---
name: no-extra-cash-without-permission
description: "Never spend extra-usage credits without explicit permission — binds the DEFAULT workflow's burn rate (model tier, fan-out, session length), not just rogue loops"
metadata:
  node_type: memory
  type: feedback
  scope: global
---

Do NOT consume usage-based billing ("extra usage credits") on top of the user's base plan without explicit permission.

This binds in two places, and the second is the one that gets missed:

- **Discrete actions** — autonomous loops, scheduled wakeups that re-fire the model, agent fleets, heavyweight context reads, hours-long polling. Ask before starting.
- **Steady-state burn from sanctioned work** — [[execution-verification-prefs]] makes codex-converge the DEFAULT arc, and that arc is itself a fleet dispatcher. Run as instructed on the top model tier it outspends any rogue loop. A workflow being requested does not make its burn RATE authorized.

**Why:** two burns, one class. 2026-06-05: ~$500/day from an autonomous loop plus wakeup polling. 2026-08-14→16: ~$878 of credits from ordinary review-convergence work — $3,035 of list-price tokens in three days, 96% of it Fable 5, 53% of turns in subagents, 69% of the cost in cache re-reads. Neither was caught in flight, because credits engage **silently**: there is no prompt when plan limits are crossed, and a response's `usage` cannot tell you which side of the line you are on. There is no gate at spend time, so the gate must sit at configuration time.

**How to apply:**
- Default: assume no credit budget exists. "Go ahead" authorizes that action, never a rate.
- **Model tier is the largest single lever** — Fable 5 is $10/$50 per MTok, exactly 2× Opus 5's $5/$25. Route review lenses, verifier passes, and mechanical subagents to Opus 5 or below; reserve Fable 5 for long-horizon autonomous work that earns the premium. State the tier before a fan-out, don't inherit it.
- Cap fan-out width, and hand off at task boundaries ([[handoff-at-boundaries-saves-tokens]]) — in a long session cache re-reads dominate the bill, so every extra turn re-pays for the whole accumulated context.
- Prefer one-shot foreground checks over ScheduleWakeup/loop polling; for long cluster jobs hand over the artifact path plus harvest command ([[long-job-completion-email]]).
- Credits are **org-scoped** at your-company; the user is `organizationRole: user` with `can_toggle: false`, so her burn eats a cap shared with the team and she cannot switch credits off herself. A hard stop needs an org admin in Console.
- Read state from `extra_usage` / `cachedExtraUsageDisabledReason` in `~/.claude.json`; derive per-day actuals from `~/.claude/projects/**/*.jsonl`, deduping by `message.id`.
