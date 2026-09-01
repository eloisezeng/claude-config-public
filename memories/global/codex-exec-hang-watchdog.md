---
name: codex-exec-hang-watchdog
description: codex exec hangs on startup waiting for interactive stdin (hook/MCP trust); feed the prompt via stdin (- < file) so it can't wedge, and watchdog it — never let it sit dead
metadata: 
  node_type: memory
  type: feedback
  scope: global
  originSessionId: a6c590aa-dca1-4418-81b2-b5182bb7df65
---

`codex exec` (drives Claude↔Codex convergence reviews) can hang **indefinitely on startup, before any model call**: The user's Codex install has custom hooks/MCP config (`~/.codex/hooks.json`, `config.toml`), and on launch it wants an interactive trust/confirm on stdin — as a background process it blocks forever at 0% CPU having written nothing. `--ignore-user-config` does NOT prevent this (it skips `config.toml` but not `hooks.json`); observed wedges of 2h+.

**Launch form that can't wedge** — feed the prompt via stdin (`-`) so the trust prompt hits EOF instead of blocking (also dodges shell-escaping of long prompts):
```
codex exec -s read-only -C <dir> --skip-git-repo-check --output-last-message <out.md> - < prompt.txt
```

**The canonical launcher now ships with the skill: `~/dotfiles/claude/skills/codex-converge/run-codex.sh`** (`<prompt> <out> <log> <workdir> [codex-args...]`). Use it rather than re-deriving the loop below; it adds process-group kill, exit-status checking, atomic promotion, and fail-fast on non-retryable errors, all pinned by a stub-`codex` test matrix. The sketch below is the minimal shape it grew from.

**The watchdog is not optional and must ship with auto-retry in the SAME launch** (the user, 2026-07-13: "remember to not allow codex review to have failure mode, or retry if it occurs" — after a correctly-launched review sat silent 87 minutes under manual spot-checking). Canonical launcher — run THE SCRIPT as the background task, so its completion always means "verdict ready or 3 attempts exhausted", never "maybe wedged":
```bash
# run-codex-watchdogged.sh <promptfile> <outfile> <logfile>
for attempt in 1 2 3; do
  rm -f "$OUT"; codex exec -s read-only -o "$OUT" - < "$PROMPT" > "$LOG" 2>&1 &
  C_PID=$!; STALE=0
  while kill -0 "$C_PID" 2>/dev/null; do
    sleep 10
    if [ -n "$(find "$LOG" -newermt '-25 seconds' 2>/dev/null)" ]; then STALE=0; else STALE=$((STALE+1)); fi
    [ "$STALE" -ge 15 ] && { kill "$C_PID" 2>/dev/null; break; }   # ~150s idle log = wedged
  done
  wait "$C_PID" 2>/dev/null
  [ -s "$OUT" ] && exit 0    # verdict written = success
done
exit 1
```

Gotchas:
- **Watch the OUTPUT-LOG mtime, never `~/.codex` writes.** Codex spends long stretches in MCP tool calls that write elsewhere at 0% CPU, so a `find ~/.codex -newermt` heuristic kills healthy runs (two premature kills in one session); a genuine startup wedge also never grows the log, so log-mtime catches the wedge AND avoids the false kill. Two concurrent runs → one log file each, watched independently.
- macOS has **no `timeout`** (only `gtimeout`) — wrapping codex in `timeout` silently no-ops the whole command.
- zsh: `PPID` is a **read-only** builtin — assigning it aborts the watchdog loop; name PID vars `C_PID`/`D_PID`.
- `-o/--output-last-message` is written by the **host CLI, not the sandboxed model**, so `-s read-only` does not block it. Verified on CLI 0.146.0 (2026-08-03): `-o` succeeded both inside the `-C` workspace and at `/tmp`. (An older note here claimed read-only silently skipped it — that was wrong.) Still point `-o` OUTSIDE the reviewed tree, for the real reason: a verdict file written into the tree pollutes the diff under review.

- **`run-codex.sh` takes the prompt as a POSITIONAL ARGUMENT, not on stdin** — piping it in (or passing a flag where the prompt path belongs) exits 2 with `prompt file not found: -m`, yet the background wrapper still reports "completed (exit code 0)". Confirm every round by reading the VERDICT FILE it should have written; a missing verdict means no review happened, so folding "no findings" would silently skip a round. (Observed 2026-08-18 on a spec-r4 dispatch.)

- **A retry ERASES the evidence of why the previous attempt died.** Each attempt starts with `: > "$LOG"` and re-redirects codex's stdout to the same path, so the `[watchdog] log idle …; killing process group` and `[watchdog] attempt N failed (rc=…); retrying` lines the launcher wrote are wiped by the next attempt. Afterwards a `grep watchdog "$LOG"` returns **nothing** whether or not a kill happened, so "did this run retry, and why?" is unanswerable from the artifact. Diagnose a retry live instead — a log that SHRINKS (e.g. 432KB → 13KB) with the banner back at the top is a retry in progress, not a dying run — and treat any liveness check keyed on `pgrep codex` as needing **two consecutive** empty readings, because the gap between attempts legitimately shows zero processes. Fix when touching the launcher: mirror the watchdog lines to a `$LOG.attempts` sidecar that is never truncated.
- **At `xhigh`/`max` with `reasoning summaries: none`, the 150s idle kill destroys HEALTHY runs — raise it, do not "budget for retries".** Measured 2026-08-21: a Sol/xhigh lens over a 5,000-line spec goes **150-170s between log writes** while thinking, i.e. straddling the `IDLE_WINDOW=25 × STALL_LIMIT=15` threshold. Retrying does not help, because every attempt hits the same wall — one lens burned all 3 attempts at `rc=124` having done real work each time. Survival is a coin flip decided by noise: codex's model-cache emits an unrelated `failed to renew cache TTL` ERROR every ~10s during MCP bursts, and that incidentally resets the idle timer, so an otherwise identical lens lives. FIXED 2026-08-25: the launcher now honors `RUN_CODEX_STALL_LIMIT` (idle windows before kill; default 15 = ~150s, set 60-90 for long-silent routes) — export it instead of copying the launcher. Also verified: high-effort runs composing a large `--output-schema` final message go silent past 150s too (three attempts burned on the same wall), and adding `-c model_reasoning_summary="auto"` keeps the log alive with genuine liveness, which is the better first knob when the account supports summaries. If a lens is already in flight under the short window, do not kill it blind: arm a watcher on the **first** `[watchdog] log idle` line to kill and re-dispatch under the tuned launcher, which saves the two doomed retries that would otherwise follow. Only if a lens exhausts attempts for some OTHER reason should you re-dispatch it — never fold a missing verdict in as "no findings".

Pairs with [[feedback-never-give-up-on-api-errors]], [[execution-verification-prefs]], [[review-the-commit-that-is-checked-out]], [[verify-claims-against-artifacts]].
