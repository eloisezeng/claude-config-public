#!/bin/bash
# run-codex.sh — the watchdogged Codex launcher for codex-converge.
#
#   run-codex.sh --policy-version 2026-08-30-regression-v1 [--write] <prompt-file> <out-file> <log-file> <workdir> [codex-args...]
#
#   run-codex.sh --policy-version 2026-08-30-regression-v1 prompt.txt /tmp/verdict.json /tmp/run.log "$WT" \
#     -p sol --output-schema "$HOME/dotfiles/claude/skills/codex-converge/review-output.schema.json"
#
# Supplies exactly one -s (never pass your own), plus -C <workdir>, -o <tmp> and stdin-piping;
# everything after <workdir> is passed through to `codex exec`.
#
#   default    -s read-only,      up to 3 attempts   (reviews)
#   --write    -s workspace-write, exactly 1 attempt (implementation)
#
# --write additionally REFUSES to start unless <workdir> is a linked git worktree (never the
# primary checkout), is not on main/master/develop, and is clean. It pins START_SHA and, on
# either outcome, prints the commits and changed files so the caller can check them against
# the task's allowlist. It never retries: a killed attempt may already have written or
# committed, so the worktree is quarantined for inspection instead.
#
# Guarantees:
#   - exit 0 ONLY if codex exited 0 AND wrote a non-empty regular file, which is then renamed
#     into place within the destination directory. A partial file is never promoted, and a
#     failed promotion leaves no partial destination behind.
#   - a run whose log goes idle for ~STALL_SECS is killed by process GROUP, escalated to
#     SIGKILL while any group member survives, and reaped under a deadline that the final
#     wait cannot exceed.
#   - non-retryable failures (bad schema, bad flag, unreadable schema file) report once.
#
# Exit codes: 0 verdict promoted | 1 attempts exhausted | 2 bad usage/environment
#             3 non-retryable request or usage error
#             4 --write run finished but left an uncommitted tree (transcript promoted, task failed)
#
# <out-file> and <log-file> should sit OUTSIDE the reviewed tree so review artifacts never
# pollute the diff under review.

set -u
set -m   # each background job becomes its own process-group leader, so we can kill the tree

WRITE_MODE=0
POLICY_VERSION="2026-08-30-regression-v1"
ACK_POLICY_VERSION=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --write) WRITE_MODE=1; shift ;;
    --policy-version)
      [ "$#" -ge 2 ] || { echo "run-codex: --policy-version requires a value" >&2; exit 2; }
      ACK_POLICY_VERSION="$2"; shift 2 ;;
    *) break ;;
  esac
done

if [ "$ACK_POLICY_VERSION" != "$POLICY_VERSION" ]; then
  echo "run-codex: convergence policy changed; refusing a stale-session launch." >&2
  echo "run-codex: re-read ~/dotfiles/claude/skills/codex-converge/SKILL.md in full." >&2
  echo "run-codex: then retry with --policy-version $POLICY_VERSION" >&2
  exit 2
fi

if [ "$#" -lt 4 ]; then
  echo "usage: run-codex.sh --policy-version $POLICY_VERSION [--write] <prompt-file> <out-file> <log-file> <workdir> [codex-args...]" >&2
  exit 2
fi
PROMPT="$1"; OUT="$2"; LOG="$3"; WORKDIR="$4"
shift 4

# Review runs are read-only and retryable. Mutating runs are neither: a killed attempt may
# already have written or committed, so a retry would inherit partial state and silently
# duplicate work. One attempt, then quarantine for inspection.
if [ "$WRITE_MODE" -eq 1 ]; then
  SANDBOX="workspace-write"
  ATTEMPTS=1
else
  SANDBOX="read-only"
  ATTEMPTS=3
fi

