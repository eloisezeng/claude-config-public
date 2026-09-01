---
name: continued-sessions-default-to-fable
description: The user 2026-08-23 supersedes for REVIVALS — a dead seat comes back on Opus, standing, no asking; her 2026-08-21 Fable default still governs ordinary handoff continuations
metadata:
  type: feedback
scope: global
---

**The user, 2026-08-21: "whenever we continue sessions default to fable unless we used up fable limit."**

**SUPERSEDED FOR REVIVALS — the user, 2026-08-23, verbatim: "revive the sessions with opus whenever
they die."** Typed directly, immediately after a `/login` that lifted a weekly account cap, and
followed by "revive sessions". Standing, not a one-off, and unconditional on its face — *whenever*
they die. So:

- **A seat that DIED comes back on `opus[1m]`. No probe, no asking, no Fable attempt first.** This
  removes the entire measure-the-tier your-project below from the revival path: you no longer need to
  establish whether Fable is spent before re-dispatching a corpse, because the answer does not change
  what you launch. `handoff.sh` still defaults to Fable, so `--model 'opus[1m]'` must be passed
  explicitly on every revival.
- **The 2026-08-21 Fable default still governs ordinary continuations** — a planned handoff at a task
  boundary, a fresh successor for a live objective. Nothing died there, so nothing supersedes it.
- The measurement discipline below is still load-bearing for *those* dispatches, and for reporting;
  it is only the revival branch that no longer needs it.

Authored record, quotable by any session that will not take a peer's header on trust:
`~/code/your-other-project/HANDOFF-fleet-limit-revival.md`, section
`## UPDATE 2026-08-23 — the 18:09Z weekly-limit wave, and the user's STANDING revival instruction`.
Applied 2026-08-23 to six lanes after a fleet-wide weekly cap-kill at 2026-08-22T18:09:36Z; all six
verified alive at their own transcripts on `claude-opus-5`.

So the model for a handoff successor, a crash revival, or any `--force` re-dispatch is
**`claude-fable-5[1m]`**. `opus[1m]` is the FALLBACK, taken for exactly two reasons:

1. Fable's own limit is spent **as established by a probe, not by inference** (see below), or
2. the successor died on the turn-1 `[reasoning_extraction]` safeguard (~10% of Fable dispatches —
   `[[background-fleet-memory-budget]]`). Verify a Fable successor cleared ~12k tokens before
   trusting the dispatch; re-dispatch a casualty on `opus[1m] --force`.

**"Spent" is a MEASUREMENT, never an inference from corpses.** A tier is available or not only as of a
dispatch that actually took a turn. On 2026-08-21 three Fable dispatches died in under 3 s each with the
literal detail `You've reached your Fable 5 limit.` (19:23:55Z, 20:57:06Z, 21:12:05Z), and three sessions
independently published "Fable is spent" as a measured fact and moved a whole runbook to `opus[1m]` — while
another session was producing Fable turns at 21:35:56Z and a throwaway probe dispatched at 21:36:44Z
survived turn 1 and completed. **The cap was lifted by the user running `/login` (an account switch)** —
measured by `your-other-project-b2`, and the same lever that cleared the 2026-08-21 fleet-wide stall.
**But the login is the LEVER, not the MOMENT — never date a lift from the account event.** On
2026-08-22 the switch was ~02:0xZ and the cap did not clear until between **03:08:14Z** (last
`<synthetic>` cap-kill in the corpus) and **03:11:38Z** (first Fable turn back) — a ~70-minute gap, in
which a seat died on the cap at 02:22:51Z. Dating recoveries from the login mis-attributes every seat
that died inside that hole as killed by a safeguard, a stall or a bad dispatch. Date it from the
artifact: the corpus scan below gives it to the second, for free. So
deaths in a window show a quota was exhausted THEN, and an operator can lift it at any moment without
telling any session; they say nothing about now. (I first wrote "quota windows roll" here — plausible, and
not what happened. Do not publish the MECHANISM of a recovery you did not measure either.) This is `[[absence-needs-a-probe-that-could-see-presence]]` wearing a tier
costume, and it inverts the user's rule while every session believes it is obeying it — opus is the
documented fallback, so choosing it on a false premise records as compliance.

