# Auto-handoff: spawn a fresh successor session instead of an in-session subagent

## Problem

The context-watchdog's URGENT band (≥150K) tells the model to hand remaining work to
"a general-purpose background Agent … or a new session".
Both halves of that instruction are wrong in a measurable way.

An in-session subagent does not shed the spent window.
The parent stays alive around it, so the ~160K window is cache-read on every subsequent turn,
including the turn where the subagent reports back.
Measured this session: a fresh subagent boots at 32–37K, a fork at 217K, an interactive session at 60.3K.
The subagent's own window is cheap; the corpse it leaves loaded is not.

"A new session" is cheaper — it abandons the spent window entirely — but it requires the user to be
present to start it, which is exactly what is not true at the moment URGENT fires in an unattended run.

`claude --bg` resolves the contradiction, and is verified working on this machine (2026-08-18):

| Probe | Result |
| --- | --- |
| First-turn window of a `--bg` session | **61,702 tokens** (vs 60,327 for this interactive session) |
| SessionStart hooks | fired — 4 `hook_success` attachments, global memory + superpowers injected |
| Auth, detached | works; probe returned `PROBE-OK` and exited `done` |
| `claude agents --json` | scriptable, no TTY, reports per-session `state` |

## The failure this must not reproduce

`claude agents --json` shows four historical background sessions still in state `blocked`:

```
427cab5f  blocked  2026-06-19T16:32  ""
32bbc7d4  blocked  2026-06-19T17:37  "incorporate feedback spec"
84ab99db  blocked  2026-06-19T21:18  "verify dashboard todo spec"
b3b91c6f  blocked  2026-08-07T19:17  "Rewrite typein payload handoff"
```

A `--bg` session that hits something it cannot answer blocks **silently and forever**.
One has been stuck since June; the August one is itself a handoff that never ran.
Fire-and-forget dispatch is therefore not acceptable: an unwatched successor is indistinguishable
from a successor that finished.
This is `worker-liveness-must-reflect-progress` — the health signal must reflect forward progress,
not process-alive — and `verify-claims-against-artifacts`: the dispatch is proven by the session
appearing in `claude agents --json`, never by the launcher's own stdout.

## Scope

1. `hooks/handoff.sh` — dispatch a successor from a handoff file, with liveness watch and notification.
2. `hooks/context-watchdog.mjs` — URGENT (and WARN) bands name the script instead of prescribing a subagent.
3. `tests/handoff.test.sh` and `tests/context-watchdog.test.sh` — plain-bash tests in the existing idiom, no real sessions spawned.
4. Pre-existing, unrelated: `tests/settings-portable-paths.test.sh` fails at BASE
   (`d88adc66`) on the symlinked-`$HOME` case. Fixed as its own task, its own commit.