POLL=10           # seconds between liveness checks
IDLE_WINDOW=25    # log counts as idle if untouched this long
STALL_LIMIT="${RUN_CODEX_STALL_LIMIT:-15}"  # consecutive idle windows before we kill (default ~150s of no log output; override via env for runs with long silent final composition)
REAP_LIMIT=15     # seconds to wait at each escalation step before giving up

[ -f "$PROMPT" ] || { echo "run-codex: prompt file not found: $PROMPT" >&2; exit 2; }
[ -d "$WORKDIR" ] || { echo "run-codex: workdir not found: $WORKDIR" >&2; exit 2; }
[ -d "$OUT" ] && { echo "run-codex: <out-file> is a directory: $OUT" >&2; exit 2; }
[ -d "$LOG" ] && { echo "run-codex: <log-file> is a directory: $LOG" >&2; exit 2; }
OUT_DIR="$(dirname "$OUT")"
for d in "$OUT_DIR" "$(dirname "$LOG")"; do
  [ -d "$d" ] && [ -w "$d" ] || { echo "run-codex: not a writable directory: $d" >&2; exit 2; }
done

# --- Codex profile preflight ------------------------------------------------
# `codex exec -p <name>` with no matching profile is NOT an error: it silently falls through
# to the base config. Measured on this Mac 2026-08-17: `-p terrax` (absent here) ran
# gpt-5.6-sol at reasoning effort "none" while the caller believed it had asked for
# Terra/xhigh. Profiles and tier availability are PER-MACHINE, so a skill shared between
# machines cannot assume a profile exists. Refuse up front rather than review at a silently
# downgraded tier.
CODEX_HOME="${CODEX_HOME:-$HOME/.codex}"
REQ_PROFILE=""
_want_profile=0
for _a in "$@"; do
  if [ "$_want_profile" -eq 1 ]; then REQ_PROFILE="$_a"; _want_profile=0; continue; fi
  case "$_a" in
    -p|--profile) _want_profile=1 ;;
    --profile=*)  REQ_PROFILE="${_a#--profile=}" ;;
  esac
done
if [ "$_want_profile" -eq 1 ]; then
  echo "run-codex: -p/--profile given with no profile name" >&2; exit 2
fi
if [ -n "$REQ_PROFILE" ]; then
  if [ ! -f "$CODEX_HOME/$REQ_PROFILE.config.toml" ] \
     && ! grep -qE "^\[profiles\.\"?${REQ_PROFILE}\"?\"?\]" "$CODEX_HOME/config.toml" 2>/dev/null; then
    {
      echo "run-codex: codex profile '$REQ_PROFILE' does not exist in $CODEX_HOME."
      echo "run-codex: codex would SILENTLY fall back to the base config rather than error,"
      echo "run-codex: so this run would report a verdict from a tier you did not choose."
      echo "run-codex: profiles installed on THIS machine:"
      ls -1 "$CODEX_HOME"/*.config.toml 2>/dev/null \
        | sed 's|.*/||; s|\.config\.toml$||; s|^|  - |' || true
      grep -oE '^\[profiles\.[^]]+\]' "$CODEX_HOME/config.toml" 2>/dev/null \
        | sed 's|^\[profiles\.||; s|\]$||; s|"||g; s|^|  - |' || true
    } >&2
    exit 2
  fi
fi

# The stall detector is only meaningful if the freshness probe actually works. Prove it here,
# so a `find` without -newermt cannot silently masquerade as "the log is idle" and kill
# healthy runs.
PROBE="$(mktemp "${TMPDIR:-/tmp}/run-codex-probe.XXXXXX")" || { echo "run-codex: mktemp failed" >&2; exit 2; }
if [ -z "$(find "$PROBE" -newermt '-60 seconds' 2>/dev/null)" ]; then
  rm -f "$PROBE"
  echo "run-codex: this find(1) does not support -newermt; the stall detector would kill healthy runs" >&2
  exit 2
fi
rm -f "$PROBE"

