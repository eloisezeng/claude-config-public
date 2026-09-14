---
name: continued-sessions-default-to-opus
description: The user 2026-09-11 "in the future default to opus" — every handoff, revival and re-dispatch runs on claude-opus-5[1m]; her 08-21 Fable default is RETIRED; read the tier off the child's respawnFlags
metadata:
  type: feedback
scope: global
---

**The user, 2026-09-11, verbatim: "in the future default to opus."**
She said it right after asking why a build seat had been dispatched on Fable.
It retires her 2026-08-21 rule ("whenever we continue sessions default to fable unless we used up fable limit").
Her 2026-08-23 word "revive the sessions with opus whenever they die" already put revivals on Opus, so the rule is now uniform.

**The rule:** every handoff successor, crash revival, `--force` re-dispatch and ordinary continuation runs on **`claude-opus-5[1m]`**.
Do not pass Fable to "honour a default"; that default no longer exists.
Pick another tier only when she names one for that seat, or for a plumbing seat (relay, watch, hold, read), which belongs on Sonnet under `[[fleet-burn-budget]]`.

**Why:** Fable 5 costs $10/$50 per MTok, twice Opus 5's $5/$25, measured 2026-08-23, and it carried 34% of fleet spend over a 4-day window.
She has now chosen the cheaper tier as the standing default.
Tier is the burn-rate lever the fleet has, alongside fan-out width and session length (`[[no-extra-cash-without-permission]]`).

**How to apply — it is mechanical:**

- `settings.json` sets `env.CLAUDE_HANDOFF_MODEL = "claude-opus-5[1m]"` for every session on both config roots, since `~/.claude1/settings.json` is a symlink to `~/.claude/settings.json`.
  `hooks/handoff.sh` resolves `MODEL="${CLAUDE_HANDOFF_MODEL-claude-opus-5[1m]}"`, so the env var and the fallback constant now agree.
  Before 2026-09-11 they disagreed: the constant said Fable while the env var said Opus, so the Fable default fired only where the variable was unset.
- An explicit `--model` always wins.
  `CLAUDE_HANDOFF_MODEL=""`, the EMPTY string, opts out to whatever `claude --bg` picks, which is why the script uses `${VAR-…}` and not `${VAR:-…}`.
  Tests AB2, AB3 and AB4 in `tests/handoff.test.sh` pin all three branches.
- **Read the tier off the CHILD, never off the flag you passed or the documented default.**
  A bg seat's environment carries the tier it was launched on, and `${VAR-default}` falls back only when the variable is unset, so a seat launched on another tier hands that tier to every seat it dispatches.
  Measured 2026-08-24: a seat believed it had launched Fable, and the child's `respawnFlags` read `["--model","claude-opus-5[1m]"]`.
  Report the tier from `~/.claude/jobs/<id>/state.json` `respawnFlags` or from the transcript's `message.model` (`[[verify-claims-against-artifacts]]`).
- Do not churn a session that is already running onto a new tier.
  The rule is about how a session is *continued*, and a mid-flight switch costs the run and buys nothing.

**A tier's limit is a MEASUREMENT, never an inference from dead seats.**
On 2026-08-21 three sessions published "Fable is spent" from three cap-killed dispatches while another session was producing Fable turns, and an `/login` account switch had lifted the cap roughly 70 minutes before the first turn came back.
Before calling any tier spent, scan `~/.claude/projects/**/*.jsonl` for assistant records whose `message.model` carries that tier and take the latest timestamp; boot a throwaway probe only if the transcripts are silent.
A login, a banner, a roster row or a `state.json` `detail` does not settle whether a tier is available; only a real assistant turn does (`[[absence-needs-a-probe-that-could-see-presence]]`).
