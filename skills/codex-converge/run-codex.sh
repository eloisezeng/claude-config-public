#!/bin/bash
# run-codex.sh — the watchdogged Codex launcher for codex-converge.
#
#   run-codex.sh --policy-version 2026-09-02-scheduler-v1 [--write] --arc DIR --track T --round N [--name NAME] \
#                <prompt-file> <out-file> <log-file> <workdir> [codex-args...]
#   run-codex.sh --policy-version 2026-09-02-scheduler-v1 [--write] --one-off <prompt-file> <out-file> <log-file> <workdir> [codex-args...]
#
# Every launch is ATTRIBUTED (arc → track → round) and runs through loop.py: it takes the
# worktree's read (or, with --write, exclusive) lock, refuses through the round gate until the
# previous round is closed and its TRIGGERED levers dispositioned, and quarantines a verdict
# whose tree moved while it was being read (rc 5).  --arc/--track/--round may also come from
# CC_ARC/CC_TRACK/CC_ROUND (arc defaults to $CLAUDE_JOB_DIR/tmp).  --one-off is the explicit
# opt-out for a single call outside any arc: unscheduled, unprofiled, no gate.  --scheduled is
# the inner marker loop.py passes back; callers never pass it.
#
#   run-codex.sh --policy-version 2026-09-02-scheduler-v1 prompt.txt /tmp/verdict.json /tmp/run.log "$WT" \
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
#   - exit 8 if the run resolved to reasoning effort 'none' (a silent profile fall-through): the
#     verdict came from a tier nobody chose, so it is moved aside to <out-file>.void rather than
#     returned as a completed review.
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
POLICY_VERSION="2026-09-02-scheduler-v1"
ACK_POLICY_VERSION=""
ARC=""; TRACK=""; ROUND=""; NAME=""; ONE_OFF=0; SCHEDULED=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --write) WRITE_MODE=1; shift ;;
    --arc|--track|--round|--name)
      [ "$#" -ge 2 ] || { echo "run-codex: $1 requires a value" >&2; exit 2; }
      case "$1" in
        --arc) ARC="$2" ;; --track) TRACK="$2" ;; --round) ROUND="$2" ;; --name) NAME="$2" ;;
      esac
      shift 2 ;;
    --one-off) ONE_OFF=1; shift ;;
    --scheduled)
      echo "run-codex: --scheduled is not a caller option. The inner handshake is CC_LOOP_JOB/CC_LOOP_ARC, set by loop.py and verified against its ledger." >&2
      exit 2 ;;
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
  echo "usage: run-codex.sh --policy-version $POLICY_VERSION [--write] (--arc DIR --track T --round N [--name NAME] | --one-off) <prompt-file> <out-file> <log-file> <workdir> [codex-args...]" >&2
  exit 2
fi
PROMPT="$1"; OUT="$2"; LOG="$3"; WORKDIR="$4"
shift 4

# ---- scheduler handshake ----------------------------------------------------------------
# An unattributed launch is invisible to `loop.py profile` (lever L7), can fight a scheduled
# job for the machine, and skips the round gate — so it is refused, not tolerated.  The
# attributed launch re-executes THIS script through loop.py, which hands the inner run a
# ledger-verified CC_LOOP_JOB handshake; the inner run
# below is byte-for-byte the launcher it always was.
HERE="$(cd "$(dirname "$0")" && pwd)"
SELF="$HERE/$(basename "$0")"
# Inner handshake. loop.py exports CC_LOOP_JOB/CC_LOOP_ARC to the child it launches and has
# already appended that job's `start` event, carrying its own pid, to the arc ledger. We honour
# the marker only when the ledger shows THIS job started by OUR parent process — a caller who
# merely sets the variables (or passes a flag) cannot skip scheduling.
if [ -n "${CC_LOOP_JOB:-}" ] || [ -n "${CC_LOOP_ARC:-}" ]; then
  if [ -n "${CC_LOOP_JOB:-}" ] && [ -n "${CC_LOOP_ARC:-}" ] && [ -f "$CC_LOOP_ARC/jobs.jsonl" ] \
     && grep -q -- "\"ev\": \"start\".*\"job\": \"$CC_LOOP_JOB\".*\"pid\": $PPID[,}]" "$CC_LOOP_ARC/jobs.jsonl" 2>/dev/null; then
    SCHEDULED=1
  else
    echo "run-codex: CC_LOOP_JOB='${CC_LOOP_JOB:-}' is set but ${CC_LOOP_ARC:-<unset>}/jobs.jsonl has no start event for it from parent pid $PPID — refusing the unverified inner handshake" >&2
    exit 2
  fi
