---
name: max-20x-subscription-context-discipline
description: Billing moved to the Max 20× subscription (2026-08-16) — Fable is fine to use, but context size is the burn lever; watchdog + 200K auto-compact enforce it
metadata:
  type: user
scope: global
---

Since 2026-08-16 you run Claude Code on the **Max 20× subscription** (the older you@example.com org) rather than metered API credits, and said plainly: "we can use fable now we switched to max 20x".

**Why:** The 13–16 Aug spend audit showed 94% of context is replayed tool traffic and half the cost sat in requests above 400K context. On a subscription the dollar rate is gone but the 5-hour and weekly usage limits still meter the same token flow — so model tier is no longer the lever to argue about; **window size and session length are**.

**How to apply:** Don't push model downgrades for cost; Fable is the accepted default. Instead honor the mechanical guards installed that day: `autoCompactWindow: 200000` and the `context-watchdog` hook (`~/dotfiles/claude/hooks/context-watchdog.mjs`) — when it says hand off, finish the step, write the handoff file, and end the session rather than riding the window up. Resuming a large session after >1h re-writes the whole cache; prefer /clear + restate. This refines, not replaces, [[no-extra-cash-without-permission]] — burn RATE still binds via the weekly cap, and [[handoff-at-boundaries-saves-tokens]] is now hook-enforced.