# Mutating runs must be bounded BEFORE anything is written: a real linked worktree (never the
# primary checkout), never on a default branch, and clean — so START_SHA...HEAD afterwards is
# exactly what this run did and nothing else.
START_SHA=""
if [ "$WRITE_MODE" -eq 1 ]; then
  # Both paths must be resolved the SAME way (physical, symlinks followed): --absolute-git-dir
  # can return /tmp/... while `cd && pwd` returns /private/tmp/..., which made them never
  # compare equal and silently disabled the primary-checkout guard.
  git -C "$WORKDIR" rev-parse --git-dir >/dev/null 2>&1 || {
    echo "run-codex: --write requires a git worktree: $WORKDIR" >&2; exit 2; }
  GIT_DIR_P="$(cd "$WORKDIR" && cd "$(git rev-parse --git-dir 2>/dev/null)" && pwd)" || GIT_DIR_P=""
  # --git-common-dir prints RELATIVE to the workdir, so it must be resolved from there; doing
  # it from the caller's cwd silently produced a non-matching path and disabled this guard.
  COMMON_P="$(cd "$WORKDIR" && cd "$(git rev-parse --git-common-dir 2>/dev/null)" && pwd)" || COMMON_P=""
  if [ -z "$COMMON_P" ] || [ "$GIT_DIR_P" = "$COMMON_P" ]; then
    echo "run-codex: --write refuses the PRIMARY checkout; use a linked worktree ($WORKDIR)" >&2
    exit 2
  fi
  BRANCH_P="$(git -C "$WORKDIR" rev-parse --abbrev-ref HEAD 2>/dev/null)"
  case "$BRANCH_P" in
    main|master|develop)
      echo "run-codex: --write refuses default branch '$BRANCH_P'; branch first" >&2; exit 2 ;;
    HEAD)
      # Commits made on a detached HEAD are unreachable from any branch and trivially lost.
      echo "run-codex: --write refuses a detached HEAD; check out a branch first" >&2; exit 2 ;;
  esac
  if [ -n "$(git -C "$WORKDIR" status --porcelain 2>/dev/null)" ]; then
    echo "run-codex: --write requires a clean worktree; commit or stash first" >&2; exit 2
  fi
  START_SHA="$(git -C "$WORKDIR" rev-parse HEAD)"
  echo "run-codex: write mode on branch '$BRANCH_P', START_SHA=$START_SHA" >&2
  # A linked worktree's git metadata lives under the PRIMARY repo's .git (COMMON_P), OUTSIDE the
  # workspace-write sandbox — without this grant `git commit` fails with EPERM and every write
  # task ends rc=4 with its work stranded uncommitted (verified 2026-08-07, round-9 task C1; the
  # grant verified working on tasks C2/C3, which committed themselves). Prepended so a caller's
  # own writable_roots -c, passed later on the command line, still wins if supplied.
  set -- -c "sandbox_workspace_write.writable_roots=[\"$COMMON_P\"]" "$@"
  # Commits carry Codex authorship by default so the authorship ledger matches the git log.
  export GIT_AUTHOR_NAME="Codex GPT-5.6 Sol"
  export GIT_AUTHOR_EMAIL="codex@openai.com"
fi

# Never let a stale verdict from an earlier round survive a failed one: a caller that reads
# $OUT after a non-zero exit would consume the previous round's answer as if it were this one's.
rm -f "$OUT" || { echo "run-codex: cannot remove existing output file: $OUT" >&2; exit 2; }
[ -e "$OUT" ] && { echo "run-codex: output path still exists after removal: $OUT" >&2; exit 2; }

group_alive() { pgrep -g "$1" >/dev/null 2>&1; }

# Kill the whole process group, escalating to SIGKILL while ANY member survives.
kill_group() {
  local pgid="$1" waited=0
  kill -TERM -"$pgid" 2>/dev/null || kill -TERM "$pgid" 2>/dev/null
  while group_alive "$pgid" && [ "$waited" -lt "$REAP_LIMIT" ]; do
    sleep 1; waited=$((waited + 1))
  done
  if group_alive "$pgid"; then
    kill -KILL -"$pgid" 2>/dev/null || kill -KILL "$pgid" 2>/dev/null
    waited=0
    while group_alive "$pgid" && [ "$waited" -lt "$REAP_LIMIT" ]; do
      sleep 1; waited=$((waited + 1))
    done
  fi
}