fi
if [ "$SCHEDULED" -eq 0 ] && [ "$ONE_OFF" -eq 0 ]; then
  [ -n "$ARC" ] || ARC="${CC_ARC:-}"
  if [ -z "$ARC" ] && [ -n "${CLAUDE_JOB_DIR:-}" ]; then ARC="$CLAUDE_JOB_DIR/tmp"; fi
  [ -n "$TRACK" ] || TRACK="${CC_TRACK:-}"
  [ -n "$ROUND" ] || ROUND="${CC_ROUND:-}"
  if [ -z "$ARC" ] || [ -z "$TRACK" ] || [ -z "$ROUND" ]; then
    echo "run-codex: this launch is not attributed to an arc/track/round, so it would be unscheduled and unprofiled." >&2
    echo "run-codex: pass --arc DIR --track T --round N (or export CC_ARC/CC_TRACK/CC_ROUND; arc defaults to \$CLAUDE_JOB_DIR/tmp)," >&2
    echo "run-codex: or --one-off for a single call outside any convergence arc." >&2
    exit 2
  fi
  case "$ROUND" in ''|*[!0-9]*) echo "run-codex: --round must be a whole number, got '$ROUND'" >&2; exit 2 ;; esac
  [ -x "$HERE/loop.py" ] || [ -f "$HERE/loop.py" ] || { echo "run-codex: $HERE/loop.py is missing — cannot schedule" >&2; exit 2; }
  # loop.py runs the inner launcher with cwd=<workdir>, so every path must be absolute before the
  # re-exec or a relative prompt/out/log resolves somewhere else inside the child.
  _abs() { case "$1" in /*) printf '%s\n' "$1" ;; *) printf '%s/%s\n' "$PWD" "$1" ;; esac; }
  PROMPT="$(_abs "$PROMPT")"; OUT="$(_abs "$OUT")"; LOG="$(_abs "$LOG")"; WORKDIR="$(_abs "$WORKDIR")"
  KIND=review; WFLAG=""
  if [ "$WRITE_MODE" -eq 1 ]; then KIND=write; WFLAG="--write"; fi
  if [ -z "$NAME" ]; then NAME="$(basename "$OUT")"; NAME="${NAME%.verdict.json}"; NAME="${NAME%.json}"; fi
  # A workdir that is not a git tree gets no tree lock (nothing can prove it unchanged), but is
  # still scheduled and ledgered; loop.py refuses --tree on a non-repo, so only pass it when true.
  TREEFLAG=""
  git -C "$WORKDIR" rev-parse --is-inside-work-tree >/dev/null 2>&1 && TREEFLAG=1
  # $WFLAG is unquoted on purpose: empty must vanish, and it is never anything but "--write".
  # shellcheck disable=SC2086
  exec python3 "$HERE/loop.py" run --arc "$ARC" --track "$TRACK" --round "$ROUND" --kind "$KIND" \
    --name "$NAME" ${TREEFLAG:+--tree "$WORKDIR"} --out "$OUT" --log "$LOG" --no-capture \
    -- "$SELF" --policy-version "$POLICY_VERSION" $WFLAG "$PROMPT" "$OUT" "$LOG" "$WORKDIR" "$@"
fi

# Review runs are read-only and retryable. Mutating runs are neither: a killed attempt may
# already have written or committed, so a retry would inherit partial state and silently
# duplicate work. One attempt, then quarantine for inspection.
if [ "$WRITE_MODE" -eq 1 ]; then
  SANDBOX="workspace-write"
  ATTEMPTS=1
  # An implementation run reasons in long silent stretches -- the model composes a whole file, or
  # thinks through a decision table, with no tool call and so no log line. Measured 2026-09-02: a
  # solx --write slice was killed at 150s idle mid-work, having written nothing, and the kill cost
  # the entire run because a mutating run is never retried. Read-only reviews emit tool traffic far
  # more steadily, so only the write path needs the wider window.
  DEFAULT_STALL_LIMIT=60   # ~600s of silence
else
  SANDBOX="read-only"
  ATTEMPTS=3
  DEFAULT_STALL_LIMIT=15   # ~150s of silence
fi

POLL=10           # seconds between liveness checks
IDLE_WINDOW=25    # log counts as idle if untouched this long
STALL_LIMIT="${RUN_CODEX_STALL_LIMIT:-$DEFAULT_STALL_LIMIT}"  # consecutive idle windows before we kill (~150s read-only, ~600s --write; override via env for runs with long silent final composition)
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
  # The name is data, not a pattern. It used to be interpolated straight into a grep -E regex, so
  # a name carrying a metacharacter matched a profile it does not name -- `-p '.*'` matches
  # `[profiles.sol]` and the guard waves it through, after which codex silently falls back to the
  # base config and the verdict comes from a tier nobody chose. That is the exact failure this
  # guard exists to catch, so the comparison is literal and the name itself is constrained.
  case "$REQ_PROFILE" in
    *[!A-Za-z0-9._-]*|''|.|..|*..*)
      echo "run-codex: profile name '$REQ_PROFILE' is not a plain profile name" >&2
      echo "run-codex: (letters, digits, dot, underscore, dash; no path segments)" >&2
      exit 2 ;;
  esac
  _found=0
  if [ -f "$CODEX_HOME/$REQ_PROFILE.config.toml" ]; then _found=1; fi
  if [ "$_found" -eq 0 ] && [ -f "$CODEX_HOME/config.toml" ]; then
    while IFS= read -r _p; do
      if [ -n "$_p" ] && [ "$_p" = "$REQ_PROFILE" ]; then _found=1; fi
    done <<EOF
$(grep -oE '^\[profiles\.[^]]+\]' "$CODEX_HOME/config.toml" 2>/dev/null | sed 's|^\[profiles\.||; s|\]$||; s|"||g')
EOF
  fi
  if [ "$_found" -eq 0 ]; then
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
  # Same rule for the CLI usage errors, and every alternative is ANCHORED: on 2026-09-02 a
  # reviewer `cat -n`-ed this very file into its log, the unanchored 'unrecognized subcommand'
  # matched the quoted grep below, and a healthy 8-minute review was abandoned as "non-retryable".
  head -100 "$LOG" 2>/dev/null | grep -q '^error: unexpected argument\|^error: invalid value\|^error: unrecognized subcommand\|^Failed to read output schema file' && return 0
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
        # This used to warn on stderr and then exit 0, so a round the launcher had ITSELF
        # identified as void was handed to the caller as a completed review -- and a warning
        # inside a multi-hundred-line log is not a gate. Effort 'none' is never something this
        # skill asks for: it is what a silent profile fall-through resolves to. Fail closed.
        echo "run-codex: the run resolved to reasoning effort 'none' (model=${RAN_MODEL:-unknown})." >&2
        echo "run-codex: this verdict came from an unintended tier -- it is NOT a completed review" >&2
        echo "run-codex: at the depth you requested, so the run is quarantined rather than returned." >&2
        echo "run-codex: the output is kept at $OUT.void for inspection." >&2
        mv -f "$OUT" "$OUT.void" 2>/dev/null || true
        exit 8
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

  if [ "$attempt" -lt "$ATTEMPTS" ]; then
    echo "[watchdog] attempt $attempt of $ATTEMPTS failed (rc=$RC, no usable verdict); retrying" >> "$LOG"
  else
    echo "[watchdog] attempt $attempt of $ATTEMPTS failed (rc=$RC, no usable verdict); no retry left" >> "$LOG"
  fi
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