Out of scope: retiring the four already-blocked sessions (the user's call — they may hold state);
anything in `your-other-project`.

## What is machine-enforced, and what is only advice

These are not the same thing, and the difference is the whole safety story.

**Enforced by the launcher** (a test fails if it stops holding):
atomic single-ownership per handoff file; absolute-path resolution of the handoff file;
dispatch identity (the session exists, is `kind=background`, and runs in the requested cwd);
fail-closed interpretation of every agent-list read; alert-once bookkeeping; a watchdog whose
arming is confirmed by its lease being HELD, not by having forked and not by a PID.

**Advisory only** — prose in the successor's system prompt, which a same-user session can ignore:
"merge only when every required gate passes", "check `scripts/deploy-freeze.sh`", "do not spend beyond an approved
envelope", "write progress into the handoff file". A successor is the user, with the user's
credentials; nothing in this launcher can stop it. They are stated because a stated constraint is
usually honoured, and they are labelled advisory here so nobody builds on them as if they were
guardrails.

## Contract

```
handoff.sh <handoff-file> <objective> [options]
handoff.sh --status
handoff.sh --watch <record>        # poll loop, armed automatically by dispatch
handoff.sh --watch-once <record>   # one evaluation
```

| Option | Default | Meaning |
| --- | --- | --- |
| `--cwd DIR` | `$PWD` | working directory for the successor; verified against the agent row |
| `--model M` | inherit | passed through to `claude --bg` |
| `--permission-mode MODE` | inherit | passed through |
| `--heartbeat-min N` (`--stall-min`) | 20 | minutes without an artifact write before a no-heartbeat alert |
| `--poll-sec N` | 60 | watchdog poll interval |
| `--no-watch` | off | dispatch without arming the watchdog |
| `--force` | off | dispatch even though a record names a live or unverified successor |
| `--dry-run` | off | print the command and exit without spawning or locking |

`--status` lists background sessions with state and age, flagging `blocked`. It is the answer to
"did my successor actually get anywhere".

### The record

`<handoff-file>.dispatch`, `key=value` lines, appended (last wins). `state` is the ownership field:

| `state` | Meaning | Effect on a later dispatch |
| --- | --- | --- |
| `launching` | the record is claimed and `claude --bg` may already have run; nothing has named a session | refused until `--force` |
| `prelaunch_failed` | a fence refused *before* the launcher was ever run | none — a plain retry is safe |
| `pending` | spawned and named, not yet confirmed | — (transient, within one run) |
| `verified` | confirmed present in `claude agents --json`, right kind and cwd | refused while the session is live |
| `unknown` | launched, but the confirmation failed or contradicted the request | refused until `--force` |
| `failed` | the launcher exited without naming a session **and** the registry was read and lists nothing backgrounded here | none — a plain retry is safe |
| *anything else* | not a value this launcher writes: a hand-edit, a half-written line, or a newer launcher's vocabulary | refused until `--force` |

`unknown` is the important one: a launcher that exits without a record after a successful spawn
invites the retry that starts a *second* successor on the same runbook.

`prelaunch_failed` and `failed` are the same rule seen from the other side. A refusal that launched
nothing must not cost the operator a `--force` — but it may only say so on evidence: because nothing
was run at all (`prelaunch_failed`), or because the registry was actually READ and shows nothing
backgrounded in this directory (`failed`). Neither may be reused for the other, and neither may
stand in for `launching`, which means "a successor may exist that no id names" (round-5
correctness #4: every pre-launch fence promised a retry that the duplicate-dispatch guard then
refused, because they all left `launching` behind).

The table is **closed**, and that is a property of the code, not of this page: the guard is a `case`
over the six values with a refusing default, so a state it does not recognise cannot rule out a live
successor and is refused like `unknown`. The shape is the point. Written as
`if [ "$st" = unknown ] || [ "$st" = launching ]`, every retryable state was retryable by falling off
the end of the `if`: naming `prelaunch_failed` there was decoration, deleting it changed nothing
observable, and the test written to pin it passed on the mutant. A truncated `launchin` — a successor
that may exist, spelled one byte short — read as permission to start a second one (case CY).

### Dispatch sequence

1. **Validate.** Handoff file exists, is readable, non-empty; objective non-empty; cwd resolvable.
   The handoff path is resolved to absolute — the successor resolves it in its own cwd, so a
   relative path is a silent wrong-file read.
2. **Claim the lock.** `flock(2)` on **`<record>.flock`** — that suffix, and no other — held
   across read-record → query → spawn → verify → record. Without it two callers both read "no live
   successor" and both spawn: the check and the act have to be one step
   (`shared-runbooks-reclaim-ownership-at-fire-time`).
   Ownership belongs to the KERNEL: the lock lives on the open file description, the kernel releases
   it when the last descriptor referring to that description closes — including when the holder is
   SIGKILLed — and acquisition is atomic against every other acquirer. So there is no owner field,
   no fencing token, no corpse, no age and no grace, and no reclaim path that can be got wrong.
   See **P4** for why the two home-made primitives that preceded it were deleted rather than patched
   a third time. The lock FILE is created once and never unlinked — unlinking it would put two locks
   on two inodes at one path — and its single line is a diagnostic nobody reads for a decision.

   **`<record>.lock` is the LEGACY path and must never be used to coordinate with dispatch.** It is
   the mkdir-shaped claim P4 replaced. Nothing sweeps it: a directory there is REPORTED and the
   dispatch REFUSES, printing the exact `rm -rf` for the operator to run once they have confirmed no
   pre-upgrade launcher holds it. Removing it automatically would be deciding, on no evidence, that
   nobody does — and if somebody does, both dispatches launch and the handoff is paid for twice
   (round-5 lifecycle #2). An unreadable answer about it refuses too: "the filesystem did not say"
   is not "no legacy claim is here".
   Anything holding `<record>.lock` therefore contends with nobody: the launcher never opens it, so
   an operator or wrapper coordinating through it and the launcher would each believe they own the
   handoff and each start a successor. This document said `<record>.lock` for three rounds, and
   described a sweep for two more after the code stopped having one; the code has taken `.flock` and
   removed nothing since P4 (round-5 lifecycle #3).

   An operator who genuinely needs to coordinate takes **the same lock the launcher takes**, held
   across their whole check-and-act — `flock(2)` on `<record>.flock`, e.g. `perl -e 'open(F,">>",
   $ARGV[0]) or die; flock(F, 2) or die; system(@ARGV[1..$#ARGV])' "$REC.flock" <cmd> [args…]`
   (`flock(1)` does not exist on macOS — see P4). The command is passed as a LIST, so its arguments
   arrive as written and no shell re-splits them — case CK runs the recipe WITH arguments for that
   reason, because a recipe invoked with a bare command word cannot tell a list from a scalar.
   Because ownership belongs to the kernel, that is symmetric with the launcher's claim by
   construction; there is no second mechanism to keep in step.
3. **Refuse a double dispatch** unless `--force`: a record whose `state` is `unknown` or `launching`,
   a record whose `state` is not one of the six this launcher writes, or one whose session is still
   live. If the agent list cannot be read at all, refuse — an unreadable list is not evidence of
   absence.
4. **Spawn** `claude --bg` from the resolved cwd, with the successor charter appended to its system
   prompt.
5. **Record `state=pending`** as soon as a session id parses out of stdout — *before* verifying.
6. **Verify against the artifact.** The id must appear in `claude agents --json`, with
   `kind=background` and the requested `cwd`. An id-only check would pass for an interactive session
   or one running in the wrong repository. Any failure sets `state=unknown`, notifies, and exits
   non-zero. A launcher that reports success from its own echo is the status-flag mistake this
   repo's rules exist to prevent.
7. **Arm the watchdog** unless `--no-watch`, then prove it is watching by observing that the
   generation's LEASE is held. That is a question about a live process answered by the kernel, not a
   `kill -0` on a recorded PID that may since have been recycled. If the lease is not held, record
   `watch_failed` and say so: "dispatched" and "watched" are separate claims.

### Successor charter (appended system prompt)

Advisory, per the section above — the launcher enforces none of it.

This block is reproduced VERBATIM from `hooks/handoff.sh`, and case CHARTER asserts both
directions, so a bullet that exists here and not there is a failing test rather than a
quiet fiction.
Documentation of a prompt no session was ever given is worse than no documentation.

<!-- CHARTER-BLOCK-BEGIN -->
```
You are an unattended successor session dispatched from a handoff file.
- Merge when every required gate below passes, and do not wait for permission to do it. A green merge is EXPECTED to trigger the normal production deploy; that is not a reason to hold one.
- The gates are ALL of: every required CI and review check green on the exact head you are merging; the head you merge is the head that was reviewed; no merge conflict; no deploy or box-side work already in flight; and the deploy freeze CLEAR.
- Read the freeze with scripts/deploy-freeze.sh status where it exists. CLEAR passes. FROZEN and UNKNOWN both FAIL, and UNKNOWN means the signal could not be read, never that no freeze is set. Where no such script exists the gate is UNESTABLISHED, which is also not a pass: say so and establish the deploy state another way before merging.
- After merging, watch the deploy pinned by YOUR merge SHA and confirm the deployed artifact carries the change; a green tick is not a deployment.
- Do not spend money or credits beyond an envelope the handoff file records as already approved.
- Write progress into the handoff file as you go, so a stall is legible from the artifact.
- Stop and report rather than improvising past the objective.
```
<!-- CHARTER-BLOCK-END -->

The merge bullet is a GATE LIST, not a prohibition, and that is a deliberate reversal.
It used to read "do not merge to `main`", which contradicted the standing directive to merge whenever merging is mechanically safe.
On 2026-08-26 seat `4b5fd6f9` had to violate this charter to do the correct thing: PR #310 was 17/17 green with the freeze clear, it merged, and deploy `32925151388` succeeded.
A charter that the correct action must break is a defect in the charter, so every gate survives — stated so it can be checked rather than felt.

### Watchdog — a total disposition table

Polls every 60s (`--poll-sec`) up to `MAX_HOURS` (12, `CLAUDE_HANDOFF_MAX_HOURS`). Every alert
fires at most once **per episode**, tracked by an `alerted_*` line in the record: the marker is
written only after delivery succeeds, and it is cleared when the condition it describes is observed
GONE, so a condition that recurs is announced again. Delivery is retried up to
`ALERT_RETRY_MAX` (10) **attempts** — attempts, not polls, because the retry has to survive a
degraded `claude agents --json` that never reaches the alert at all.

Two of those keys name a STAND-DOWN rather than a condition — `expired_<scope>` and
`clocklost_<scope>` — and a stand-down has no recovery transition inside one watcher's life to clear
a marker with, so they are scoped to the WATCHER instead: `<scope>` is the generation when there is
one, and the watcher's pid otherwise. The pid half is load-bearing, not a fallback for tidiness:
`handoff.sh --watch <record>` without `--watch-gen` is a documented mode and the one an operator
re-arming by hand actually runs, and with a flat key the first bare watchdog to lose the clock
silenced every later one on that record. `finished` stays flat on purpose — it names a TERMINAL fact
about the successor, so a second watcher re-announcing it is noise rather than a lost warning.

| Observation | Disposition | Alert |
| --- | --- | --- |
| `agents --json` errors, is empty, or is not a JSON array | **not terminal.** Ownership retained, exit 3 | "monitoring is DEGRADED" |
| valid list, id absent | terminal | "finished (gone)" |
| valid list, state in `done complete completed stopped failed error` | terminal | "finished (\<state\>)" |
| state `blocked` | live | "blocked and needs input" |
| state in `running busy working active starting queued` | live | heartbeat check below |
| **any other state** | live — never terminal | "unknown state '\<state\>' — not treated as finished" |
| no transcript file past a 5-minute grace | live | "no transcript — monitoring is DEGRADED" |
| newest of transcript/handoff mtime older than `--heartbeat-min` | live | "no heartbeat for Nm" |
| 12h lifetime reached while non-terminal | records `monitoring_expired` | "EXPIRED … nobody is watching it now" |
| the presence probe did not RUN — including a `session_uuid` the record would not give up | **not terminal.** Ownership retained, exit 3 | "cannot tell whether … is still in the agent list — DEGRADED" |
| the projects directory cannot be ENUMERATED (a permission error, not ENOENT) | **not** "no transcript". Exit 3 | "cannot read the filesystem to locate … transcript — DEGRADED" |
| neither heartbeat source could be observed — including a `handoff` key the record would not give up | live, exit 3 | "cannot stat … transcript or handoff file — DEGRADED" |

Only a **positive** observation releases ownership. The states above are the ones seen on this
machine; the enum is not documented and not closed, which is why the table is total and the
unknown row exists.

The heartbeat is deliberately named for what it is. Transcript mtime is a **weak** signal: a long
silent tool call looks identical to a wedge (false alarm), and an agent looping without progress
keeps it fresh forever (false calm). It is paired with the handoff file's own mtime — the artifact
the charter asks the successor to update — and the alert says "no heartbeat", not "stalled".
Only a `blocked` state observation actually establishes that the successor is stuck.

The transcript is located by globbing `$CLAUDE_PROJECTS_DIR/*/<session-uuid>.jsonl` rather than
recomputing the cwd-slug directory name, so a change to the slugging rule cannot silently point the
watchdog at nothing; a missing transcript is reported, never read as staleness.

An unmatched glob is only an OBSERVATION if the search happened, so the lookup asks `opendir` for the
projects directory afterwards and separates ENOENT (a real absence) from every other errno (a look
that was refused). A projects directory the watchdog may not enumerate is reported as DEGRADED and
never as "this successor has written no transcript". One blind spot is recorded rather than dressed
up: an individual project SUBdirectory that cannot be searched is still invisible, because probing
each one would cost a probe per directory on every poll and would raise spurious DEGRADED alerts on
a large `~/.claude/projects`.

## Retiring the predecessor seat

A verified dispatch used to leave the seat that made it alive and idle.
`dispatch()` ended at `state verified`, armed the watchdog, printed its report and returned to the turn loop, so the predecessor sat in `claude agents` as *awaiting input* indefinitely and its `state.json` kept `firstTerminalAt: null` forever.
Two sessions were then nominally on one piece of work and only one of them knew it.

Retirement closes that: once a dispatch is **verified**, the dispatching seat marks itself terminal and stops its own process.

**The kill is the durable half.**
The agents daemon re-derives a session's `state` by scanning its transcript, so a `state.json` edited without stopping the process is reverted on the next wake — a marker alone retires nothing.
The marker is what makes the kill legible: without it the seat reads as a crash rather than as a finished handoff.

### The subject is derived from this seat, never read from the record

The dispatch record's `session_id` names the **successor**.
A retirement that took its subject from there would kill the session it had just started.
The subject is derived instead from the predecessor's own environment, and five conditions must hold before anything is written.
Every one of them is a REFUSAL that is printed and recorded, never a silent skip:

| Condition | `retire_state` |
| --- | --- |
| `basename($CLAUDE_JOB_DIR)` is the successor's short id | `refused_is_successor` |
| `basename($CLAUDE_JOB_DIR)` does not match `$CLAUDE_CODE_SESSION_ID` | `refused_jobdir_not_ours` |
| that job's `state.json` records some other session | `refused_state_mismatch` |
| `$CLAUDE_PID` is unset or not a pid | `refused_no_pid` |
| `$CLAUDE_PID` is not a live `claude` **ancestor** of this shell | `refused_not_ancestor` |

The first row is the tripwire, and it is the reason the other four exist.
It asserts that the two ids never collapsed — the control that a watcher's subject cannot move out from under it.

### Two halves, because only one of them is reversible

| Phase | Runs in | Does |
| --- | --- | --- |
| `retire_self` | the dispatching process | writes the `<session-id>.handed-off` sentinel, then renames a rewritten `state.json` over the original, keeping `state.json.pre-retire` as the rollback copy; records `retired_predecessor` and `retire_state=retire_pending`; spawns the detached second half with fds 9/8/7 closed so the per-handoff lock is not inherited |
| `retire_exec` | its own process | **re-verifies at act time**: if `claude agents --json` cannot be read, or the successor is no longer listed, or it is already terminal, it rolls the state file back, removes the sentinel, records `retire_aborted` and alerts — the seat stays alive so the work is not orphaned. Otherwise SIGTERM, `CLAUDE_HANDOFF_RETIRE_GRACE` seconds (default 10), then SIGKILL, and records `retired` |

The sentinel is written **first**, before the state file and long before the signal.
`hooks/context-watchdog.mjs` reads it and emits no handoff instruction for a session that has already dispatched one, so a seat cannot be told to hand off again by the very tool calls its own retirement provokes.
`handoff.sh` refuses a second dispatch from a session that holds a sentinel for the same reason, with `--force` as the override.
Both read `CLAUDE_HANDOFF_STATE_DIR`, then `CLAUDE_CONFIG_DIR`, in that order, so the writer and the guard cannot end up looking at different directories.

**Residual, not closed.**
The successor can still die in the window between `retire_exec`'s re-check and the signal.
Closing that needs a fence held across the whole critical section, which is not built; the watchdog armed for the successor is what covers it, because it alerts on a successor that stops.

### Opting out, and the seat that has nothing to retire

`--no-retire` disarms it for one call and `CLAUDE_HANDOFF_RETIRE=0` disarms it for a whole fleet, mirroring `CLAUDE_HANDOFF_ARM`.
It is a modifier and not a command, so it is appended to an ordinary dispatch — `handoff.sh <handoff-file> <objective> --no-retire` — and is refused by the option parser when given on its own.
A session with no `CLAUDE_JOB_DIR` is not a background seat and is skipped cleanly rather than refused.
The dispatch report carries the outcome on its own line, because "dispatched" and "retired" are separate claims exactly as "dispatched" and "watched" already are:

```
  retired : pending (state=done, sentinel written; stopping pid 41234)
```

**Retirement never fires on a dispatch that did not verify.**
It is called once, past `state verified`, after the report is printed — so the predecessor's transcript records the dispatch before the seat stops.

## Design for test

No test spawns a real session. The CLI and the paths are injected:

| Variable | Purpose |
| --- | --- |
| `CLAUDE_BIN` | the binary called for both `--bg` and `agents --json` |
| `CLAUDE_PROJECTS_DIR` | where transcripts are globbed from |
| `CLAUDE_HANDOFF_LOG` | the event log appended to |
| `CLAUDE_HANDOFF_NOTIFY_DEBUG` | print `NOTIFY: …` instead of ringing (mirrors `CLAUDE_NOTIF_DEBUG`) |
| `CLAUDE_HANDOFF_ARM` | `0` disarms the poll loop so tests leave no background processes |
| `CLAUDE_HANDOFF_MAX_HOURS` | `0` makes the expiry path reachable in a test |
| `CLAUDE_HANDOFF_STATE_DIR` | where the `.handed-off` sentinel is written and read |
| `CLAUDE_HANDOFF_RETIRE` | `0` disarms predecessor retirement |
| `CLAUDE_HANDOFF_RETIRE_GRACE` | seconds between SIGTERM and SIGKILL on the seat being retired |

The record lives beside the handoff file rather than in a state directory, so it is discoverable by
whoever finds the handoff.

Tests provide a shim `claude` whose canned output — and canned *failures* — make every row of the
disposition table reachable: blocked, unknown state, missing transcript, agent-query error,
malformed JSON, wrong cwd, a stale lock, two concurrent callers, and watchdog expiry.

## Acceptance

1. Dispatch writes a record and reports the session id, verified against `agents --json`.
2. A shim whose `agents --json` omits the id fails the dispatch loudly, **records `state=unknown`**,
   and that record blocks an unforced retry.
3. A second dispatch against a live record is refused; `--force` overrides; an unreadable agent list
   is also a refusal, not a green light.
4. Missing file, empty file, and missing objective each fail with a distinct message.
5. `--dry-run` prints the command and spawns nothing.
6. Exactly one alert each for blocked, no-heartbeat, unknown state, missing transcript, and
   completion — and none while the session is healthy.
7. A failed or malformed `agents --json` read is DEGRADED, never completion (exit 3).
8. Two concurrent dispatches against one handoff produce exactly one spawn.
9. A row with the wrong `cwd` or a non-background `kind` fails the dispatch.
10. A dead holder's lock is released BY THE KERNEL the moment its last descriptor closes — including
    on SIGKILL — and the lock FILE stays where it is. The next dispatch acquires that same file with
    no reaping, no age check and no unlinking. (This item used to read "a lock left by a dead process
    is broken rather than fatal", which described P1's `ln`-based claim and is the OPPOSITE of what P4
    does; left standing it invites an operator to delete lock files, which is exactly how two holders
    end up on two inodes at one pathname — round-4 correctness C12.)
11. Watchdog expiry records `monitoring_expired` and alerts.
12. `--status` flags blocked sessions.
13. The URGENT band of `context-watchdog.mjs` names `handoff.sh` with its exact invocation, still
    forbids forks, still carries the recurring-loop exception, and still says never to block on
    The user — pinned by `tests/context-watchdog.test.sh` driving the hook's real stdin/stdout.
14. `tests/settings-portable-paths.test.sh` passes.
15. Both watchdog bands are pinned at their exact edges — 119,999 silent, 120,000 warn, 149,999
    warn, 150,000 urgent — for `UserPromptSubmit` and `PostToolUse` alike, and each band's assertion
    quotes the launcher invocation in full rather than the substring `handoff.sh`.
16. The real `install.sh` runs end-to-end against a throwaway `$HOME` and persists a portable hook
    naming no machine-specific path, from the canonical repo location and from a non-canonical one.
17. Running `install.sh` twice succeeds. (It did not: the first run creates `~/.claude1/projects/…`
    while restoring memories, and the preflight then failed on that dir's absent `settings.json`.)
18. A handoff reached through a symlink and a handoff reached by its real name are ONE ownership
    claim: one record, one lock, one successor (case BN).
19. A handoff removed, emptied or replaced between validation and launch spawns NOTHING and leaves
    the record at `launching`, and the identical untouched dispatch still spawns exactly one — the
    anchor that keeps the guard from passing by refusing everything (case BO).
20. A record value that looks like a node option (`--require=…`) is data, never an option: nothing is
    preloaded, and the lookup it feeds still answers (case BP).
21. Alert markers are episode-scoped, not record-scoped — blocked → running → blocked alerts twice,
    and a second watchdog generation that expires alerts again (case BQ).
22. Generated Linux service files survive a repo path containing a space, `%`, `&` or `<`, per
    grammar: plist XML text, a systemd `ExecStart` word, and a systemd bare path value.
23. An install whose MIRROR aliases the PRIMARY (or either aliases the repo) is refused before the
    first link is written, and an out-of-`$HOME` install refuses to persist an absolute hook path
    into shared settings unless `ALLOW_ABSOLUTE_HOOK_PATH=1`.
24. The successor charter states a GATED always-merge rule and contains no prohibition-shaped merge
    or push instruction, and the charter in `hooks/handoff.sh` and the charter in this document are
    byte-identical in both directions (cases CHARTER-1/2/3).
25. A verified dispatch leaves the DISPATCHING seat terminal — `state=done`, `tempo=idle`, a `detail`
    naming the successor, an ISO `firstTerminalAt` — and its process stopped, while the SUCCESSOR's
    own `state.json` is byte-for-byte unchanged (cases RETIRE-1/2).
26. Retirement refuses, records why, and stops nothing when the seat's job id is the successor's, when
    `CLAUDE_JOB_DIR` names another session, when `state.json` records another session, when
    `CLAUDE_PID` is not a pid, and when that pid is not a live `claude` ancestor of the dispatching
    shell (cases RETIRE-3/3B/3C/3D).
27. An unverified dispatch retires nothing; `--no-retire` and `CLAUDE_HANDOFF_RETIRE=0` both skip; a
    retired seat may not dispatch a second successor; the detached killer holds no dispatch lock; and
    a successor that dies between verification and the signal rolls the state file back, removes the
    sentinel and leaves the predecessor alive (cases RETIRE-4/5/6/7/9).

## Review dispositions — Codex spec round 1 (`-p terrax`, 2026-08-17)

Ten findings, one critical. All fixed; none deferred.

| # | Sev | Finding | Disposition |
| --- | --- | --- | --- |
| 1 | critical | double-dispatch check is not an atomic ownership claim | **fixed** — `mkdir` lock held across check→spawn→verify→record; test O runs two concurrent callers and asserts exactly one spawn |
| 2 | high | an unobserved state has no safe disposition | **fixed** — total disposition table; unknown states stay live and alert; test I |
| 3 | high | failed post-spawn verification orphans a successor | **fixed** — `state=pending` written before verification, `state=unknown` on failure, which blocks an unforced retry; test B |
| 4 | high | "absent" treated as completion when the observation itself failed | **fixed** — `read_agents` separates command failure / empty / non-array from a valid empty list; exit 3 + DEGRADED alert; tests L, M |
| 5 | high | transcript mtime is a weak signal, path derivation unspecified | **fixed** — renamed "no heartbeat", paired with the handoff file's mtime, missing transcript reported on its own, path derivation documented; test N |
| 6 | high | watchdog has no lifecycle guarantee and expires silently | **fixed** — arming confirmed with `kill -0` (`watch_failed` otherwise), expiry records `monitoring_expired` and alerts as action-required; tests K, R |
| 7 | high | the URGENT rewire is an instruction, not a mechanism | **fixed as far as the interface allows** — the band now names the exact invocation and demands the printed record path be reported; `tests/context-watchdog.test.sh` pins it. The residual is real and is now stated in the hook's own header: a `UserPromptSubmit`/`PostToolUse` hook cannot dispatch, because only the model can author the handoff file's contents. The band is advisory by construction. |
| 8 | medium | verification does not prove cwd or that the row is a background session | **fixed** — `kind` and `cwd` are checked against the request; test P. `--model` / `--permission-mode` / `--append-system-prompt` confirmed present in `claude --help` before use |
| 9 | medium | the charter describes constraints a same-user prompt cannot enforce | **fixed** — split into "machine-enforced" and "advisory" above, and labelled in the script |
| 10 | medium | the test design omits the failure modes that make liveness claims unsafe | **fixed** — cases L–R added for query failure, malformed JSON, missing transcript, concurrency, wrong cwd, stale lock, and expiry |

## Review dispositions — Codex diff round 1 (three parallel lenses, `-p terrax`, 2026-08-17)

Scope-checked: all three verdicts echoed `base d88adc66`, `head 75d6072`, and a `files` manifest matching `git diff --name-only` exactly.
18 findings — 1 critical, 9 high, 7 medium, 1 low — of which C1 and L1 are the same defect seen from two angles, so 17 are distinct.
Every one was verified before being acted on: two by direct reproduction, the six test-lens findings by the reviewer's own surviving mutation.
All fixed; none deferred.

### Correctness lens

| # | Sev | Finding | Disposition |
| --- | --- | --- | --- |
| C1 | high | stale-lock recovery lets two callers claim one handoff | **fixed** — see L1; the same defect. |
| C2 | high | a newline in the objective forges record fields | **fixed** — `rec_ok_value` rejects any value containing CR or LF, logs `HandoffRecordRejected`, and the write fails closed; a multi-line objective is refused (test V). |
| C3 | high | an omitted objective makes `--dry-run` the objective and dispatches for real | **fixed** — an objective starting with `-` is refused by name, with `--` offered as the escape for a legitimately dash-leading objective (test T). |
| C4 | medium | a value-taking option with no value spins forever | **fixed** — `need_val` checks the remaining argument count on every value-taking option, in both dispatch and `--watch` parsing; reproduced first (the old code hung), now exits non-zero (test U). |
| C5 | medium | record-write failures still end in a "watched" dispatch | **fixed** — the record is created before the spawn and every subsequent `rec_put` is checked; a failure to record a launched successor is fatal and says so (test W). |
| C6 | medium | raw `$HOME` prefix matching calls a symlinked-outside repo portable | **fixed** — `portable_hook_cmd` resolves both sides physically *before* any prefix decision; the early literal `return` could never be corrected later. Pinned by the `$HOME/shortcut`-out-of-home case, mutation-verified. |

### Lifecycle / liveness lens

| # | Sev | Finding | Disposition |
| --- | --- | --- | --- |
| L1 | critical | concurrent stale-lock recovery deletes a freshly acquired lock | **fixed** — fencing tokens. `mkdir` is an atomic claim but *breaking* a stale one is not, so breaking now happens under a serialising `<lock>.reclaim` claim, the owner is re-read inside that claim, the new pid is written before the old lock is released, and the token is re-checked immediately before the spawn and before each record commit. `release_lock` removes a lock only while it still carries our token. |
| L2 | high | a lock is stolen after ten minutes even while its owner is alive | **fixed** — age is no longer a reason to take a lock. `LOCK_STALE_SEC` is gone; a live owner is never overrun at any age, and `LOCK_PID_GRACE` covers only the instant between `mkdir` and the pid file being written (test S, which holds the lock with a real running process and an ancient directory mtime). |
| L3 | high | a kill between `claude --bg` and the record write loses the successor | **fixed** — a durable `state=launching` intent is written *before* the spawn, so an interrupted dispatch is recoverable rather than invisible; an unforced retry refuses and `--force` overrides (test X). |
| L4 | high | a live successor can permanently lose its watchdog | **fixed** — `reconcile_watch` re-arms monitoring for any recorded successor whose `watch_pid` is gone, records `watch_reattached`, and says so on stderr and by notification (test Y). |
| L5 | high | a hung `agents --json` freezes the watchdog with no degraded alert | **fixed** — `timed_to_file` bounds the query (default 45 s) and a timeout is DEGRADED, exit 3. The deadline captures stdout to a *file*, not a pipe: a command substitution does not return until every process holding the pipe closes it, so killing a wrapper's direct child still blocks for as long as a grandchild lives, and the timeout would have been silently ineffective — which is how the first attempt at this fix failed its own test (test Z). |
| L6 | high | alert-once markers both suppress and duplicate alerts | **fixed** — the marker is written only *after* delivery succeeds, under a per-alert claim directory carrying the claimant's pid; a failed delivery leaves no marker and is retried (test AA). The watch loop now terminates on the durable `finished` fact rather than on the alert marker, so a delivery failure cannot make the watchdog immortal. |

### Test-quality lens

Each of these was accepted only because the reviewer supplied a mutation that survived the suite.

| # | Sev | Finding | Disposition |
| --- | --- | --- | --- |
| T1 | high | the launcher-path assertions accept a broken invocation | **fixed** — cases A, B, D and D2 assert the complete invocation, JSON-decoded, for both events and both bands. Mutation-verified: renaming the path to `wrong-handoff.sh` in any of the four templates is killed by the case that owns it. |
| T2 | high | the shim never verifies the successor's real working directory | **fixed** — the shim records `pwd` at launch and case A compares it physically against the requested `--cwd`. |
| T3 | medium | threshold inclusivity is untested | **fixed** — case G crosses both edges for both events (119,999 / 120,000 / 149,999 / 150,000). Mutation-verified: `>=`→`>` at either threshold, and a 1,000-token nudge of either constant, are each killed. Distinguishing the bands by wording rather than by the reported `~120K` matters — the number is rounded and reads the same on both sides of the edge. |
| T4 | medium | heartbeat coverage never crosses the configured timeout | **fixed** — case G of the handoff suite now ages artifacts by offsets straddling the configured boundary (19 min silent, 21 min alerts once at `--heartbeat-min 20`) instead of a fixed calendar date, which also removes a fixture that would have expired. |
| T5 | medium | portable-path coverage stops before the installer integration point | **fixed** — the real `install.sh` now runs twice against a throwaway `$HOME`, from the canonical and a non-canonical repo location, asserting the persisted hook is the portable form, unique, free of machine-specific paths, and unchanged by the second run. This is what found the non-idempotent preflight (acceptance 17): the unit tests supplied the hook command themselves and so could never see the wiring. |
| T6 | low | requested model forwarding is untested | **fixed** — case AB asserts `--model` and `--permission-mode` reach `claude` as exact ordered pairs. |

## Review dispositions — Codex diff round 2 (three parallel lenses, `-p terrax`)

BASE `d88adc6692db23c460318bc501e831a6d877de61` → HEAD `c9432e30300b348aadc6a1fc779035d0bac88b85`.
Scope check PASSED on all three lenses: `reviewed.base`/`reviewed.head` exact, no duplicate file entries, and the correctness and test lenses each read all 8 files in the round manifest.
The lifecycle lens read 3 files (`hooks/handoff.sh`, `docs/handoff-successor.md`, `tests/handoff.test.sh`), which is where lifecycle lives; round-level manifest coverage is satisfied by the other two lenses.
19 findings: 1 critical, 10 high, 8 medium, 0 low.
Round 1 was 18 (1/9/7/1), so **the finding rate is flat**, and that changed the response from "patch the instances" to "rewrite the region" — see the decision below.

### The decision: rewrite the ownership/watcher/alert region, do not patch it again

Eleven of the nineteen findings trace to three home-made primitives, and patching instances has already been tried and failed once.
Round 1's headline fix was a fencing-token lock; round 2's critical finding is *still* the lock, because the token is published in a second step after the claim already exists.
L3 and L5 are one root cause stated twice: a bare PID is used as an identity, and a PID is not an identity.
L4 and L6 are also one root cause stated twice: alert delivery markers are neither durable nor transactional.
So the fix is three correct primitives, each of which is SMALLER than the code it replaces:

- **P1 — `claim`: atomic ownership whose payload exists before the claim does.**
  `mkdir` is an atomic claim but says nothing about the owner, so the owner's pid must be written afterwards, and that gap is the bug.
  Instead, stage a file containing `pid<TAB>token<TAB>epoch` and `ln` it into place: `link(2)` fails EEXIST atomically, so the lock, from the instant it is observable, already names its owner.
  This deletes `LOCK_PID_GRACE`, the entire pid-less branch of `lock_holder_reason`, and the `.reclaim` sub-lock — about 35 lines for about 12.
  Breaking a dead owner's lock uses `mv` (not `rm -f`) so the removal is itself conditional: the loser gets ENOENT and re-evaluates instead of deleting the winner's lock.
  The round-1 rule survives unchanged: a live owner is never overrun at any age, and the fencing token is re-verified before every irreversible step.
- **P2 — a watcher LEASE, not a watcher PID.**
  The record carries `watch_gen`, written BEFORE the fork so a launcher killed mid-arm still names the generation it started, and the watcher renews a generation-keyed beat file.
  "Is it watched" becomes "is the recorded generation's lease fresh", never "does that PID exist".
- **P3 — a durable alert log with an explicit at-least-once contract.**
  Every alert, including the rearm notice, goes through `alert_once` with a durable key, and the watch loop retries a claimed-but-undelivered alert.

### Findings and dispositions

| # | Sev | Finding | Disposition |
| --- | --- | --- | --- |
| L1 | critical | A pid-less lock is reclaimed on age while its owner is alive, so two successors can launch | ACCEPTED — root cause of the rewrite; P1 removes the window rather than widening the grace |
| L2 | high | A post-spawn `unknown` successor is never given a watchdog and later dispatches refuse | ACCEPTED — arm/reconcile for every record carrying a `session_id`, `unknown` included |
| L3 | high | `reconcile_watch` accepts an unrelated process holding a recycled watchdog PID | ACCEPTED — P2 |
| L4 | high | A delivered alert is duplicated if the watcher dies before persisting its marker | ACCEPTED IN PART — the claim window is fixed by P1; the duplicate itself is the DESIGNED trade and is now documented as at-least-once. The recommendation (an idempotent remote delivery endpoint) is REJECTED for a local hook: `osascript` is not transactional, and marking before delivering is the worse failure — it durably suppresses an alert nobody received |
| L5 | medium | Killing the launcher after the watchdog fork can arm two watchdogs | ACCEPTED — P2 writes `watch_gen` before the fork |
| L6 | medium | The rearm notification is a single lossy attempt and is never retried | ACCEPTED — P3 |
| L7 | medium | Transcript discovery/stat has no deadline and can freeze the watch loop on a hung mount | ACCEPTED — reuse the existing `timed_to_file` probe so an untimely result is DEGRADED, consistent with `read_agents`. Low real-world probability on local APFS, but consistency costs one fork per 60s poll |
| C1 | high | A value-taking option consumes a following flag, so `--model --dry-run` performs a REAL dispatch | ACCEPTED — class A, one choke point |
| C2 | high | `cwd=` and `handoff=` are written raw, so a newline in a path forges `finished=1` | ACCEPTED — class C, 2 of 24 sites |
| C3 | high | TERM releases the lock and then execution CONTINUES into the launch | ACCEPTED — split EXIT cleanup from INT/TERM; the signal handler must exit with signal status |
| C4 | medium | A non-numeric `--heartbeat-min` silently disables heartbeat evaluation and still exits 0 | ACCEPTED — class B, 4 of 8 controls |
| C5 | medium | A physical path containing a quote generates an unparsable SessionStart command | ACCEPTED — shell-escape the runtime path while preserving the literal `$HOME` |
| T1 | high | The launching-recovery fixture writes `state=launching` itself, so durable launch intent is untested | ACCEPTED — mutation named and reproduced |
| T2 | high | The fencing token is never contested at the irreversible fence | ACCEPTED — mutation named and reproduced |
| T3 | high | Reconcile-watch coverage proves a PID changed, not that monitoring continues | ACCEPTED — mutation named and reproduced |
| T4 | high | No poll-loop test combines terminal completion with failed delivery | ACCEPTED — mutation named and reproduced |
| T5 | medium | CR rejection is untested (case V supplies only LF) | ACCEPTED — mutation named and reproduced |
| T6 | medium | The `--` escape is asserted only in dry-run output, never in a real dispatch | ACCEPTED — mutation named and reproduced |
| T7 | medium | The installer end-to-end test uses the host `uname`, so the Linux settings branch is never exercised | ACCEPTED — mutation named and reproduced |

Every test-lens finding arrived with a surviving mutation, which is the bar for accepting one; all seven are taken.

### Recurring-class enumerations (counts, not instances)

A defect class that reappears at a different site is not fixed by fixing the site, so each of these was enumerated exhaustively with a three-way classification before any edit.

| Class | Sites | UNSAFE | SAFE | N/A | Fix |
| --- | --- | --- | --- | --- | --- |
| A — an option value can swallow a following option token | 7 (5 options × dispatch and watch parsers) | 7 | 0 | 0 | `need_val` rejects a following `-*`; all 7 funnel through it |
| B — a numeric control reaches arithmetic or `sleep` unvalidated | 8 controls | 5 (`HEARTBEAT_MIN`, `POLL_SEC`, `MAX_HOURS`, `AGENTS_TIMEOUT_SEC`, `FS_TIMEOUT_SEC`) | 2 (`ARM` is string-compared; derived mtimes are `-n`-guarded) | 1 (`TRANSCRIPT_GRACE` is an internal constant) | one `need_num` validator at every entry point |
| C — a record value is written without `rec_ok_value` | 24 writes | 2 (`cwd=$CWD_ABS`, `handoff=$FILE_ABS`) | 22 (16 via `rec_put`, 3 `rec_set` key-only, 3 constant or generated) | 0 | route the creation block through `rec_put`; `objective=` was already validated at its parse site |

The reviewer independently named exactly the 2 unsafe record sites, which is the cross-check that the enumeration is complete rather than merely long.

Class B's numbers are **corrected from the first write-up of this table (8 controls / 4 unsafe)**, and the correction came from the fix, not from the review.
`CLAUDE_HANDOFF_FS_TIMEOUT` is a ninth control and a fifth unsafe one — L7's own fix introduced it, so an enumeration written before that fix could not have counted it, and the honest record is that the count was right for the code it was written against and wrong by the time the class was closed.
`LOCK_PID_GRACE` left the N/A column because P1 deleted it outright; `WATCH_LEASE_MULT` (from P2) took its place.
Round 3 then removed `WATCH_LEASE_MULT` as well — a lease is now held, not aged — so the class stands at **8 controls / 5 unsafe / 2 safe / 1 N/A**, and the table above carries the round-3 numbers rather than the round-2 ones.
Every entry point of all five unsafe controls now passes through `need_num`, which is what closes the class.

### What the round-2 fixes produced

The three primitives landed as designed, and the test suite was rewritten around the lease/generation contract rather than patched to match new output.
Ten cases are new or rewritten, each mutation-verified individually (sixteen mutations run in total; a named mutation table applied in place, with the anchor count checked so a mutation that failed to apply cannot be recorded as "survived"):

| Case | Pins | Mutation that kills it |
| --- | --- | --- |
| K (rewritten) | arming publishes `watch_gen`, `watch_pid_<gen>` and the generation's own lease, and the watcher really polls | `K-arm-from-fork` (also kills AD, AE, AH, Y) |
| Q (rewritten) | a dead owner's claim file is broken, and nothing is left behind | `Q-no-break` — **superseded in round 3**: under `flock` there is no corpse to break, and Q now asserts that a leftover file with arbitrary content is simply a file |
| S (rewritten) | a live owner is never overrun at any age, and its token is untouched | `S-break-live` (also kills O) |
| Y (rewritten) | a lost watcher is re-armed under a NEW generation | `Y-no-reconcile` |
| AC | a legacy `mkdir`-shaped lock is a corpse, not a won claim | the pre-fix `claim_try` (both guards) |
| AD | a live PID with a stale lease is re-armed | `AD-lease-ignored` |
| AE | a live watcher is NOT re-armed, and exactly one lease exists | `AE-always-rearm` |
| AF | unparsable `--bg` output leaves `state=launching` and refuses an unforced retry | `AF-parse-any` |
| AG | the fencing token is re-checked at the irreversible fence | `AG-no-verify` |
| AH | a RE-ARMED watcher is a working watcher (it alerts on a later `blocked`) | `AH-rearm-no-loop` |
| AI | the watch loop exits on the durable `finished` fact even when delivery fails | `AI-loop-on-marker` |
| AJ | a CR in the objective is refused (T5) | `AJ-lf-only` |
| AK | `--` escapes a dash-leading objective in a REAL dispatch (T6) | `AK-no-escape` |
| AL | the pre-loop lease beat, which is what a zero-hour deadline depends on | `AL-no-preloop-lease` — **superseded in round 3**, and the round-2 claim was OVERSTATED: rewritten for the lease-is-held contract, AL turned out to pin nothing at all (see M4 below) |
| e2e-linux-settings / e2e-darwin-settings | the installer's OS branch selects `settings.linux.json` vs `settings.json` (T7) | collapsing `case "$(uname)"` to either arm, or a `Linux`/`linux` typo — three mutations, each killed by the case that owns that arm |

**A HIGH was found at fix time, by a probe rather than by a reviewer.**
`ln <src> <DIR>` does not fail EEXIST — it links the source INSIDE the directory and *succeeds*.
So P1's new claim primitive reported a won claim against any directory sitting at the claim path, while the path stayed foreign and the fencing token read back empty; the dispatch then died at `verify_lock`.
That is not a hypothetical shape: it is exactly what the `mkdir`-based predecessor left behind, so **every machine upgrading across this commit would have wedged permanently on its first dispatch**.
Fixed with an explicit `[ -d ]` refusal plus reading the claim back and comparing the token, and `rm -rf` (not `rm -f`) on the moved-aside corpse, since a corpse may be a legacy directory and `rm -f` would strand the claim path forever.
Case AC pins the **pair**: either guard alone masks the other, so each mutated in isolation survives, and only the pre-fix `claim_try` kills the case.
Stated plainly rather than counted as two mutation-verified fixes — the read-back is defence in depth and is not independently pinned, because there is no portable way to make `ln` succeed without transferring ownership other than the directory case the `-d` guard already refuses.

**Two mutations survived, and both were treated as findings against the code, not the tests.**

- `S-age-steal` survived because the live-owner rule was enforced **twice** — once in `claim_lock` and again inside `claim_break_if_dead`. Two sites for one rule means the tests pin whichever runs first and the other can rot unnoticed, so the outer copy was deleted. With one enforcement site, `S-break-live` now kills cases O and S.
- `K-no-lease` survived because the pre-loop `watch_beat` only matters when the deadline has already passed. Case AL was added for exactly that path, and `AL-no-preloop-lease` kills it.

One test defect was also found by running the suite rather than by reading it: case K arms a REAL watchdog that outlives its dispatch, and it had been arming against the shared record, so it kept writing after later cases had recreated that file — which is what made case L's `alerted_finished` assertion flake.
Every arming case now owns its own handoff file (`NEWHO`), and the suite is verified to leak no processes (`pgrep -f 'sleep 300'` identical before and after a full run).

All 9 test files are green.
The live end-to-end dispatch was re-run against the rewritten primitives, because round 1's live run proved the OLD lock/watcher code and does not carry over.
**By that same rule this run is now historical too**: it exercised P1's `ln`-based claim and P2's aged lease, both of which round 3 replaced with `flock`, so it is evidence about code that no longer exists and a further live run is required before the branch is called done.
2026-08-18 02:20:02Z: dispatch → session `26dc4deb` → the successor appended `SUCCESSOR-OK 2026-08-18T02:20:22Z` to the handoff file 20s later → the watchdog recorded `finished=1`, delivered the alert (`.dispatch.alert.finished` exists, and the marker is written only after delivery), and exited within the same poll.
The record shows the full intended progression — `launching` → `pending` → `verified`, with `watch_gen` and `watch_pid_<gen>` published at arm time — and afterwards the claim file is gone, with only the generation lease and the alert marker left behind.
That last clause is **false of the current code and was true only of P1**: a `flock` lock file is created once and never unlinked, so the artifact to look for after a clean run is a lock file that exists and is NOT held, not an absent one.
Evidence at `<scratchpad>/live2/`.

## Review dispositions — Codex diff round 3 (three parallel lenses, `-p solx`)

BASE `d88adc6692db23c460318bc501e831a6d877de61` → HEAD `b23d0387696f1f713812e81b4171ca4811265e05`.
Route verified from the run-log banner rather than the flag: `model: gpt-5.6-sol`, `reasoning effort: xhigh`, `read-only`, correct workdir, on all three lenses.
Scope check PASSED: `reviewed.base`/`reviewed.head` exact on all three, no duplicate file entries, no reversed line spans.
The lifecycle and test lenses each read all 8 manifest files; **the correctness lens read only 4** (`hooks/handoff.sh`, `hooks/context-watchdog.mjs`, `install.sh`, and the spec), so its coverage is partial and round-level manifest coverage rests on the other two.
The test lens also read 5 files outside the diff (`settings.json`, `settings.linux.json`, the two memory-injection hooks, this handoff) — context, not a scope failure.

**31 findings: 0 critical, 21 high, 10 medium, 0 low.** Round 2 was 19 and round 1 was 18, so **the rate went UP**, not flat.
That is not the flat signal that triggers a rewrite; it is what a rewritten region looks like when it is reviewed for the first time. The three primitives P1–P3 landed *between* rounds 2 and 3, so round 3 is round ONE for most of this code, and eight of its high findings are against lines that did not exist when round 2 ran.

### The decision: P4 — one kernel lock for every ownership claim

Five of the seven lifecycle findings are the same shape, and it is the shape P1 and P2 were supposed to have fixed:

- L1 — the dead-claim decision reads the owner, tests `kill -0`, and then `mv`s. The decision is bound to a **pathname**, not to the object it examined, so a breaker paused between those steps removes the *winner's* fresh claim.
- L2 — a fresh lease plus a recycled PID falsely proves a watcher alive.
- L5 — PID reuse can suppress a durable alert indefinitely.
- L4 — publishing `watch_gen` before the fork creates a durable phantom generation when the fork never arrives.
- L3 — re-arming never fences the watcher generation it displaced.

Every one of them exists because ownership was expressed as **data about a process** (a pid, a token, an mtime, a staleness multiple) that some other process then interprets.
Round 2 already replaced one such scheme with another and the class came straight back, so round 3 stops writing ownership down:

**P4 — every ownership claim is an exclusive `flock(2)` on a fixed descriptor, and nothing else.**
The lock lives on the open file description; acquisition is atomic; the kernel releases it when the last descriptor closes, **including on SIGKILL and on a panic**.
There is no owner field, no token, no corpse, no age, no grace period, and no cleanup path to get wrong — which deletes `LOCK_STALE_SEC`, `LOCK_PID_GRACE`, `WATCH_LEASE_MULT`, `claim_break_if_dead`, the `.reclaim` sub-lock and the whole `mv`-the-corpse your-project.
Three claims, three fixed descriptors: **9 = the dispatch lock, 8 = the watcher's generation lease, 7 = an alert claim**.

Three consequences are load-bearing and each is pinned by a case:

1. **The lock file is created once and NEVER unlinked** (case AG2). Unlinking reintroduces pathname identity: `rm` plus a fresh file at the same path leaves the holder's lock exactly where it was and hands the next caller a lock on a *different* inode — two locks at one path is two successors. A leftover file is just a file (case Q); an unheld lock reads as free.
2. **A descriptor must not leak into a child** (cases BE, AM). A child that inherits fd 8 re-locks its own parent's file description, which always succeeds, so an unclosed descriptor makes a live watcher read as dead. All **14 spawn sites** are enumerated in the source: 11 close `9>&- 8>&- 7>&-`, 2 hold nothing, and 1 (`lock_take`'s perl) inherits deliberately, which is the point of it.
3. **"Is a watcher alive" is answered by taking its lease, not by looking at it.** `lease_probe` prints `held`, `free`, or *nothing at all*; silence is DEGRADED, and unobservable liveness counts as watched (case AX). A lease means "watching NOW", so a watcher whose deadline has already passed must never publish one (case AL) — otherwise arming is a race decided by scheduling.

`flock(1)` does not exist on macOS; perl 5.34 does, and `open(my $fh, ">&=", $fd)` is `fdopen`, so a two-line perl helper takes the lock on a descriptor bash already holds. The test suite probes locks with its **own independently written** perl (`flock(LOCK_EX|LOCK_NB)`), never by calling the product's `lock_hold` — a probe written in terms of the implementation under test proves nothing about it.

### Findings and dispositions

| # | Sev | Finding | Disposition |
| --- | --- | --- | --- |
| C1 | high | A present agent with an empty state is treated as finished | FIXED — a listed row with an unreadable state is `unknown`, not gone and not finished (cases AR, AS) |
| C2 | high | Trailing newlines are stripped from valid handoff and cwd paths | FIXED — refused at the raw path *and* at the resolved path (case AW) |
| C3 | high | Directories pass as non-empty handoff files and cause a useless paid dispatch | FIXED — `[ -f ]`, because `-r` and `-s` are both true of a directory (case AP) |
| C4 | high | Logical-versus-physical cwd comparison rejects a correctly placed successor | FIXED — `pwd -P` on both sides (case AQ) |
| C5 | high | The notification implementation cannot deliver on Linux | FIXED — a `notify-send` arm; both branches are driven by case BB through a PATH-scoped `uname` |
| C6 | high | A record value is recursively evaluated as Bash arithmetic | FIXED — the recorded watch pid is DIAGNOSTIC and never reaches arithmetic or a liveness decision (case AU) |
| C7 | medium | Notification messages are interpolated unescaped into AppleScript source | FIXED — the message travels as an **argv value** (`on run argv` … `item 1 of argv`), so no quoting rule applies to it |
| C8 | medium | The watchdog prints an invocation that fails for valid operands | FIXED — the printed command quotes both operands and separates the objective with `--` |
| C9 | medium | A repo directory ending in LF can make install.sh operate on a sibling repo | FIXED — `REPO_DIR` is checked to contain `install.sh` and refuses loudly, since a command substitution strips the trailing newline and physical resolution cannot recover it |
| L1 | high | The dead-claim decision is not bound to the object that `mv` removes | FIXED — P4; there is no corpse and no break step |
| L2 | high | A fresh lease plus a recycled PID falsely proves a watcher is alive | FIXED — P4; no pid is consulted (cases AD, AZ) |
| L3 | high | Re-arming never fences the displaced watcher generation | FIXED — a superseded watcher stands itself down on the record's generation (case AM) |
| L4 | high | Publishing `watch_gen` before fork creates a durable phantom generation | FIXED — the generation stays written before the fork (a launcher killed mid-arm must still name what it started), but arming is proven by the lease being HELD, so a phantom generation reports FAILED TO ARM and is re-armed |
| L5 | high | PID reuse can suppress a durable alert indefinitely | FIXED — P4; the alert claim is fd 7 |
| L6 | medium | The first-lease observation bypasses the filesystem timeout | FIXED — every lease observation goes through `fs_get "$FS_TIMEOUT_SEC" lease_probe` (case AX) |
| L7 | medium | Heartbeat stat timeouts are silently treated as no artifact | FIXED — both probes failing is DEGRADED, and it alerts (case AT) |
| T1 | high | Concurrent recovery does not pin the atomic dead-claim move | OBSOLETE under P4 — there is no move to pin. Replaced by case BA (a SIGKILLed holder leaves nothing to reap) and AG2 (unlinking the file does not release the lock) |
| T2 | high | The real notification sink is completely bypassed | ACCEPTED — case BB drives the real sink on both OS branches |
| T3 | high | The missing-transcript test supplies the production timestamp itself | ACCEPTED — case N |
| T4 | high | Cached tokens can be ignored without crossing any tested band | ACCEPTED — context-watchdog band coverage |
| T5 | high | Non-background identity verification has no negative case | ACCEPTED — case P2 |
| T6 | high | Filesystem observation deadlines are not exercised | ACCEPTED — cases AT and AX |
| T7 | high | Zero-hour expiry cannot detect a wrong deadline unit | ACCEPTED — case AY crosses the boundary in BOTH directions on a controlled clock |
| T8 | high | Legacy watcher records can regress to PID-only identity | ACCEPTED — case AZ |
| T9 | high | Per-option validation can disappear while the shared-helper test stays green | ACCEPTED — case U2 drives EVERY value-taking option, not the helper |
| T10 | high | A substring accepts the wrong state key on cwd mismatch | ACCEPTED — case P |
| T11 | medium | The UUID assertion proves a value, not the record field monitoring reads | ACCEPTED — case A asserts the record field |
| T12 | medium | Failed delivery of the rearm notice is not tested through the poll loop | ACCEPTED — case BC |
| T13 | medium | The stale-session resume branch has no clock-controlled coverage | ACCEPTED — context-watchdog resume coverage |
| T14 | medium | Portable-path tests omit every character the escaping helper exists for | ACCEPTED |
| T15 | medium | Second-install idempotence compares only filtered inject-hook counts | ACCEPTED |

**S1 was found by Claude reviewing its own fixes, not by any lens**: a mode branch that fails *before* its `exit` — a `die` inside a command substitution kills only the subshell — falls through the `case` into `dispatch "$@"` and dispatches a successor nobody asked for, reporting `$1: unbound variable` instead of the real failure. Guarded, and pinned by case AV.

### Mutation ledger — 22 mutations, per ITEM

Each mutation is applied by a named script with an **anchor assertion** (`assert s.count(old)==1`), so a mutation that failed to apply cannot be recorded as "survived", and the runner restores the original before reporting.

| Mutation | What it breaks | Result |
| --- | --- | --- |
| C3-no-regular-file | the `-f` handoff-file check | KILLED by AP |
| C4-logical-pwd | `CWD_ABS` resolved logically | KILLED (the log truncates at three failure lines and the first is case A, so unique attribution to AQ is not established) |
| C1-dispatch-presence | dispatch reads presence, not state | KILLED by AR |
| C1-watch-empty-finished | the watcher reads an empty state as finished | KILLED by AS |
| LIFE7-ignore-probe-failure | both probes failing is treated as "no heartbeat" | KILLED by AT |
| C6-unvalidated-pid | the recorded watch pid becomes a liveness signal | KILLED by AU |
| S1-no-fallthrough-guard | the mode-branch fall-through guard | KILLED by AV |
| C2-no-raw-newline-check | the raw-path newline refusal | KILLED by AW |
| LIFE6-collapse-unknown | "could not tell" collapses into "stale" | KILLED by AX |
| mtime_of-absence-as-failure | absence read as a failed look | KILLED by Y |
| M1 lock_take-always-succeeds | the lock primitive itself | KILLED by 13 cases (K, S, Y, AD, AE, AG, AH, AM, AN, AU, AZ, BC, BF) |
| M2 spawn-inherits-descriptors | the successor spawn stops closing 7/8/9 | KILLED by **BE alone** |
| M3 no-legacy-directory-guard | the `[ -d ]` sweep of a predecessor's `mkdir` lock | KILLED by AC, AF |
| M5 no-verify_lock | the irreversible fence | KILLED by **AG alone** |
| M7 duplicate-watches-anyway | a duplicate watcher continues without a lease | KILLED by **BF alone** |
| M8 unopenable-lease-is-free | an unreadable lease collapses into "nobody is watching" | KILLED by **AX alone** |
| M10b superseded-keeps-watching | the supersession stand-down | KILLED by **AM alone** |
| M11 deadline-after-lease | `DEADLINE` computed below the lease block | KILLED — **structurally**: `$DEADLINE` is then unbound under `set -u`, so the ordering cannot be got wrong silently. A wide kill is weak evidence, and it is recorded as structural rather than as test-pinned |
| M12 transcript_for-no-return | the loop's own status leaks out of `transcript_for` | KILLED by N, BD |
| M4 deadline-does-not-gate-the-lease | the zero-hour rule | **SURVIVED → a defect in case AL** (below); after the fix, KILLED by **AL alone** |
| M10 no-lock_drop-before-standing-down | the lease drop in the supersession branch | **SURVIVED — the mutation is INVALID**, not a coverage gap (below) |
| transcript_for `return 0` → `:` | — | **SURVIVED — a no-op mutation**: `:` returns 0 exactly as `return 0` did. Re-expressed as M12 above, which dies |

**M4's survival was a test defect, and the test was the one written to catch exactly this.**
Case AL widens the race window by injecting a `sleep 1` into a *copy* of the script — but the copy is produced by a redirect, so it is mode 0644, and the watcher is spawned with `nohup "$0" --watch`, i.e. **executed**. The child died `Permission denied` before it ever reached the lease, arming failed for a reason that had nothing to do with the deadline, and both assertions passed under every mutant: a control that could never fail. Fixed with `chmod +x` plus an `[ -x ]` assertion, after which M4 is killed by AL and nothing else.
The class was then enumerated rather than patched at the one site: **3 derived-copy sites — 1 UNSAFE (AL), 2 safe (AG never reaches arming; AV uses `cp`, which preserves the mode)** — and `chmod +x` was added to both redirect-produced copies so no later assertion can inherit the hole.

**M10 is an invalid mutation and is recorded as such rather than as a survivor to chase.**
`lock_drop 8` in the supersession branch is followed by `return 0`, and `watch_loop`'s only caller is `watch_loop "$REC"; exit 0` — so the process exits and the kernel releases the descriptor either way. No mutation of that line can be observed at process granularity. The line stays (the function should be correct independent of its caller) with a comment saying so, and the *behaviour* is pinned by M10b instead, which removes the stand-down itself and dies to case AM.

### Live end-to-end, re-run against P4

2026-08-18 **04:53:33Z**, session `ccb5fc03` (`ccb5fc03-d4d6-41eb-9497-11d9c51b59c0`), cwd `~/code/dotfiles-handoff`.
The launcher reported `watchdog: generation 1787028818.98275.27629 (holding its lease; pid 98493 is diagnostic)` — the arming line now names what was actually proved.
Measured 15s in, while the successor was still working: the dispatch lock **free** (the dispatch had returned) and the generation lease **HELD**.
The successor appended `SUCCESSOR-OK 2026-08-18T04:53:51Z` 18s after dispatch; `claude agents --json` shows the row at `state: done`.
The record carries the full intended progression — `launching` → `pending` → `verified`, then `watch_gen`, `watch_pid_<gen>` (diagnostic), `finished=1`, `alerted_finished=1`.

The post-run artifact is what P4 predicts and what round 2's write-up got wrong: **both lock files still exist and neither is held.**
The dispatch lock is a 0-byte file; the alert claim carries one informational line that says of itself that it is informational (`whether it is held NOW is the kernel's answer, not this line's`).
No watcher process survives, and pid 98493 is gone.

One probe defect, recorded because it could have produced a false pass: the first liveness check grepped for `SUCCESSOR-OK` anywhere in the handoff file, and the *instructions* contain that string — so it matched instantly and would have reported success against an untouched file. Re-run anchored at `^SUCCESSOR-OK`, which is what the timestamp above comes from.

## Review dispositions — Codex diff round 4 (three parallel lenses, `-p solx`)

BASE `d88adc6692db23c460318bc501e831a6d877de61` → HEAD `90db75e0ceefb050b58a5b1a708160077db10b32`.
Route verified from each run-log banner rather than from the flag: `model: gpt-5.6-sol`, `reasoning effort: xhigh`, `read-only`, correct workdir, on all three lenses.
Scope check PASSED on all three: `reviewed.base`/`reviewed.head` exact, the full 8-file manifest covered by **every** lens this time (round 3's correctness lens read only 4), no duplicate file entries, no reversed or out-of-range line spans, and no `approve` sitting next to a high finding.
The lifecycle and test lenses also list the untracked `HANDOFF-auto-handoff.md` — read for context, not reviewed as change.

**23 findings: 0 critical, 14 high, 8 medium, 1 low** — down from round 3's 31.
This is the number that mattered: round 3's rate rose because P1–P3 had landed *between* rounds, so round 3 was round ONE for that code.
**Round 4 is the first round to read P4 after a round that already read it, so it is the first honest rate on this region** — and it fell.
The escalate-to-user trigger (flat or rising on the same region) did not fire, and no fifth rewrite was warranted.

Nor did the findings cluster in P4: only 5 of the 23 are against the locking region itself, and none of those is the ownership class that forced P1→P2→P3→P4.
The rest are the surrounding surfaces — the installer's target set, the Linux service generation, the context watchdog's transcript window, and the alert lifecycle.

### The two rules this round turned on

**A pathname is not an object identity** — the same rule P4 was built on, arriving three more times in different clothes:

- **C1 ≡ L1** — the legacy sweep `rm -rf`'d the very path it was about to lock, so a migration could leave two independently locked inodes at one path. Reproduced before it was fixed (`l1side.sh` / `l1late.sh`: inodes 45046231 and 45046238 both HOLD). Round 5 then retired the sweep entirely: **there is no sweep**. Removing a claim in the predecessor's shape is a decision that nobody holds it, and this layer has no way to tell a live pre-upgrade launcher from the corpse of one — the mkdir claim's pid-LESS window is the very defect that retired it. A dispatch that finds one therefore **refuses**, logs `HandoffLegacyLockPresent`, removes nothing, and prints the `rm -rf` the operator runs once they have checked (cases AC, BH). The P4 paths took a `.flock` suffix nothing else has ever created.
- **C3** — a symlink and its target are two spellings of one handoff, so each got its own record and its own lock, and both dispatched. The final component is now resolved (bounded at 40 hops) *before* the record path, the lock path or any alert claim is derived.
- **C4** — a handoff removed or replaced between validation and launch still produced a paid, verified dispatch of the wrong content. `-f`/`-r`/`-s` **and** the device:inode identity are re-asserted at the irreversible boundary, and the refusal records `prelaunch_failed` — nothing was launched, so the retry it promises needs no `--force` (round-5 correctness #4; it left `launching` for two rounds, which the guard then refused).

**Generated config is per-grammar, and a descriptor is inherited by every child** — the other two classes:

- **C11** — one `shq_in_dq` was doing duty for plist XML, a systemd command line and a systemd bare path value. Three encoders now (`xml_text`, `systemd_arg`, `systemd_path`), applied to a counted enumeration: 9 XML interpolations, 1 `ExecStart` word, 5 `PathModified` values, 1 settings hook.
- **C2 ≡ L2** — a command substitution is a *forked child*, so the round-3 "14 spawn sites" inventory was the wrong unit: the closes belong on the subshell, `( exec 9>&- 8>&- 7>&-; … )`. Reproduced: a holder SIGKILLed inside `$(sed…|tail)` and an independent probe still read the lease HELD.

### Findings and dispositions

| # | Sev | Finding | Disposition |
| --- | --- | --- | --- |
| C1 ≡ L1 | high | `lock_hold` `rm -rf`s the path it is about to lock; legacy migration leaves two locked inodes at one path | FIXED — there is no sweep: a legacy claim is a REFUSAL naming the operator's own `rm -rf`, decided before any descriptor is opened; P4 paths carry a `.flock` suffix (cases AC, BH) |
| C2 ≡ L2 | med | the `arm_watch` substitution leaks fd 9 into an unenumerated child | FIXED — the closes moved onto the SUBSHELL at every substitution or pipeline that can run under a claim (case BI) |
| C3 | high | a symlink and its target are two ownership records, so both dispatch | FIXED — identity is the resolved file, never its spelling (case BN) |
| C4 | high | a handoff removed or replaced after validation still yields a paid, verified dispatch | FIXED — existence *and* device:inode re-asserted at the boundary (case BO) |
| C5 | med | `session_id=--require=/tmp/x.js` is parsed by node as an option and preloaded | FIXED at the boundary — `--` terminates options at both node call sites (case BP). **Second half of the recommendation REJECTED with reason** below |
| C6 | high | alert markers are keyed for the record's whole life, so a second episode is silent | FIXED, **both halves** — an episode ends when the poll observes the condition clear, and the EXPIRY fact is generation-scoped like the terminal fact (case BQ) |
| C7 | med | one transcript record larger than the 1 MiB tail makes the context watchdog silent | FIXED — the window grows 1 MiB → 16 MiB until a whole main-chain record is inside it; one byte before the window is read deliberately so "is line 0 a fragment?" answers itself |
| C8 | high | the newline-path guard can validate one repo and install another (the stripped sibling) | FIXED — an object-identity test (`-ef`) against `${BASH_SOURCE[0]}` plus an explicit newline refusal, both hoisted above first use |
| C9 | high | a MIRROR aliasing the PRIMARY destroys the primary installation | FIXED — the whole target set is validated before the first link: PRIMARY≡REPO_DIR, MIRROR≡PRIMARY and MIRROR≡REPO_DIR each refused before anything is written |
| C10 | med | an out-of-home install persists a host-specific absolute path into SHARED settings | FIXED for the write — refused unless `ALLOW_ABSOLUTE_HOOK_PATH=1`, and the opt-in warns. **PARTIALLY ACCEPTED** on the reconcile half, below |
| C11 | med | Linux service generation breaks on a repo path with spaces (and on `%`, `&`, `<`) | FIXED — three per-grammar encoders over a counted enumeration |
| C12 | low | the acceptance doc still says a dead process's lock file is "broken" | FIXED — corrected in place (acceptance item 10); under P4 the file exists and is simply not held |
| L3 | high | a broken lock backend is reported as live contention | FIXED — perl distinguishes `EWOULDBLOCK`/`EAGAIN` (35 here) → 1 from anything else → 3, which maps to the existing "unobservable" code every caller treats as DEGRADED. `lock_tool` prefers perl, because `flock(1)` exits 1 for both (case BJ) |
| L4 | high | an unopenable lease admits duplicate watchers | **ACCEPTED IN PART**, below |
| L5 | high | a superseded watcher commits terminal state into the new generation | FIXED — the terminal fact is `finished_<gen>`, and the fence is re-read at the WRITE rather than at the top of the poll (case BK) |
| L6 | high | a terminal alert that could not be delivered is lost permanently | FIXED — retried on the poll cadence to a bounded budget; on exhaustion `alert_undelivered_<key>` plus a log line make the loss durable and visible (case BL) |
| L7 | high | unbounded record reads freeze monitoring and retain the lease | FIXED — record and stat reads go through the bounded `fs_get` machinery; a timeout is DEGRADED, never a value |
| L8 | med | the deadline is not atomic with publishing the lease | FIXED — the clock is re-read after acquisition; an already-expired watcher drops the lease and lets the expiry path speak instead of advertising a watcher (case BM) |
| T1 | high | notifier site 4 can drop its closes with all 9 test files green | FIXED — case BF drives a real `--watch` process against a notify sink that blocks after signalling readiness, SIGKILLs the watcher, and requires BOTH the lease and the alert claim to become free while the sink is still held |
| T2 | med | `lock_is_held` CREATED the path it probed, so "exists and unheld" was vacuous | FIXED — the probe opens read-only and reports a missing path as its own state (3), which every assertion treats as a failure. Same class as round 3's M4: a control that cannot fail |
| T3 | med | the Linux wiring case is pre-satisfied by the tracked canonical hook | FIXED — `e2e_case` takes a `mode` (`append`\|`match`) checked as a PRE-install precondition against the selected settings source; four cases now cross canonical/non-canonical × Darwin/Linux |

**S2 was found by this session reviewing its own round-3 write-up, not by any lens**: the spawn-site enumeration claimed "all 14 sites" when command substitutions were never in the inventory.
Superseded by L2/L7 — the class was real, so the fix is the subshell idiom at every site plus a corrected comment that says what is actually enumerated.

### The two recommendations taken only in part, and why

**C5 — the `--` is the cure; a session-id format allow-list is not.** Adding `--` at both node call sites removes the injection outright: an untrusted record value can no longer be anything but data.
The reviewer also wanted ids validated against their accepted format.
Rejected: these ids are minted by `claude`, whose *state* enum this branch already knows is not closed, and an allow-list on another program's identifiers fails closed against the next id shape it invents — trading a fixed injection for a future outage.

**C10 — warn about a foreign `inject-global-memory` entry, never remove it.** Removing an entry that names another machine's path silently disables global memory on the machine that needed it, and two machines installing in turn would delete each other's hook forever.
An extra error line on SessionStart is the better failure.
The reasoning is in the source at `warn_stale_inject_hooks`.

**L4 — a degraded watcher beats no watcher.** The recommendation ("do not enter `watch_once` without a lease") trades a duplicate watcher for NO watcher, and an unwatched successor is the exact failure this script exists to prevent — the four sessions blocked since 2026-06-19.
Taken instead: bounded retry, then `lease_degraded` and a degraded ALERT, so "monitoring may be doubled" is a fact a human is told rather than a silence that reconciliation reads as health.
The watcher still watches.

### Three things the FIX pass found that no lens did

1. **The C6 fix was incomplete when first written.** The finding named blocked *and* expiry episodes; ending the episode covered the poll-time conditions, but the expiry marker was still the record-scoped `expired`, so a re-armed watchdog that expired again would have been silent. Caught by reading the finding against the code a second time while writing case BQ, and pinned by BQ's second half plus mutation M-C6b.
2. **A fixture bug that had been making an assertion pass by accident.** `tests/install-guards.test.sh` failed four assertions on `/var` vs `/private/var` — `mktemp -d` returns the logical spelling. Fixed with `tmp="$(cd "$(mktemp -d)" && pwd -P)"`, which also cured a silently-unsound G3-optin assertion: `/private/var/x` *contains* `/var/x`, so a `contains` check had been passing for the wrong reason.
3. **A dead `-ef` guard inside `link()`**, left over from an earlier shape of C9 and unreachable once the whole target set is validated up front. Deleted rather than left to read as protection.

### Mutation ledger — 26 mutations, 26 KILLED, 0 survivors

Same contract as round 3: every mutation is applied by a named script with an anchor assertion (`assert s.count(old)==1`), each carries an ANCHOR case id that must report a failure, and the runner restores the original before reporting — so a mutation that failed to apply can never be recorded as "survived".

| Batch | Mutations | Target |
| --- | --- | --- |
| `results.json` | M-F1a, M-F1b, M-F2, M-F3a, M-F3b, M-F5a, M-F5b, M-F6, M-F7, M-T1, M-T2 | `hooks/handoff.sh` (C1/L1, C2/L2, L3, L5, L6, L8, T1, T2) |
| `results-cw.json` | M-C7 | `hooks/context-watchdog.mjs` |
| `mut-install.json` | M-C8, M-C9, M-C10, M-C11a, M-C11b, M-C11c, M-T3 | `install.sh` |
| `results-c3c6.json` | M-C3, M-C4a, M-C4b, M-C5a, M-C5b, M-C6a, M-C6b | `hooks/handoff.sh` (C3–C6) |

Every mutation reports `applied: true` with its anchor case in `anchors_hit`, so none can have been recorded as survived for failing to apply.
The C3–C6 batch is the tightest of the four: each of its seven mutations is killed by its anchor case **alone** — M-C3 → BN, M-C4a/M-C4b → BO, M-C5a/M-C5b → BP, M-C6a/M-C6b → BQ.
Round 3 had two survivors (one real test defect, one invalid mutation); round 4 has none.

Seventeen named cases are new this round, and the installer e2e matrix widened to four.
`tests/handoff.test.sh` gains **BF–BM** for the first batch and **BN** (symlink identity), **BO** (removed/replaced at the boundary, with the untouched dispatch as its anchor), **BP** (a `--require=` session id must not be preloaded, anchored on the record still reaching `finished=1`) and **BQ** (blocked → running → blocked twice, then two expiries across two generations) for C3–C6.
`tests/context-watchdog.test.sh` gains **J**, and the new `tests/install-guards.test.sh` carries **G1–G4**.

## Review dispositions — Codex micro-review of the round-4 fix diff (`-p solx`)

The round-4 fix diff reviewed on its own (`90db75e0` -> `9b20c1e7`), before the next full panel,
per the standing rule that a fix diff is cross-reviewed with the counter-party first.
Scope check PASSED: `reviewed.base`/`reviewed.head` exact, all eight manifest files, no duplicate
entries, no reversed spans, `needs-attention` consistent with four highs.

**8 findings (0 critical / 4 high / 4 medium / 0 low). All 8 fixed.**

| # | Finding | Disposition | Case | Mutation |
| --- | --- | --- | --- | --- |
| C3 | a `readlink` that FAILED was read as "not a symlink", so a handoff replaced mid-resolution dispatched against the link's own spelling | fixed — an unreadable link is a degraded read and refuses | BR | M1 |
| C4 | the dispatch-boundary identity check failed OPEN: `stat` not answering read as "unchanged" | fixed — both inode reads required, or refuse | BS | M2 |
| C8 | the `install.sh` spans-lines refusal covered `\n` but not `\r` | fixed — one guard, both characters | G5 | M3 |
| C9 | `same_dir` compared SPELLINGS whenever a directory did not exist yet, so a mirror aliasing a not-yet-created primary was accepted | fixed — `canon_dir` walks to the nearest existing ancestor | G6, G2–G4 | M4a, M4b |
| C6-i | `alerted_no_session` had no clearing site, so the first missing-id alert was the last one that record could ever send | fixed — cleared on the poll the id arrives | BU | A1 |
| C6-ii | the `fsdegraded` clear ran `rec_clear` -> `rec_read` -> `fs_get` and clobbered `FS_VAL` before the probe value was consumed | fixed — consume, then clear | BD | A2a |
| C6-iii | the watch-liveness marker had no clearing site, and the episode was decided INSIDE the alive arm, so the dead-watcher path skipped it | fixed — decided above the branch; a re-arm that works also ends the failure episode | BW | A4a–A4c |
| L6 | the retry budget was spent on POLLS, not on delivery attempts | fixed — see below | BX, BY | L6a, L6b |

Two more defects were found while fixing, and are recorded as ours rather than the reviewer's:

- **A2b** — one `alerted_fsdegraded` key was doing duty for two different degraded conditions (an
  unreadable transcript and an unreadable heartbeat), so recovering from one silenced the other.
  Split into `beatdegraded`; case AT, with BT (the transcript half) as its anchor — without that
  anchor a guard that simply stopped alerting on either condition would have passed.
- **A3** — `alerted_leasedegraded` was flat-keyed rather than keyed to the generation, so the first
  watcher that could not publish a lease silenced every later watcher on that record forever.
  Case BV.

### L6 in full, because it stayed open longest

`watch_once` reaches the terminal alert only on a poll whose `claude agents --json` SUCCEEDED, but
the loop charged its ten-retry budget on every poll that merely saw the terminal FACT. A degraded
agent query therefore burned all ten retries **without calling the notifier once**, and the watcher
exited having written `alert_undelivered` after a SINGLE real attempt — reporting "nobody could be
told" without having tried, which is the same silent finish the retry exists to prevent.

The fix gives the terminal alert ONE author, `alert_finished`, reached from `watch_once` on the poll
that observes the finish and from `watch_loop` on every later poll while the marker is absent.
`alert_once` now reports what it actually did in `ALERT_RESULT` — `delivered`, `failed`, `skipped`,
one word per outcome — and only `failed` spends budget: a stand-down (another claimant is delivering
this very alert) is not our failure and is not helped by giving up sooner.
HOW it finished travels with the fact as `finished_<gen>_how`, so a retry with no successful agent
query left still produces the SAME sentence as the first attempt rather than a different one.

Two cases pin it, and they pin opposite halves. **BX** records the terminal fact through one real
`--watch-once` poll with the notifier failing, then kills the agent query and asserts the give-up
arrives only after **ten** delivery attempts (it was 1). **BY** holds the alert's own `flock` from
the test for the whole case, so every attempt stands down, and asserts that fifteen polls later
there is still no `alert_undelivered` and the watcher is still running.

### Mutation ledger — 14 mutations, 14 KILLED, 0 survivors

Per ITEM, each anchor-checked before the run (0 anchor problems), so a mutation that failed to apply
could not be scored as "survived":
M1->BR, M2->BS, M3->G5, M4a->G6, M4b->G2/G3/G4, A1->BU, A2a->BD, A2b->AT, A3->BV,
A4a/A4b/A4c->BW, L6a->BX, L6b->BY.

`tests/handoff.test.sh` gains **BR** (an unreadable symlink refuses), **BS** (an unreadable identity
at the boundary refuses), **BT**/**AT** (the two degraded conditions alert independently), **BU**
(the missing-id episode ends when the id arrives), **BV** (two generations each report an
unpublishable lease), **BW** (the liveness episode ends on the dead-watcher path too, and a working
re-arm ends the re-arm failure episode), **BX** and **BY** (the retry budget), and
`tests/install-guards.test.sh` gains **G5** (CR) and **G6** (a not-yet-created directory reached two
ways).

### Two claims from this round corrected in place

- *"C4 reproduced by `repro/m2.sh`"* — it was not. That probe's shim compared the full pathname the
  test spelled (`/var/...`) against the one the script had already resolved (`/private/var/...`), so
  it never fired and the run proved nothing either way. The finding stands on `m2b.sh`, which
  matches by basename and does reproduce it. **A repro that cannot fail is not a repro** — the same
  shape as round 3's M4.
- *"all four mediums fixed as one class"* — overstated. Three of them (C6-i/ii/iii) genuinely are one
  class, *an alert marker with no end to its episode*, and were closed together. **L6 is not in that
  class**, and it was still open when the claim was written.

### Still open on this branch

- Nothing blocking. The branch is not merged or pushed: that is the user's call and she has not been asked.


## Review dispositions — Codex diff round 5 (three parallel lenses, `-p terrax`)

BASE `d88adc6692db23c460318bc501e831a6d877de61`.
Round 5's findings were taken in three shapes rather than as eighteen separate patches, because they are not eighteen problems:

| Shape | The claim the code was making | Findings |
| --- | --- | --- |
| A | *a degraded observation may not become a value* | correctness #1/#2/#5, lifecycle #12 |
| B | *a control that cannot fail is not a control*, applied to the WAIT | lifecycle #4, correctness #6 |
| C | *an episode is a predicate over a transition, not a flag someone remembered to clear* | lifecycle #6/#7, correctness #9 |

Shape A landed first because the other two rest on it: a watcher cannot reason about an episode it mis-observed, nor usefully bound a probe whose failure it then reads as an answer.
Its single load-bearing edit is `row_present`'s **tri-state** — it answered *present* or *not present*, so a hung `node`, a killed probe and a genuinely missing registry row were one answer, and the one meaning *I could not look* was the input to marking a successor dead. It now answers **0 present · 3 absent · 2 unknown**, and every caller has a third arm.

### Shape B — every unbounded command under a held claim is now bounded

Two routes, chosen by what the caller reads: `fs_get` when the answer is a **value** (returned in a global, so no `$( )` fork at all), and `timed_to_file … /dev/null` when the answer is an **exit code**.

The behavioural claim is pinned end-to-end by case **BT**: a `stat` shim that sleeps 30s with `CLAUDE_HANDOFF_FS_TIMEOUT=1` must produce a *degraded* report, not a frozen poll — and four polls in a row pin the whole episode (alert once, stay silent, clear on recovery, alert again on the next outage).

### `_FS_FILE` — a property `mktemp` was buying, spent without noticing

Shape B replaced a per-call `mktemp` with one fixed `$TMPDIR/handoff-fs.$$.<n>` per process.
That removed a real bug: the old per-call `rm -f` ran in the **parent**, outside every deadline, so a hung TMPDIR killed the probe on time and then blocked the caller forever on the very next line — the bound the function exists to provide, undone by its own cleanup.

But a fixed name is a **predictable** name, and `>` follows symlinks. On a shared `/tmp`, another user who creates that name first as a link has the link's *target* truncated by a probe that only meant to read something.

The file is now created under `set -C` — noclobber is `O_EXCL|O_CREAT`, which refuses an existing file **and** refuses a symlink — and the suffix walks when the name is taken.
A second branch tells our own leftover from a reused pid apart from a squatted name using `[ ! -h ]` (which does not follow the link) plus `[ -f ]` and `[ -O ]`; without it a long-lived box would walk the suffix and eventually degrade.
Both branches go through `timed_to_file … /dev/null`, because they are the process's *first* filesystem operations and would otherwise run unbounded in the parent — the same shape as the old `rm`, moved from the end of every call to the start of the first one.

Pinned by case **CT**, end to end. The hook's pid is not knowable before launch, so a wrapper publishes its own `$$` and `exec`s the hook — `exec` keeps the pid, so the name the test squats is the name the hook will actually try. (`$BASHPID` is the obvious way to do this from a subshell and is empty in bash 3.2, which is `/bin/bash` on this machine.) Three runs: an unsquatted control, the squat, and a **negative control** with noclobber removed, which clobbers the canary — so the squat assertion is load-bearing rather than merely green.

### Recurring-class enumerations (counts, not instances)

**The spawn-site list went wrong in both directions.** Re-deriving the census to restate one count found four defects in the file's own bookkeeping:

| Defect | What the list said | What was true |
| --- | --- | --- |
| Stale probe constant | `SPAWN_SUBSHELLS=37` | **19** — shape B removed forks, so the number moved *down*. A count that only ever ratchets up is not being read. |
| Headline over a longer body | `CLOSES THE DESCRIPTORS (10)` | 12 entries followed it |
| Retired number still live | site 12 = `fs_get`'s per-call `rm` | deleted in batch 4. The number is **not reissued**: a later diff reading `SPAWN SITE 12` would otherwise mean two different things depending on which version of the list you read it against. |
| Marker lost under an edit | `lookup` marked | batch 4 moved the `node` call into a helper and left the marker behind, so the list described four call sites in a file with five |

The list is now a parsed contract rather than prose: `SPAWN-LIST-BEGIN`/`END`, **one entry per line** (the two-column version hid sites 5 and 7 from every line-oriented reader — the same way it went stale), numbers checked to be `1..N` with no gap or repeat, and the headline count checked against the parsed length.

**Presence is not coverage where one entry stands for several places.** Site 7 is marked in five callers, so a per-number *presence* check passes when four of the five survive — it cannot catch the regression that prompted it. The list therefore declares its multiplicity (`at 5 call sites`) and the test asserts the count. Control C3 reproduces the batch-4 loss exactly: `FAIL[CM]: the list says site 7 is marked at 5 place(s); the code marks it at 4`.

**The other half of the coverage question: stray tags.** An *untagged* site is loud — `UNTAGGED`, floored at 0. A tag whose site moved out from under it is *silent*: the population simply comes back one smaller, indistinguishable from a site legitimately deleted. `claim-census.js` now reports `stray-TAGS` — every `# CLAIM:` no primitive site consumed — and exits 2 on one.

**Nine inline hang guards, three-way classified.** The first full-suite run on shape B reported `FAIL[AI]: the watch loop did not exit on the durable finished fact`. The record carried `finished=1`; the process had been SIGKILLed by the test's own `sleep 20` while working normally. **Measured rather than assumed**, since the leading hypothesis was a shape-B fork-cost regression: the case takes **13s on shape B and 15s on shape A** — shape B is *faster*, and the hypothesis was wrong.

- **6** guards (AY, BL, BL2, BM, BX, CA) arm *after* an `await_rec` on the very fact that ends the loop — the process is already leaving and the guard is a formality.
- **3** (AI, CB, CD) arm immediately after launch, so the guard races the real duration; all three are paced by the same `ALERT_RETRY_MAX` budget.

Those three now take a guard **derived from the hook by value** (`ALERT_RETRY_MAX × 8 + 30`), so raising the retry budget cannot quietly turn any of them back into a flake, and AI's failure message prints the elapsed time so a future firing is diagnosable instead of mysterious. A guard set at 1.3× the real duration does not report a slow test — it reports a **correctness** verdict about code that was correct.

The same stale-constant shape existed one level up in the tests: CS's three population controls asserted the literals `57`/`58`. What they actually claim is a **delta** — (a) adds one site, (d) and (g) add none — so they now derive the baseline from a census run.

### Census after shape B

`closure: 57 functions · population: 59 primitive sites · a: 29 · b: 13 · c: 4 · d: 13`, exit 0.
The four tags are **properties, not batches**: `a` bounded (runs inside `timed_to_file`'s deadline-killed child) · `b` no blocking operation of its own · `c` bounded by construction · `d` unbounded **and named**, with the reason in the source beside the tag.

### The mutation ledger — 9 of 10, and what the tenth cost

Shape B was checked by ten mutations run serially against the full suite (`mut-shapeB.log`).
Nine were killed, each by the case that claims the thing: CS for the census and its bookkeeping, BT for the bounded heartbeat stat, AI for the derived hang guard, CT for both halves of the `_FS_FILE` hardening.
The AI kill is worth quoting because it is the fix reporting itself — *"the watch loop ran 5s without exiting on the durable finished fact, and hit the 5s hang guard"* — where the same failure a day earlier said only that the loop did not exit.

**One survived, and it was one of ours.** Narrowing the census's filetest character class back to `-[rfdLsxew]`, undoing the widening that batch 3 added for `-h` and `-O`, changed nothing any assertion could see.
The cause is in the census, not in the suite: it records **one row per line**, not per occurrence (`rows.push({ line: n, … })`).
The single line that motivated the widening — `[ ! -h "$1" ] && [ -f "$1" ] && [ -O "$1" ]` — still matches on `-f` under the narrow class, so both censuses print byte-identical output on the real hook.
That is *a control that cannot fail is not a control* again, and the first time in this loop that the uncontrolled thing was a control's own **input** rather than a guard.

The cure is control **(h)**, an enumeration with a denominator in both directions: nineteen filesystem-touching operators must each ENTER the population on a line where it is the only primitive, five non-filesystem tests (`-z -n -o -t -v`) must stay out, and `$csh_n = 19` asserts the denominator itself so the enumeration cannot quietly shrink.
The operator list is a **literal, deliberately not derived from the census** — deriving it would shrink along with the census and the control would pass again, which is precisely the failure being fixed. It is a specification; the census is the implementation measured against it.
It was proven able to fail before it was believed: against the narrowed census it emits twelve `FAIL[CS]` lines beginning *"the census filetest class is 'rfdLsxew' but the filesystem-touching operators are '…' — one of the two moved"*; against the real census it is silent.

### A flake that was a defect: fencing a read on the fact it reads

One mutation run carried a `FAIL[BL]` that appeared in no other — the kind of thing a ledger records as load and moves on from.
It is a test defect, and reading the two write sites is enough to see it: the hook writes `rec_put "$REC" "alert_undelivered_$FIN_KEY"` and then, on the next line, `logline HandoffAlertUndelivered`.
BL awaited the **record** and immediately read the **event log** — awaiting fact X as evidence for fact Y. Two adjacent writes are still two writes, and under the load of a mutation run the gap between them opened.

Enumerated rather than patched. Of the **15** event-log assertions in the suite:

| Fencing | Count |
| --- | --- |
| the writing process has EXITED (`wait`, foreground, or a drain loop) | 11 |
| awaits the asserted log line itself | 2 |
| fenced on a NEIGHBOURING fact | 2 — **BJ** and **BL** |

Both are fixed with the discipline each one's own situation allows.
BL's log read moves **behind `wait "$bl2p"`**, which is what all four sibling give-up cases (BX, CA, CB, CD) already did.
BJ's watcher keeps running by design — that is the case's whole point — so there is no exit to fence on; it now **awaits the log line**.
BJ was not failing, and that is the more interesting half: it was safe only because the hook happens to write the log line *before* the record there, the opposite order to BL's, with nothing pinning either. A case whose correctness depends on which of two adjacent lines in the code under test runs first is a flake that has not happened yet.
The rule is written on `await_rec` itself, the helper whose misuse produces it.

These two are **flake fixes, not new assertions, and they are not mutation-verified** — the mutation that would discriminate the old code from the new is "make the machine slower", which is not a mutation. What was verified is that BJ's new wait can fail: deleting the `logline` call makes it report, with its own message, rather than time out silently.

### Still open on this branch

- **The launcher runs unbounded under the dispatch claim** (`hooks/handoff.sh`, the `CLAUDE_BIN` command substitution, tagged `CLAIM:d`). If `claude --bg` starts a successor and then hangs, the record stays at `state=launching`, no watcher is armed, and the claim is held for as long as the hang lasts, so every later dispatch for that handoff refuses. A ceiling is coherent — expiry maps onto the existing `state=unknown` + `bg_here` path — but choosing it wrong turns a slow cold start into a false "may be running", and the alternative to refusing is a SECOND successor, which is invariant #1. **Proposed 600s; the decision is the user's.** This entry is what the tag's word "filed" refers to — round 6 found it referred to nothing.
- **The alert fence is deliberately open during the re-dispatch truncation window.** `gen_is_ours` treats an *empty* `watch_gen` as ours, because that is the window between a `--force` re-dispatch truncating the record and the replacement watcher arming — a watcher that stood down there would stand down against a generation that does not exist yet. A stale notifier returning inside that window can still land a flat `alerted_*` in the new generation's record. Closing it would require `dispatch` to take the alert claim, which lets a wedged notifier block a re-dispatch — a worse failure. The *unreadable* half of the same fence was NOT a trade-off and was fixed in round 6: a record that could not be read no longer authorises a durable suppression marker.
- **`install.sh`'s backup selection is check-then-act across processes** (`backup_if_real`). Two deliberate concurrent manual installs can both choose `.bak-1`, and the second `mv` then destroys the user's original. Byte-identical since before this branch and nothing auto-invokes the installer, so it is recorded rather than fixed here.
- The suite is now **~7 minutes** per run, so a ten-mutation set is ~70. That is the real reason mutations run serially: the two documented false failures in this loop both came from a concurrent second workload.

## Review dispositions — Codex diff round 6 (three parallel lenses, `-p sol`)

Range `d88adc66..ab92448`, three lenses dispatched concurrently (correctness · lifecycle/ownership ·
test-quality), each pinned to those SHAs and each verified against `git diff --name-only` before its
findings were read.
`verdict` was ignored and `findings` adjudicated: every correctness/lifecycle finding was reproduced
end-to-end before it was acted on, and every test finding had to produce a mutant that survives
today's suite or it was rejected.
**17 reported, 15 accepted, 2 rejected, 3 HIGHs accepted** — not only-LOWs and not flat, so the
region was reviewed again rather than rewritten.
The full scorecard, with each reproduction's control/mutant transcript, is
`.review-rounds/round6/SCORECARD.md`.

### The one rule this round turned on

**A degraded observation may not become a value.**
Six of the round's findings are the same sentence at six sites: a probe that did not run, a read that
timed out, a clock that would not answer and a directory that could not be listed each arrived at a
decision spelled as a fact.
The cures are all the same shape — a tri-state return the caller must look at, never an in-band
empty string:

| site | what a failure used to become | now |
| --- | --- | --- |
| `gen_is_ours` (C1) | "this generation is ours", authorising a durable suppression marker | `gen_may_write` requires a POSITIVE ownership observation; delivery still fails open |
| `rec_num` (C2) | an age of **zero**, i.e. a ten-hour-silent successor reported healthy | `0 = observed ('' = no usable number)`, `2 = could not read` |
| `dispatch`'s clock (C3) | `dispatched_at=` and `dispatched_epoch=0`, read 56 years later as an age | both keys are ABSENT and `dispatch_clock_lost=1` says why |
| `file_exists` (C4) | EACCES reported as "the file is not there" | `path_state` via `perl`, errno-aware: `0` present, `1` ABSENT, `2` could not look |
| `rec_read session_uuid` (micro-review) | an empty uuid, so the second presence probe was skipped and "absent" became FINISHED | the skipped probe is `_rpu=1`, i.e. "not observed" |
| `rec_read handoff` (micro-review) | neither a beat nor a failure, so a standing DEGRADED marker was CLEARED | an unreadable record sets `FSFAIL=1` |
| `transcript_for` (micro-review) | an unlistable projects directory reported as "no transcript" | `opendir` separates ENOENT from every other errno; non-ENOENT returns 2 |
| the five marker stamps (micro-review) | `monitoring_expired=`, a marker present and dated to nothing | `rec_stamp` writes `clock-unavailable` and logs `HandoffClockLostAtMarker` |

### The class this round enumerated: self-referential claims

Four findings (a census whose token list could not match the site it was supposed to police, a doc
sentence calling built work unbuilt, a key census claiming 15 keys where there were 17, and a
`--help` header describing a locking mechanism retired two rounds earlier) are one class: **a claim
the source makes about itself that a `grep` could check.**
Per the standing rule the class was enumerated with a denominator rather than patched where reported
— 8 such claims in the tree, 3 pinned by a test and all 3 accurate, 5 unpinned and 4 of those wrong.
Whether a test pins the claim predicts whether it is still true, so the cure was to pin the unpinned
ones: case **DG** derives the alert-key census (18 keys across 19 arming sites) from the source
instead of remembering it, case **DJ** drives every `handoff.sh --<flag>` string printed by the hook
or by this document through the REAL parser, and case **DA** now asserts the printed-command census
PER TOKEN rather than as a total a cross-token trade can hold.

### Micro-review of the round-6 fix diff — 6 findings, 6 accepted (one in part)

The counter-party review of the fix diff itself, before the next full panel, per the standing rule
that whoever wrote a range never reviews it.
It found more than the panel did, and all four product findings are the round's own rule at sites the
round had just walked past:

- **MR-1 (medium, test):** case DI proved the dry-run's quoting with operands that contain nothing to
  quote, so `SHQ_BIN` and `SHQ_PMODE` could be built raw and DI would still pass.
  Reproduced: two whole-file mutants, both PASS on the pristine fixture.
  DI now runs with a launcher path containing a space and a semicolon (`di bin/cl;aude`) and a
  `--permission-mode` carrying `; touch …`, asserts the printed argv line by line, and carries an
  unquoted-launcher control that must NOT be written.
- **MR-2 (medium, test):** case BU extracted its expected message from the very product line a
  mutation would edit, so the assertion moved with the mutant.
  Reproduced: mutant PASS.
  BU now also drives the flag it finds inside the delivered message through the real parser, and its
  comment says exactly what the equality does and does not prove.
- **MR-3 (high, product):** two `rec_read … || true` sites — `session_uuid` and `handoff` — where an
  unreadable record became a terminal `finished` and a cleared `beatdegraded` marker respectively.
  Pinned by new cases **DK** and **DL**.
- **MR-4 (high, product, accepted in part):** `transcript_for` returned 0 unconditionally, so an
  unlistable projects directory was reported as a clean absence.
  The reviewer's second claim — that the function's comment was false — was a misreading of a
  subjunctive sentence and is rejected; the defect is real and is fixed, and the contract is now
  stated on the function.
  Pinned by new case **DM**.
- **MR-5 (medium, product):** scoping the stand-down keys by `$WATCH_GEN` alone left the original flat-key
  defect standing for the bare `--watch <record>` mode this document advertises.
  The class is exactly three keys: two now carry `<generation-or-pid>`, and `leasedegraded_<gen>` is
  unreachable without a generation because the lease is only taken inside `[ -n "$WATCH_GEN" ]`.
  Pinned by case **DF**, which now runs two bare watchers and asserts two DISTINCT
  `clocklost_pid<pid>r<n>x<n>x<n>` keys plus the absence of the flat one.
  The scope carries a per-watcher nonce as well as the pid, because these two markers have no
  clearing edge by design and a pid is reissued; case **DO** arranges that reuse and is the pin for
  it.
- **MR-6 (medium, product):** five marker writes were `now_utc` on one line and `rec_put` on the next,
  so a failed clock stored a present-but-blank marker — and the `now_utc` header comment had declared
  the class closed while all five were still open.
  Enumeration closed at 7 consumers as they stood before the fix: 1 dispatch (C3), 5 markers,
  1 informational — and folding the five into `rec_stamp` leaves 3 consumers of `$NOW_UTC` in the
  source.
  **"Pinned by new case DN" was OVERSTATED**, and is corrected here.
  DN pins the SENTINEL, at one marker (`monitoring_expired`), under a broken clock.
  It says nothing about the other four markers still going through the helper: reverting any one of
  them to the two-line form it came from reintroduces the blank-timestamp defect at that site and
  the whole suite stays green, which was built as a whole-file mutant and run (round 6 micro-review
  2).
  The consolidation is pinned by new case **DP**, which censuses every `$NOW_UTC` consumer in the
  hook, classifies each as `stamp`, `guarded` or `annotation`, and names the file and line of
  anything that is a fourth thing.

Each of DK, DL, DM and DN carries its own in-case mutant control, and each was additionally run
against a whole-file copy of the hook with its fix reverted: all four go RED on the primary
assertion, not merely on the "mutant is identical" guard.

MR-5's fix then broke the census that polices this class, and the suite — not a reviewer — caught it.
Renaming the alert-key heading from `GENERATION-SCOPED` to `WATCHER-SCOPED` in the hook orphaned case
DG's parser of that heading, so three of its lists and counts silently compared against an empty
parse and reported the drift as `expected '2' got ''`.
DG now derives the class from either scope suffix (`$WATCH_GEN` or `$_fk_scope`), and asserts each
class heading EXISTS before parsing it, so a future rename fails by name instead of by empty string.
Two stale prose claims went with it: the `EXP_KEY` header and the `leasedegraded` comment both still
called the stand-down keys generation-scoped.

### Review dispositions — micro-review 2 (the round-6 fix delta)

The counter-party reviewed the 887-line delta that closed MR-1 to MR-6 and returned five findings.
All five were accepted; each was reproduced or mutation-verified before it was acted on.

- **MR2-1 (high, product):** `now_utc` treated a non-empty `date` as a success.
  Its body was `NOW_UTC="$(date …)"; [ -n "$NOW_UTC" ]`, so a `date` that printed a partial line and
  then failed passed the emptiness test and `rec_stamp` stored that garbage as a time.
  Reproduced with a shim that prints `partial` and exits 1: `rc=0`, `NOW_UTC=partial`.
  Fixed by checking the child's exit status AND the timestamp's shape, and both arms were re-run.
- **MR2-2 (medium, product):** the stand-down keys' watcher scope was `pid$$`, which is not a durable
  identity.
  `clocklost_<scope>` and `expired_<scope>` have no clearing edge, so a later bare watcher that drew a
  dead predecessor's pid read the predecessor's marker and stood down silently — the flat-key defect
  returning through pid reuse.
  A per-process nonce is appended (`$RANDOM` is a bash builtin: no fork, nothing to time out).
  Pinned by new case **DO**, which arranges the collision by writing the marker under the live
  watcher's own pid, and whose nonce-less control goes RED on the primary assertion.
  **Corrected in micro-review 3, and the original claim was overstated:** the nonce was written
  `$RANDOM$RANDOM` and the comment beside it said reuse "cannot make two watchers share a key".
  Concatenation without a separator is not injective — (1,23) and (12,3) both spell `123` — and no
  finite nonce can promise uniqueness anyway.
  It is now `${RANDOM}x${RANDOM}x${RANDOM}`: the separators make distinct draws distinct keys, the
  third draw puts a same-pid collision at about 1 in 3.5e13, and the guarantee is stated as
  probabilistic.
- **MR2-3 (medium, test):** case BU checked only that the parser did not reject the recovery command
  the alert names.
  Renaming that command to one that is accepted but answers a different question left BU and DJ both
  green while handing an operator a usage header instead of the successor's state.
  BU now RUNS the command out of the delivered text and requires its output to name the session the
  alert is about; the mutant is killed on that assertion.
- **MR2-4 (medium, test):** the `rec_stamp` consolidation was unpinned — see the correction to MR-6
  above.
  Closed by new case **DP**.
- **MR2-5 (low, product):** eleven degraded messages named a cause they had not observed.
  `fs_get` collapses every failure into 2 for the caller, which is deliberate, but all eleven human
  messages said "timed out", and the probes have a second failure mode: `path_state`, `file_exists`,
  `mtime_of` and `transcript_for` return 2 when the OS answered with an error rather than a value.
  An operator told a mount is slow waits; an operator told the read was refused fixes a permission.
  `fs_get` now derives the cause from `timed_to_file`'s raw status and publishes it as a phrase the
  messages interpolate.
  17 sites interpolate it, and case **DR** asserts that number against the hook rather than trusting
  this line: it was written as "Ten sites use it" and was still saying ten at sixteen, which is the
  second count in this document to go stale while reading as evidence (round 6 micro-review 5; the
  first was the `rec_stamp` consumer count, now derived by case DP).
  **Corrected in micro-review 4, and the `refused` wording was overstated in the same way:** it read
  "the probe refused the read (status 2) rather than answering", which names a refusal where the
  status says only that the probed function returned non-zero — `fs_get` collapses EVERY non-zero
  from the probe into 2, so a missing helper, an I/O error and a permission denial arrive
  indistinguishably.
  It now reads "the probe answered \"I could not look\" (status <n>) instead of returning a value —
  that is the one status it has for every way the look can fail to happen, from a permission or I/O
  error to a helper it could not run".
  **Corrected in micro-review 3, and the original claim was overstated:** this said 128+N "is the
  deadline's own kill", and the phrase it produced was "the filesystem did not answer within Ns".
  128+N says only that the child was SIGNALLED — a probe killed from outside (an OOM kill, a
  supervisor terminating the process group, a stray TERM) arrives with the same status having
  returned instantly, reproduced with a probe exiting 143 under a 5s bound and reported as "did not
  answer within 5s" after 0s.
  The tri-state's own invariant applies to itself, so the value is now `killed`.
  **Corrected again in micro-review 4, and the micro-review-3 replacement was itself overstated:**
  that replacement read "the bounded read was killed before it answered — either the Ns bound expired
  or the probe was signalled from outside", and "was killed" is still a cause nobody observed.
  A shell reports `128+N` for a signalled child and for a child that RETURNED `128+N` itself, and a
  probe that exits 143 voluntarily is not killed by anything; reproduced with a probe running
  `exit 143` under a 5s bound, reported as "was killed" after 0s.
  The phrase now reads "the bounded read produced no value and the probe ended with status <n> under
  a <b>s bound — a status in that range means the probe was signalled or returned that number itself,
  and nothing here can tell those apart".
  The value is spelled `killed` rather than the obvious `timeout` because the claim census audits the
  decoded hook for bare command names, and a `case` label spelled `timeout)` is indistinguishable
  from a fork to that scan; the audit was left blunt rather than taught to skip `case` labels,
  because its over-inclusiveness is the property being bought.
  `fs_why_set` itself joins the claim closure — `fs_get` calls it while a claim descriptor may be
  held — and was admitted there deliberately: it performs no I/O at all, so the census totals were
  unchanged at 63 sites while its membership grew by one.
  (The population is **64** as of micro-review 5, which added one `b` site: `verify_lock`'s probe of
  its own descriptor, a redirection that writes no bytes.
  Case CS asserts the number, so this sentence cannot be the thing that goes stale.)
  The eleventh, `beatdegraded`, deliberately does not: `FSFAIL` is a running OR over up to four
  probes, so the phrase there would describe whichever ran last rather than one that failed, and that
  message states only what is known.
  Pinned by case **DM**, whose fixture is unlistable rather than slow: it now asserts the refusal
  wording and the absence of the timeout wording, with an all-killed mutant as its control.

### Review dispositions — micro-review 3 (the micro-review-2 fix delta)

Four findings, four accepted, none rejected, no HIGHs.
All four are in fixes written earlier in the same round, which is the second consecutive
micro-review for which that is true.

- **MR3-1 (medium, test):** `now_utc`'s two refusal arms were unpinned, and the fix that added them
  was carried by a case that cannot see either.
  The suite's only ISO-clock fixture (case DN) exits 1 printing NOTHING, which the ORIGINAL body —
  `NOW_UTC="$(date …)"; [ -n "$NOW_UTC" ]` — also refuses on its emptiness test.
  Confirmed by building the whole-file revert and running the suite: `PASS: handoff`, rc 0.
  Closed by new case **DQ**, which needs a fixture per arm because each arm is only reachable where
  the ones before it do not already refuse — A answers with a well-formed time and exits 1, B answers
  `not-a-time` and exits 0 — and by a control per arm that each remove exactly one arm.
  Against a hook with neither arm, DQ goes red on both primary assertions, storing
  `monitoring_expired=1970-01-01T00:00:00Z` and `monitoring_expired=not-a-time`.
  **Extended in micro-review 4:** a third arm and a third fixture, C, answering
  `2026-99-99T99:99:99Z` and exiting 0 — see MR4-4 below.
- **MR3-2 (medium, product):** the tri-state itself named a cause it had not observed — corrected in
  place under MR2-5 above.
- **MR3-3 (low, product):** three messages still spelled `(the filesystem did not answer)` rather
  than interpolating the reason: the `watchunknown` alert, the hard-link guard, and the identity
  re-check at the dispatch boundary.
  Two of the three could not have interpolated `FS_WHY_TXT` even if someone had thought to, and that
  is the more interesting half: `file_nlink` and `file_ident` end in `printf` and so return 0 while
  printing nothing, which reaches the guard as an empty value after a SUCCESSFUL, instant read with
  `FS_WHY_TXT` cleared to the empty string.
  Reproduced with a `stat` shim exiting 1: `fs_get status=0 elapsed=0s _nl0=[] FS_WHY_TXT=[]`.
  `watch_is_alive` now publishes `WATCH_UNKNOWN_WHY` at each of its three set-sites, and the two
  dispatch-path guards derive a reason at their own read site, naming which of the two identity reads
  failed.
  **Corrected in micro-review 4, and the original claim was overstated:** this said the third set-site
  "says the lease file could not be opened".
  That site is reached whenever `lease_probe` SUCCEEDS with a value that is neither `held` nor `free`
  — including the value it prints when the lock backend is unavailable — so the message asserted an
  open failure it had not observed; reproduced under `CLAUDE_HANDOFF_LOCK_DEBUG=broken:8`.
  **Corrected in micro-review 5, and the micro-review-4 correction was itself overstated:** that
  reproduction was written up as a run "where nothing tried to open anything", which is the same
  species of claim it was correcting.
  `lock_hold` opens the lease file (`exec 8>>`) *before* `lock_take` is ever consulted, so the open
  is not merely attempted, it SUCCEEDS and the backend refuses afterwards — re-run to check: with
  the lease path absent beforehand, `fs_get lease_probe` under `broken:8` returns 0 with an empty
  value and the lease file now EXISTS, created by the open the write-up said never happened.
  The same overstatement was still sitting in `lease_probe`'s own trailing comment, which labelled
  its status 2 "could not even open it" when `lock_hold` produces 2 from four places and only one of
  them is the open; both are fixed.
  The two reasons micro-review 3 wrote by hand for the identity guards had the same defect, so all
  three now go through one constructor, `fs_novalue_set`, which states only the shape actually
  observed: the probe ran, returned success and produced no usable value, and nothing here observed
  why.
  Pinned by case **DR**, which censuses the phrase across the whole hook rather than hunting sites,
  because instance-by-instance review found eleven, then three more, then two more inside its own
  fix — see MR4-3 below for what DR became.
- **MR3-4 (low, product):** the watcher nonce was not injective and its comment claimed an absolute
  guarantee — corrected in place under MR2-2 above.

### Review dispositions — micro-review 4 (the micro-review-3 fix delta)

Five findings, five accepted, none rejected, one HIGH.
The HIGH was reported as a medium and upgraded on the reproduction: with a dispatch record that is
writable but unreadable and names a live successor, the hook as it stood at the head of this round
launched a SECOND successor and overwrote the live one's row.
All five are again in fixes written earlier in the same round, which is the third consecutive
micro-review for which that is true — see "the class, and what was done about it" below.

- **MR4-1 (medium, product):** the tri-state's own two phrases named causes nobody observed —
  corrected in place under MR2-5 above.
  `killed` asserted a kill from a status a shell also reports for a voluntary `exit 143`, and
  `refused` asserted a refusal from a status `fs_get` produces for every non-zero the probe can
  return.
  Both now state the observation and enumerate the sources they cannot tell apart, and both take the
  observed status as an argument instead of spelling it into the sentence.
- **MR4-2 (HIGH, product):** `rec_get_raw` was `sed … | tail -1`, and a pipeline's status is its last
  command's.
  `tail` succeeds whatever happened upstream, so the function returned 0 for a record this process
  may not read, and `rec_read`'s documented 2 — "not observed" — was unreachable at the only place
  that can produce it.
  Three guards branch on that return and each names this exact harm in its own comment before
  suffering it: `watch_is_alive` ("an unreadable record is not 'no watcher'"), `watch_once`, and the
  dispatch pre-flight ("a record that cannot be read cannot rule out a live successor").
  `rec_get_raw` now recovers `sed`'s own status from `PIPESTATUS[0]` and, on a non-zero, asks
  `path_state` whether the file is merely absent (still 0, an empty record is a real observation)
  or unreadable (2).
  Pinned by new case **DS**, whose fixture is a mode-222 record naming a live successor and whose
  control is the masking one-liner restored: the mutant does not refuse, overwrites the live row and
  spawns.
- **MR4-3 (medium, product):** the fix for MR3-3 introduced two more messages of the class it was
  closing, and a third pre-existing one survived it.
  All three are the same shape — a probe that returns SUCCESS and prints nothing — and there is now
  exactly one constructor for it, `fs_novalue_set`, with no hand-written cause prose at any site.
  Case **DR** was rewritten from a phrase census into a shape census with a denominator: it counts
  the sites that ASSIGN a degraded reason (13) and requires every one of them to derive it from
  `FS_WHY_TXT` or `FS_NOVALUE_TXT`, so a fourteenth hand-written reason fails the case rather than
  waiting for a fifth reviewer.
  Its own presence/filter behaviour is driven against a four-line fixture, and it carries a control
  that must NOT be caught.
- **MR4-4 (medium, product):** `now_utc`'s shape check was the whole test of the value, so
  `2026-99-99T99:99:99Z` — digits in every position it counts — passed as a successful timestamp with
  no clock-lost marker beside it.
  The ranges are now checked as well, in a one-line helper (`_nu_in_range`) so that a shape control
  and a range control can each remove exactly one arm.
  Pinned by DQ's new arm C and its control; the control stores month 99 in the record.
- **MR4-5 (low, test):** case DO's comment said DF's two bare watchers are CONCURRENT and that DF is
  therefore structurally blind to pid reuse.
  They are sequential — `df_bare` runs each watcher inside a command substitution — so DF's blindness
  is nondeterministic rather than structural, which is a weaker claim and the honest one.
  Corrected in place; DO itself is unchanged, because arranging the recycled pid deterministically is
  still the only way to pin it.

**The class, and what was done about it.**
"A degraded observation may not name a cause it did not observe" has now produced findings in three
consecutive micro-reviews — eleven sites in MR2, three in MR3, and in MR4 both arms of the tri-state
plus the two messages MR3's own fix had just written.
Two rounds of instance patching were each falsified by the next round, which is the signal to stop
patching instances.
The response was therefore a rewrite of the region rather than a fourth pass: two constructors own
every degraded phrase in the hook, no site spells a cause of its own, and DR enforces that
structurally with a counted denominator instead of a phrase list.

### Review dispositions — micro-review 5 (the micro-review-4 fix delta)

Seven findings, seven accepted, none rejected, no HIGH.
Every one of the seven is in a fix micro-review 4 had just written, which is the fourth consecutive
micro-review for which that is true.
Two of them are corrections of a CORRECTION: micro-review 4 had labelled a passage here "the
original claim was overstated", and micro-review 5 showed the replacement was overstated too.

- **MR5-1 (medium, test):** case DQ's arm C used a fixture wrong in every field
  (`2026-99-99T99:99:99Z`), so any ONE of `_nu_in_range`'s five conjuncts refuted it and the other
  four were pinned by nothing — proved with a hook keeping only the month check, which PASSED the
  case.
  DQ now drives five one-field-wrong fixtures, each asserted refused, plus the two acceptances the
  comment's calendar argument turns on and nothing had tested: the leap second `2026-06-30T23:59:60Z`
  and the floor `2026-01-01T00:00:00Z`, both asserted stored.
  A structural census of the five conjuncts sits on top, so a sixth field cannot be added and
  validated nowhere.
- **MR5-2 and MR5-3 (medium, test):** case DR's assignment census exempted any value CONTAINING a
  constructor token, which a hand-written cause satisfies by appending one, and it knew only five
  variable names, which a sixth defeats by existing.
  The census now works by naming convention — every assignment to a variable whose name ends in
  `WHY`/`why` — with an exact denominator, a reviewed NAME set and a reviewed VALUE inventory.
  The inventory is the part that answers MR5-2: no filter can distinguish a value that came from a
  constructor from one that came from a person with a constructor stapled to it, so the written-out
  values are enumerated and reviewed, and the case says in its failure message that changing the
  inventory is a review decision rather than an edit.
- **MR5-4 (medium, product):** `verify_lock` read a STATUS as a CAUSE.
  It re-takes the dispatch lock to prove the hook still holds it, and it was one line —
  `lock_take 9 || die "the dispatch lock's descriptor is no longer open …"` — so EVERY non-zero
  status was reported to the operator as a closed descriptor.
  (**This sentence is itself a correction, made in micro-review 6.** It previously said status 1 was
  reported as a closed descriptor "and every other status as a backend failure", which describes
  neither the old code nor the new: the old code had one message for all of them, and the fix is what
  introduced a second.
  `lock_take` answers 1 for EWOULDBLOCK and 3 for every other way the question could not be answered,
  only one of which is a closed descriptor.)
  Reproduced with `CLAUDE_HANDOFF_LOCK_DEBUG=broken:9` while the descriptor was provably still open:
  the hook told the operator its descriptor was gone, sending them after a leak that does not exist.
  `verify_lock` now OBSERVES the descriptor (`( true >&9 ) 2>/dev/null` — a duplication in a subshell
  that writes nothing and cannot block) and reports the observation separately from the status.
  Pinned by new case **DT** with its `if false` control, and case **AG** was tightened to assert the
  ABSENCE of the other arm's phrase, because one message naming both causes would have satisfied
  either case.
- **MR5-5 (medium, test):** case DS took its spawn-count baseline after the fixed run had already
  run, so a successor spawned by the fixed run was inside the baseline — proved with a mutant that
  spawns immediately before the record read and left DS green.
  The baseline is now taken first, the fixed run is separately asserted to spawn nothing, and the
  spawn-before-the-read mutant is a second control.
- **MR5-6 (low, doc):** the `broken:8` account here said nothing tried to open anything.
  It is not true: `lock_hold` opens the lease with `exec 8>>` BEFORE `lock_take` is consulted, and
  under `broken:8` that open SUCCEEDS — the lease file exists on disk afterwards, which is how the
  claim was falsified.
  Corrected below, and in `lease_probe`'s own trailing comment, which carried the same overstatement.
- **MR5-7 (low, doc):** "Ten sites use it", of `$FS_WHY_TXT`, was wrong by six.
  This page no longer states the number on its own authority — it says case DR asserts the count
  against the hook, and DR does, extracting the figure from this page and comparing it.
  (**Corrected in micro-review 6:** this sentence originally credited the case with "a control that
  doctors it", and there was no such control — only a guard that fails loudly if the page cannot be
  read at all.
  A comparison of two numbers proves nothing until a run in which they DISAGREE has been shown to
  fail, so the control was written, and now the sentence is true.)

**The class, and what was done about it.**
Micro-reviews 2–4 were dominated by one product class, "a degraded observation may not name a cause
it did not observe", answered by rewriting the observation layer around two constructors.
Micro-review 5 found that class alive at exactly one more site — `verify_lock`, a fence OUTSIDE the
layer the rewrite covered — and otherwise found a different class four times over: **a census or
control that under-covers**, whether by standing one fixture in for five rules, exempting on a
substring, enumerating names that a new name defeats, or measuring a baseline after the event it is
meant to bound.
Each was answered structurally rather than by instance: every affected case now carries a
denominator, extracts its expectation from the product rather than retyping it, and ships a control
proven able to fail.

### Review dispositions — micro-review 6 (the micro-review-5 fix delta)

Seven findings, **seven accepted**, 0 HIGH / 3 MED / 4 LOW — three of them against work micro-review 5 had just landed, and three against this page.
Same shape as before: one lens over the fix delta, every finding reproduced before it was acted on, every test finding required to name a mutant that survives.

- **MR6-1 (medium, test):** DR could not see a hand-written cause assigned *through* the constructors' own output variables.
  It scanned assignment names ending in `why` and exempted the copies out of `FS_WHY_TXT` / `FS_NOVALUE_TXT`, and those two names do not end in `why`, so a line that writes an unobserved cause straight into the operator-facing variable was invisible to it.
  The reviewer's own mutant collided with an existing control's `sed` anchor and made DR red for the wrong reason, so it was rebuilt as a non-colliding one (`FS_WHY_TXT="the mount went away"` inserted before `_ino0why="$FS_WHY_TXT"`) and DR passed on it — the finding is accepted on that reproduction, not on the reviewer's.
  DR now carries a second census, `dr_out_sites`, which inventories every write to those two variables by ENCLOSING FUNCTION and by kind (`clear` vs `text`): 2 `<toplevel>|clear`, 1 `fs_get|clear`, 1 `fs_novalue_set|text`, 3 `fs_why_set|text`.
  Wording changes inside a constructor stay an edit; a write appearing anywhere else is a review decision, and the failure message says so and prints a `diff`.
  The control is the mutant above, which must be reported as `dispatch|text`.

- **MR6-2 (medium, product):** the status-1 arm of `verify_lock` — the fix micro-review 5 had just made — said the backend both answered and could not answer.
  The observation string it built for a still-open descriptor carried an INTERPRETATION inside it ("so it is the lock backend that could not answer"), and status 1 is EWOULDBLOCK, which means the backend *did* answer.
  Reproduced end to end with a `lock_take` that returns 1 while fd 9 is open.
  The observation and the interpretation are now two separate strings: `_vlfd` states only what was measured about this process's descriptor, and each `die` supplies the reading that belongs to its own status.
  Status 1 now says the lock came back held by a DIFFERENT open file description — a deduction from the backend's own answer, since `flock` on a description we already hold returns success.
  Pinned by new case **DV**, which is the first case to enter the EWOULDBLOCK arm at all, with a control that restores the contradiction and must resurrect the phrase "could not answer".

- **MR6-3 (medium, test):** DU's population grep required a literal space after `lock_take`, so a third direct caller separated by a TAB was not counted.
  Reproduced: the tab-caller mutant parsed, read a status into prose, and DU still reported two callers.
  The population is now whitespace-agnostic (`grep -E 'lock_take([[:blank:]]|;|$)'` with comment lines stripped) and the tab caller is a permanent control asserted to census as 3.

- **MR6-4 (low, product-comment):** the `_wr=2` retry comment still described the case as "a transient failure to open the lease".
  `lock_hold` returns 2 from four places, only one of which is a failed open; the comment now says "we could not tell" and names all four, matching the correction micro-review 5 made to `lease_probe`.
  This is the second reported instance of one class — a caller narrating WHICH of `lock_hold`'s four situations produced status 2 — so the class was closed by enumeration rather than by fixing the instance: new case **DW** censuses every direct `lock_hold` caller (four, each pinned to its exact line, whitespace-agnostic like DU) with a tab-separated fifth caller as its control.
  A fifth caller now has to be reviewed instead of discovered by a later round.

- **MR6-5 (low, test-comment):** case CS's explanatory prose still said the totals were 63/33/13/4/13 while its assertions and the live census said 64/33/14/4/13.
  Both blocks rewritten, with the classification argument for the new `b` row (`( true >&9 )` is a descriptor duplication in a subshell: it writes nothing and cannot block).

- **MR6-6 (low, test-comment):** DQ's opening contract still described the removed all-fields-wrong fixture and claimed one control per arm.
  Rewritten to the case as it stands: five one-field-wrong refusals, two boundary acceptances, and the conjunct census, with the month-only surviving mutation recorded as the reason the old shape was replaced.

- **MR6-7 (low, doc):** two claims on THIS page were wrong, and both were mine.
  The micro-review-5 entry described the old `verify_lock` as splitting status 1 from the rest; it did not — it was one line and every non-zero status got the closed-descriptor message.
  And the same entry credited DR's doc-count comparison with "a control that doctors it" when only an unreadable-doc guard existed.
  The first is corrected in place above and labelled as overstated; the second was closed by WRITING the control (`DR_DOC_N + 83`) rather than by softening the sentence, because a comparison of two numbers proves nothing until a run in which they disagree has been shown to fail.
  The same two overstatements were corrected in the round-6 scorecard and the running handoff record.

**What this round says about the region.**
Three of the seven landed on micro-review 5's own delta, which is the second round running where the fix pass is the largest source of findings — the argument for the counter-party micro-review, not against it.
The product class ("a status is not a cause") is now three rounds deep and has moved from the observation layer, to the fence outside it, to the *wording of the fence's own fix*; each step is smaller than the last.
What MR6 changed is the way the class is held: it is now covered by three censuses rather than by having had its instances found — DU over `lock_take`'s callers, **DW** over `lock_hold`'s, and DR over every write to the two operator-facing cause variables.
That is a claim about POPULATIONS, not about correctness: a new site in any of the three stops the suite and asks for a review.
It says nothing about a site that reads some other status, and it does not make the existing wording right — only newly wrong wording at a NEW site cheap to catch.

### Review dispositions — micro-review 7 (the micro-review-6 fix delta)

Three findings, **three accepted**, 0 HIGH / 2 MED / 1 LOW.
Both mediums are the same shape as each other and as the round's long-running class: an enumeration that is narrower than the thing it claims to enumerate.

- **MR7-1 (medium, test):** case DR's new constructor-output census matched `FS_(WHY|NOVALUE)_TXT=`, which is one WRITE SYNTAX rather than every write.
  `printf -v FS_WHY_TXT %s "the mount went away"` writes the variable with no `=` after the name; reproduced as a whole-file mutant on `watch_once`'s readability guard, where the invented cause reaches the operator on a `die` arm — and DR, the older assignment census, DU, DW and the interpolation count all stayed byte-for-byte unchanged.
  Enumerating write syntaxes is unbounded, so the census now enumerates MENTIONS: every line naming either variable is classified by stripping its `$NAME` / `${NAME}` reads, and if the bare name still occurs the line does something other than read and must appear in the inventory.
  The inventory is unchanged (`2 <toplevel>|clear`, `1 fs_get|clear`, `1 fs_novalue_set|text`, `3 fs_why_set|text`) and a fourth kind, `other`, exists for a write that is not an assignment.
  Verified both ways: DR is green on the tree, and RED on the reviewer's mutant with `1 watch_once|other`.

- **MR7-2 (medium, test):** the trio of censuses did not cover the hook's other degraded statuses.
  Reproduced by appending `because its mount is unavailable` to `claim_lock`'s status-2 refusal for `legacy_lock_present` — a cause nothing observed, sitting beside the one that was — with DR, DU and DW all green.
  This is the third consecutive round in which the answer to a status-narration finding was a census of ONE more function's callers, so the population itself was frozen instead: new case **DX** extracts every function in the hook that RETURNS a literal status of 2 or more (fourteen: `epoch`, `file_exists`, `fs_get`, `legacy_lock_present`, `lock_hold`, `lock_take`, `mtime_of`, `path_state`, `rec_get_raw`, `rec_num`, `rec_read`, `row_present`, `transcript_for`, `watch_once`) and requires each to carry a reviewed one-line reason its degraded status cannot become an invented cause.
  The six reasons in use (**corrected in micro-review 8**, which counted the list this sentence introduces and found six, not the four it claimed), each measured rather than assumed: `fs_get` PUBLISHES its cause; `rec_read`, `rec_num` and `legacy_lock_present` DELEGATE to it, so `FS_WHY_TXT` is live for their callers; `file_exists`, `mtime_of`, `rec_get_raw`, `transcript_for` are PROBES that are only ever invoked through `fs_get` (and `path_state` only from inside those), so `fs_get` converts and publishes their status; `lock_take` and `lock_hold` publish nothing and are CENSUSED by DU and DW; `epoch` and `row_present` are narrated by callers that name no mechanism; `watch_once`'s 3 and 4 are the hook's exit protocol, not an observation.
  DX also checks the two dispositions that point at another case — "censused by DU/DW" is worth nothing if DU or DW has been deleted — and its control is a fifteenth function with a degraded status, which must be reported.
  **What DX does not do** (**corrected in micro-review 8** — the original wording, "it guarantees the set is complete", was an OVERSTATEMENT, and MR8 falsified it with a mutant DX passed): it does not verify the dispositions, which are prose reviewed by a person, exactly like `claim-census.js`'s audit list.
  Nor is the set "every function that can be degraded" — that population is not decidable by reading shell.
  A status also arrives by falling off an external command (`notify`, `_notify_darwin`, `_notify_linux`), off a node pipeline (`_row_present_raw`), through a variable (`timed_to_file`'s `return "$_rc"`), or as `exit 2` (`die`); each was read at micro-review 8, none of them narrates a cause, and none is in DX's census.
  What DX does guarantee is narrower: a new LITERAL degraded return is a review decision rather than a silent one.
  Nothing mechanical can decide whether a sentence names a mechanism that was observed.

- **MR7-3 (low, records):** the round-6 scorecard and the running handoff record both quoted case DT's asserted phrase as "the descriptor is still open".
  That is what DT asserted when it was written, and micro-review 6 reworded it to "descriptor for it is still open"; the old wording now survives in the tree only as `DVMUT`'s control text, so both quotations had come loose from the assertion they describe.
  Corrected in place in both files and labelled as corrections.

### Review dispositions — micro-review 8 (the micro-review-7 fix delta)

Three findings, none HIGH, all against the tests and the record rather than the product — `hooks/handoff.sh` is byte-for-byte unchanged in this delta for the second micro-review running.
Both mediums came with a surviving mutation, and both were reproduced as whole-file mutants and run before anything was written.

- **MR8-1 (medium, test):** case DX's population was neither what it claimed nor as wide as it needed to be, and its boundary parsing had four ways past it.
  Reproduced with the reviewer's own mutant — a `function mount_state { … return 2; }` added ahead of `claim_lock`, whose refusal then tells the operator "the mount containing … is unavailable" on a directory test that merely observed absence.
  DR, DU, DW and DX were all green on it.
  Measured on this hook rather than argued: **17 of its 74 function definitions are one-liners** (5 plain, 12 carrying a trailing comment), and for every one of them the old awk matched the header, ran `next`, and skipped the body — so `f() { return 2; }` was invisible.
  `function f {` was not a definition to it at all, and a `return` no function encloses was dropped rather than reported.
  The census now scans a definition line *with* its body, accepts the `function` keyword, and prints `<UNATTRIBUTED>` instead of dropping; four new controls pin one spelling each.
  The overstated claim in this document — "it guarantees the set is complete" — is corrected above and labelled; the true population ("every function that can be degraded") is not decidable by reading shell, and the four mechanisms that carry a status without a literal `return N` are now named there.

- **MR8-2 (medium, test):** case DR censused LINES, so a second write on a line the inventory had already approved was invisible.
  Reproduced with the reviewer's mutant: appending `; printf -v FS_WHY_TXT %s "the mount went away"` to the `killed` constructor's existing arm leaves the inventory byte-for-byte identical, and a probe ending in 143 then reports an invented mount cause to the operator through `watch_once`'s guard.
  The same finding caught a second hole in the same line: the stripper's optional closing brace ate `${FS_WHY_TXT` out of `${FS_WHY_TXT:=…}`, so a default-value ASSIGNMENT was classified as a read.
  DR now counts **writes, not lines** — every mention of either name minus the mentions that are pure `$NAME` / `${NAME}` reads — which closes both holes with one subtraction.
  The inventory is unchanged (`2 <toplevel>|clear`, `1 fs_get|clear`, `1 fs_novalue_set|text`, `3 fs_why_set|text`), verified identical on the untouched hook, and two new controls pin the two shapes.

- **MR8-3 (low, records):** this document said "The four reasons in use" and then listed six.
  True as reported; corrected in place above and labelled.

**The region rewrite, and why this round stops here.**
Micro-reviews 6, 7 and 8 all landed 0 HIGH / 2 MED / 1 LOW on the same region, and all three mediums had the same shape: a message names a mechanism it did not observe, answered by a census of one more *function*.
A flat rate over three rounds is the signal to rewrite the region rather than run a fourth pass of the same lens, because the population those censuses chase — "which functions can be degraded" — is not decidable: a status arrives by literal return, through a variable, by falling off a pipeline or an external command, or as `exit`.
So round 6 closes with a census at the OTHER end of the invariant, where the population *is* bounded and was measured: new case **DY** freezes every sentence the hook can tell an operator, together with the line that says it.
An invented cause has to be SAID before anyone can suffer it, so the population is every line that puts operator-visible words into a channel: **123 lines across six channels** — 81 `die`, 22 `alert_once`, 6 `prelaunch_die`, 5 `notify`, 3 bare `printf … >&2`, and 6 assignments of a variable that carries a whole message.
DY asserts the total, each channel's count, and a SHA-256 digest of the sorted `channel|function|source line` rows, so a new sentence, a *reworded* one, and a *permutation* of two existing ones are all red; a count alone cannot say which site changed, which is the defect this branch has now produced eight times.
Rewording an operator message therefore becomes a review decision made in the same commit as the words — that is the cost, and it is the point.
DY does not judge whether a sentence is honest; nothing mechanical can. It makes the set of sentences, and the sites that say them, something a person signed off on.

**Corrected in micro-review 9 — the first version of this paragraph was an OVERSTATEMENT.**
It said DY "freezes every sentence the hook can tell an operator" and that "every saying is a literal in one file — 81 `die` message literals", and neither half held.
`die` is one of five channels: `alert_once`, `prelaunch_die`, `notify` and a bare `printf … >&2` account for 36 more lines the census never saw, so "every sentence" covered 81 of 117.
And a message need not be a literal at the channel at all — `die "$_recfail"` froze the *variable name* while the sentence, written far above, stayed unpinned, and eight direct sites share that one variable.
Hashing the sorted TEXT also discarded which site says what, so two guards could exchange explanations and the digest would hold.
Both defects were demonstrated with surviving mutants, not argued; the numbers and the claim above are the corrected ones.

Both of micro-review 8's surviving mutants were re-run against the rewritten cases and both die: MR8-1's is caught by DX *and* DY (`14 → 15` status functions; under the micro-review-9 census the DY figures are `123 → 124` lines and `81 → 82` `die` sites, not the `81 → 82` total originally recorded here), MR8-2's by DR (`3 → 4` writes in `fs_why_set`).

### Review dispositions — micro-review 9 (the micro-review-8 fix delta)

Micro-review 9 read the micro-review-8 delta on the same three lenses.
It returned **0 HIGH / 2 MEDIUM / 0 LOW**, both mediums against case DY, and both were accepted after their surviving mutants were rebuilt as whole-file copies and confirmed to pass the suite unchanged.
No product file was touched by this round: `hooks/handoff.sh` is byte-identical across the micro-review-9 delta, and the fix is entirely in `tests/handoff.test.sh` plus the corrections above.

- **MR9-1 (medium, test quality):** DY froze call templates, not the sentences operators receive.
  Eight direct sites call `die "$_recfail"`, and DY hashed the four characters `$_recfail` rather than the sentence.
  The surviving mutant rewrites `_recfail` so the refusal names a mount nothing probed — the exact invariant violation the region exists to catch — and the whole suite stayed green on it.
  *Reproduced:* built as a whole-file copy, ran cases DR · DU · DW · DX · DY solo, `rc=0`.
  *Fixed:* the census now includes the assignment of any variable that carries a whole message, so the mutant moves the digest; the case is red on it.
- **MR9-2 (medium, test quality):** sorting discarded the message-to-condition mapping.
  `need_num`'s minimum and maximum guards can exchange explanations, leaving the digest untouched, so a timeout of `0` is refused as "implausibly large" and `1000000` is told it must be at least `1`.
  *Reproduced:* built as a whole-file copy; the census cases stayed green, and the mutant's misrouting was confirmed end-to-end by running the hook with `CLAUDE_HANDOFF_AGENTS_TIMEOUT=0` and `=1000000` and reading the two messages come out swapped.
  *Fixed:* each row is now `channel|function|source line`, so a permutation is red.
  The case keeps the superseded literal-only census as its own control and asserts that the permutation is *invisible* to it, so control 4 cannot quietly degrade into a reword.

Micro-review 9's own delta is where round 6 stops: two mediums, both on the same case, both closed by a rewrite that widened the population by 42 lines and bound every row to its site, with four surviving mutants standing as controls inside the case.

### Still open after round 6

- The three entries under "Still open on this branch" above are unchanged: the unbounded launcher
  under the dispatch claim (the user's number to choose), the deliberately open alert fence during the
  re-dispatch truncation window, and `install.sh`'s cross-process backup selection.
- **`transcript_for`'s per-subdirectory blind spot**, recorded above with the reason it was not
  closed: a project SUBdirectory that cannot be searched is still invisible.
- **No census can decide whether a message names a mechanism that was observed.**
  DY now freezes the operator-facing sentences themselves and DR freezes every WRITE into the two
  cause variables, so a new or reworded sentence is always a review decision — but whether the
  sentence a reviewer then approves is TRUE of the code beside it is a human judgement, and the
  suite only guarantees that a human was asked. This is stated here rather than implied by the
  censuses' existence.
- **DY's digest is deliberately brittle, and that is a standing cost.** Any copy edit to any of the
  123 operator-facing lines — including a change to a message *variable*, and including a swap of two
  existing messages between their sites — reddens the suite until the digest is updated in the same
  commit. If that ever becomes friction someone routes around — updating the digest without reading
  the diff — the case has stopped working, and the fix is a review habit, not a looser assertion.
- **DX's population is not "every function that can be degraded."** It is every function with a
  literal `return N ≥ 2`. The four other mechanisms are named in the micro-review-8 dispositions
  above; each was read and none narrates a cause, but nothing stops a future one from doing so, and
  only DY would see it.
- **DY's population is every line that SAYS something, not every line that could mislead.** A
  sentence assembled at the channel from two variables neither of which is assigned words — the
  shape `die "$a$b"` where `$a` and `$b` are both built by concatenation — would be counted once, at
  the channel, with the halves unfrozen. The hook has no such site today (the six message variables
  are each assigned their words in one place, and DY asserts that count), but the census would not
  announce the first one; it would simply cover it less than the row implies.