# `set -m` puts Codex in its own process group, which means it does NOT die with the launcher.
# Without this trap, interrupting the launcher orphans a running Codex process.
C_PID=""; TMP_OUT=""
# shellcheck disable=SC2329  # invoked indirectly by the trap installed below
on_signal() {
  local sig="$1"
  [ -n "$C_PID" ] && kill -0 "$C_PID" 2>/dev/null && kill_group "$C_PID"
  [ -n "$TMP_OUT" ] && rm -f "$TMP_OUT"
  echo "run-codex: terminated by SIG$sig" >&2
  trap - "$sig"
  kill -"$sig" $$ 2>/dev/null || exit 2
}
for sig in INT TERM HUP; do
  # shellcheck disable=SC2064
  trap "on_signal $sig" "$sig"
done

# A local usage error (unknown flag, unreadable --output-schema) never succeeds on retry.
non_retryable() {
  # The API-error sniff scans only the HEAD of the log: a genuine request rejection aborts
  # the run before any tool output lands, while a busy review log can QUOTE repo content
  # containing an error-shaped string — a test fixture holding a literal
  # '"type":"invalid_request_error"' spoofed the whole-log grep on 2026-08-04 and turned a
  # retryable wedge into "non-retryable".
  head -100 "$LOG" 2>/dev/null | grep -q '"code": *"invalid_json_schema"\|"type": *"invalid_request_error"' && return 0
  grep -qi '^error: unexpected argument\|^error: invalid value\|Failed to read output schema file\|unrecognized subcommand' "$LOG" 2>/dev/null && return 0
  return 1
}

