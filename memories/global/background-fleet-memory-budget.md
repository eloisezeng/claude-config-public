---
name: background-fleet-memory-budget
description: A background Claude fleet costs ~1 GB/session at idle and grows with CONTEXT, not session count — measure before blaming concurrency, and recover crash-killed sessions via reapedMidWorkAt
metadata:
  type: reference
scope: global
---

A `claude --bg` fleet's memory is dominated by **per-session context growth**, not by how many
sessions are running. Measured 2026-08-21 on a 48 GB Mac after VS Code died with "out of application
memory" and took seven background sessions with it.

**Idle cost, seven sessions freshly booted (~20k tokens each): 7.2 GB total.**

| component | ×8 | note |
|---|---|---|
| `bg-spare` | 4.2 GB | pre-warmed standby, ~525 MB each — the largest single lever |
| `bg-pty-host` | 2.1 GB | ~265 MB each |
| `context-mode` MCP | 0.6 GB | ~75 MB per session |
| `claude daemon run` | 0.3 GB | one, shared |

GUI apps dwarf a fresh fleet: VS Code 5.8 GB, Codex.app 2.9 GB, Claude.app 1.1 GB. **Quitting an idle
Codex.app frees more than three background sessions' baseline.**

**Growth rate, measured on the same fleet 15 minutes later:** the seven sessions went 20k → 36k
tokens doing real work and the fleet went **7.2 GB → 12.1 GB** — roughly **+700 MB per session per
15 minutes of active work**. It does not stay linear (800k tokens × that rate would exceed any Mac),
but the direction is unambiguous: a session's footprint is driven by how much work it has done, so
the fleet's memory is a function of session AGE, not session COUNT.

**The crash driver is context, not count.** The seven sessions that died were carrying 600k–840k
token conversations — multiples of their ~1 GB idle footprint. Two of them died *of* context
exhaustion in the same minute the machine ran out. So the fix is to relay at ~300–400k tokens
(`[[handoff-at-boundaries-saves-tokens]]`), not to run fewer sessions.

**Detaching does not protect the fleet.** `claude daemon run` already runs at **PPID 1** — it is not
in the terminal's or VS Code's process tree. The fleet died because macOS reclaimed memory
system-wide. Moving sessions to tmux/Terminal.app buys nothing; only lowering resident memory does.
Check this with `ps -eo pid,ppid,command` before proposing a re-parenting fix.

**Crash forensics — find what to revive.** `~/.claude/jobs/<short>/state.json` uses key `state`
(not `status`). A daemon-backed session killed mid-work carries **`reapedMidWorkAt`**, and the reaper
then marks it `failed` — so nothing auto-revives and the field is a reliable "was running at the
crash" marker. An **interactive** session has no reaper: it keeps reading `blocked` / `tempo: active`
with no process, looks alive in `/agents`, and must be marked `failed` by hand before `handoff.sh`
will dispatch over it. A stale `.dispatch` record reading `working` makes the launcher refuse;
`--force` is the documented route once you have confirmed no process exists.

**Fable turn-1 mortality is real but cheap.** Across 21 `claude-fable-5[1m]` dispatches on this
machine, 2 died on turn 1 to the `[reasoning_extraction]` model safeguard at 205 and 2,979 tokens,
before any tool call — ~10%. The rest ran fine, two past 1.3M and 1.5M tokens, so Fable does carry
the 1M window. Always verify a Fable successor cleared ~12k tokens before trusting the dispatch, and
re-dispatch casualties on `opus[1m]` — `[[handoff-successor-model-safeguard-failure]]`.
