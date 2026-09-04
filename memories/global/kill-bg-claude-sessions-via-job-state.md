---
name: kill-bg-claude-sessions-via-job-state
description: "Killing a background Claude session's PID doesn't stick — mark ~/.claude/jobs/<id>/state.json state=failed FIRST; plus two handoff.sh dispatch bugs (ANSI-polluted session_id, verification race that skips watcher arming)"
metadata: 
  node_type: memory
  type: reference
  scope: global
  originSessionId: 7cd44110-5385-49aa-ba3d-10ad28a595f6
  modified: 2026-08-20T01:14:12.591Z
---

**To permanently stop a background Claude session, set its job record to a terminal state BEFORE killing the process.**

**Why:** the Claude daemon revives every job whose `~/.claude/jobs/<id>/state.json` says `state=working` (it holds `respawnFlags` for exactly this) on every daemon restart — and restarts happen on every binary auto-upgrade, which any new session launch can trigger. Measured 2026-08-19/20: wedged session 59edc06e was `kill`ed three times and revived three times (once by `bg claimed-spare`, once by an upgrade restart triggered by dispatching a *different* session). A queued SendMessage to a dead session also resumes it from transcript.

**How to apply:**
1. `python3` edit `~/.claude/jobs/<shortid>/state.json`: set `state` to `failed` (or `done` if it genuinely finished), `tempo` to `idle`, and a `detail` explaining why.
2. **Verify the marking PERSISTED (~25s) before killing.** An ACTIVELY-WORKING seat's harness rewrites `state.json` every ~20–30s, so its own writer races your marking: measured 2026-08-25, seat `744a3bbf` was marked `failed` then killed mid-turn — its next state write restored `working`, and the daemon respawned it on a new pid within ~60s; the seat experienced the kill as a mere "restart" and kept going. Mark → confirm the marking survived → kill → confirm no respawn for ~40–60s (no new pid in `claude agents --json`, timeline quiet). A blocked/waiting seat's writer is quiescent, so the marking sticks — in a two-seat contest, retire the parked seat; a mid-turn seat may be unkillable in practice.
3. Then `kill` the session PID *and* its `--bg-pty-host` sibling.
4. Never leave a queued SendMessage targeting a session you intend to kill — it resurrects it.

**Two `~/dotfiles/claude/hooks/handoff.sh` dispatch bugs (open as of 2026-08-20, both worked around by hand-repairing the `.dispatch` record with clean appends — the record is append-only `k=v`, last-write-wins):**
- `_short_backgrounded` captures the session id WITH ANSI color codes from the launcher's colorized stdout; the polluted `session_id` makes the watcher's `claude agents` lookup miss forever. Repair: append a clean `session_id=<shortid>` and `session_uuid=<full-uuid>` (the uuid is only written by the verification step, and the transcript probe needs it).
- Post-launch verification races `claude agents --json` registration; on loss the dispatch exits `state=unknown` BEFORE the auto-arm line, so no stall-watchdog is armed. Repair: append `watch_gen=<token of [0-9A-Za-z._-]>` then `nohup handoff.sh --watch <record> --watch-gen <token> --heartbeat-min 20 --poll-sec 60 &`; proof of arming is the watcher clearing/holding markers on its next poll, not the fork returning.

Related: [[worker-liveness-must-reflect-progress]], [[handoff-at-boundaries-saves-tokens]].

**And the converse does NOT hold: marking `state.json` `failed` does not stop a live seat.**
Measured 2026-09-04 on job `ef6bc042`, 1 minute after dispatch. Its record carried `pid: null` —
the daemon owns the process, not the record — so flipping `state` to `failed` and writing a
`retired-by-decision` detail changed nothing: `claude agents --json` still read `working` 25 s
later. The state edit is the half that makes a kill STICK; it is not itself a kill, and with no
pid in the record there is nothing to kill from it.

The hazard this creates is worse than the failed attempt. A live seat left marked
`failed / retired-by-decision` reads as a corpse that must never be revived, so a later revival
wave will refuse to wake a perfectly healthy session — and `retired-by-decision` is the one detail
that is never revivable. If a stop attempt does not take, **restore the record to the truth**
before moving on.

Corollary for tier: a bg seat exports `CLAUDE_HANDOFF_MODEL`, so every seat it dispatches inherits
the parent's tier and beats `handoff.sh`'s Fable default. Fix that by passing
`--model 'claude-fable-5[1m]'` AT DISPATCH TIME. After the fact there is no cheap correction —
re-dispatching means killing a seat you cannot reach through its own record.