for attempt in $(seq 1 "$ATTEMPTS"); do
  # Same directory as $OUT so the promotion is a true same-filesystem rename, never a
  # cross-device copy that is observable while partial.
  TMP_OUT="$(mktemp "$OUT_DIR/.run-codex-out.XXXXXX")" || { echo "run-codex: mktemp failed in $OUT_DIR" >&2; exit 2; }
  : > "$LOG"

  codex exec -s "$SANDBOX" -C "$WORKDIR" --skip-git-repo-check -o "$TMP_OUT" "$@" - < "$PROMPT" > "$LOG" 2>&1 &
  C_PID=$!
  STALE=0; KILLED=0

  while kill -0 "$C_PID" 2>/dev/null; do
    sleep "$POLL"
    if find "$LOG" -newermt "-${IDLE_WINDOW} seconds" 2>/dev/null | grep -q .; then
      STALE=0
    else
      STALE=$((STALE + 1))
    fi
    if [ "$STALE" -ge "$STALL_LIMIT" ]; then
      echo "[watchdog] log idle ~$((POLL * STALL_LIMIT))s; killing process group (attempt $attempt)" >> "$LOG"
      kill_group "$C_PID"
      KILLED=1
      break
    fi
  done

  if [ "$KILLED" -eq 1 ]; then
    RC=124
    # Only reap if the leader is actually gone; a survivor must not turn `wait` into a hang.
    if kill -0 "$C_PID" 2>/dev/null; then
      echo "run-codex: process group $C_PID survived SIGKILL; abandoning it rather than blocking" >&2
    else
      wait "$C_PID" 2>/dev/null
    fi
  else
    wait "$C_PID" 2>/dev/null
    RC=$?
  fi

  # Success requires BOTH a clean exit and a non-empty regular file.
  if [ "$RC" -eq 0 ] && [ -f "$TMP_OUT" ] && [ -s "$TMP_OUT" ]; then
    if mv -f "$TMP_OUT" "$OUT"; then
      echo "[watchdog] verdict written on attempt $attempt"
      # Report the tier the run ACTUALLY used, read from codex's own banner, never inferred
      # from the flags we passed. The preflight refuses an unknown -p, but an explicit
      # -m/-c can still land somewhere unintended, and "effort: none" is the signature of a
      # request that resolved to the base config.
      # codex colorizes the banner labels ("\e[1mmodel:\e[0m gpt-..."), so the labels are NOT
      # at the start of the line in bytes. Strip ANSI first or both reads return empty and the
      # tier check reports "unknown" on every single run — a verification that always abstains
      # is worse than none, because it reads like a check that ran.
      _banner="$(sed -e 's/\x1b\[[0-9;]*m//g' "$LOG" 2>/dev/null)"
      RAN_MODEL="$(printf '%s\n' "$_banner"  | sed -n 's/^[[:space:]]*model:[[:space:]]*//p'            | head -1)"
      RAN_EFFORT="$(printf '%s\n' "$_banner" | sed -n 's/^[[:space:]]*reasoning effort:[[:space:]]*//p' | head -1)"
      echo "[watchdog] tier actually used: model=${RAN_MODEL:-unknown} effort=${RAN_EFFORT:-unknown}"
      if [ "$RAN_EFFORT" = "none" ]; then
        echo "run-codex: WARNING - the run resolved to reasoning effort 'none'." >&2
        echo "run-codex: this verdict came from an unintended tier; do not treat it as a" >&2
        echo "run-codex: completed review at the depth you requested (model=${RAN_MODEL:-unknown})." >&2
      fi
      if [ "$WRITE_MODE" -eq 1 ]; then
        echo "run-codex: START_SHA=$START_SHA" >&2
        echo "run-codex: commits made:" >&2
        git -C "$WORKDIR" --no-pager log --oneline "$START_SHA"..HEAD >&2 2>/dev/null
        echo "run-codex: files changed (compare against the task allowlist):" >&2
        { git -C "$WORKDIR" diff --name-only "$START_SHA"..HEAD;
          git -C "$WORKDIR" status --porcelain | awk '{print $NF}'; } 2>/dev/null | sort -u >&2
        # The task contract is atomic commits, so a clean tree is part of "done". Leftover
        # tracked-but-uncommitted edits are exactly where out-of-scope work hides, and
        # START_SHA..HEAD cannot see them. The transcript is already promoted; fail loudly.
        if [ -n "$(git -C "$WORKDIR" status --porcelain 2>/dev/null)" ]; then
          echo "run-codex: WRITE RUN LEFT AN UNCOMMITTED TREE -- task FAILED, quarantined." >&2
          git -C "$WORKDIR" status --porcelain >&2
          exit 4
        fi
      fi
      exit 0
    fi
    echo "run-codex: could not promote output to $OUT" >&2
    rm -f "$TMP_OUT" "$OUT"
    exit 2
  fi

  rm -f "$TMP_OUT"

  if non_retryable; then
    echo "[watchdog] non-retryable error on attempt $attempt; not retrying" >&2
    grep -m1 '"message"\|^error:\|Failed to read output schema file' "$LOG" >&2
    exit 3
  fi

  echo "[watchdog] attempt $attempt failed (rc=$RC, no usable verdict); retrying" >> "$LOG"
done

if [ "$WRITE_MODE" -eq 1 ]; then
  echo "run-codex: MUTATING RUN FAILED. Worktree left AS-IS for inspection, not retried." >&2
  echo "run-codex: START_SHA=$START_SHA -- diff it against HEAD to see what landed." >&2
  git -C "$WORKDIR" --no-pager log --oneline "$START_SHA"..HEAD >&2 2>/dev/null
  git -C "$WORKDIR" status --porcelain >&2 2>/dev/null
  exit 1
fi
echo "[watchdog] $ATTEMPTS attempts exhausted, no verdict" >&2
exit 1