**Probe it, but read the CORPUS first — it is free and no dispatch is needed.** The fleet is continuously
generating the evidence: scan `~/.claude/projects/**/*.jsonl` for `type=="assistant"` records whose
`message.model` carries the tier, and take the min/max timestamps. On 2026-08-22 that measured the hole
exactly — 11,675 files, **zero** `claude-fable-5` turns between 01:30Z and 03:11:38Z, first turn back at
03:11:38.025Z, 93 turns within eight minutes. Only if the corpus is silent do you need the throwaway
boot: dispatch a scratch handoff with **no `--model` flag** and read `~/.claude/jobs/<short>/state.json`
plus the transcript's `"model":"…"` stamps. Run it in both directions — never infer the quota came back
either.

**An operator's account switch is NOT the lift, and dating from it mis-attributes a whole hour of
corpses.** The `/login` above is the lever, not the timestamp. On 2026-08-22 a session dated a revival to
a ~02:0xZ login; a dispatch died on the cap at **02:22:51Z**, twenty minutes later, and no Fable turn
existed until **03:11:38Z** — so every seat that died in that hour would have been recorded as killed by
something else. The only artifact that settles a lift is a real assistant turn carrying the model; a
login, a banner, a roster row and a `state.json` `detail` settle nothing. Corollary worth its own line:
the seat whose death established "spent" is often the fastest disproof later — `53aaed9b`, cited fleet-wide
as proof of the cap, was producing healthy Fable turns at 03:19:02Z. Re-read the corpse before quoting it.
This is `[[verify-claims-against-artifacts]]` at the tier layer: the EVENT that should cause a
change is not evidence the change happened.

**Why:** on 2026-08-21 eight concurrent Opus sessions exhausted the plan's session cap in ~35 minutes,
which stalled the whole fleet silently — a stall records no turn, so no session could report it
(`[[a-session-cannot-see-its-own-stall]]`). Tier is the burn-rate lever the fleet actually has, and
it is one the user has now set; it sits alongside fan-out width and session length under
`[[no-extra-cash-without-permission]]`.

**How to apply — it is mechanical, not a thing to remember.** `hooks/handoff.sh` defaults
`MODEL="${CLAUDE_HANDOFF_MODEL-claude-fable-5[1m]}"`, so every caller gets it:

- explicit `--model` always wins (that is the documented route to the Opus fallback);
- `CLAUDE_HANDOFF_MODEL=""` — the EMPTY string, hence `${VAR-…}` and not `${VAR:-…}` — opts back out
  to whatever `claude --bg` itself picks;
- pinned by tests AB2/AB3/AB4 in `tests/handoff.test.sh`, mutation-verified (reverting the default to
  `""` turns AB2 red).

**The Fable default DOES NOT FIRE inside a background seat, and nothing warns you.** A bg session's own
environment carries `CLAUDE_HANDOFF_MODEL` set to the tier *it* was launched on (`claude --bg` exports it).
`${VAR-default}` only falls back when the variable is **unset**, so every seat a bg seat dispatches
silently inherits the parent's tier and the Fable default is dead code on that path. Measured 2026-08-24:
seat `2b9a9ca6` (opus[1m]) dispatched a review seat with no `--model`, believed it had launched Fable,
and told the user so; the child's `respawnFlags` read `["--model","claude-opus-5[1m]"]`. Nobody
hand-passed a tier — the environment did, which is exactly the case the "do not hand-pass a tier to
defeat the default" rule does not cover. So: **read the tier from the CHILD's own `respawnFlags` (or its
transcript's `message.model`), never from the flag you passed or from the documented default** — this is
`[[an-armed-watcher-holds-its-boot-config]]` at the dispatch layer, and `[[verify-claims-against-artifacts]]`
for the report. To actually get the default from inside a seat, pass `--model` explicitly or clear the
variable (`CLAUDE_HANDOFF_MODEL= handoff.sh …` gives `claude --bg`'s own pick, not Fable).

Do **not** churn already-running sessions to move them onto Fable: the word is about how a session is
*continued*, and a mid-flight model switch buys nothing while costing the run.

**COST FACT, measured 2026-08-23 (does not reverse her default — makes its price visible):** Fable 5
is **$10/$50 per MTok, twice Opus 5's $5/$25** — the most expensive model on the menu, not a cheap
one. Across a measured 4-day fleet window Fable carried 34% of spend. So this Fable default is a
*capability* choice being paid for at 2x Opus, and the 08-23 revive-on-Opus word is the cheaper branch
on its own terms. Plumbing seats (relay / watch / hold / read) have no capability argument and belong
on Sonnet ($3/$15) — see `[[fleet-burn-budget]]`. Do not silently flip a seat's tier to save money;
name the tier and its price when dispatching.
