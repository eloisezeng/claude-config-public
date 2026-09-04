#!/usr/bin/env bash
# handoff.sh — hand remaining work to a FRESH `claude --bg` successor session.
#
# Why a separate session and not an in-session subagent: a subagent leaves the
# spent parent window loaded, so ~160K is cache-read on every later turn. A
# `claude --bg` successor boots its own full session (measured 61.7K first turn,
# SessionStart hooks fire, auth works detached) and the spent window is simply
# abandoned. A fork is never right here — it copies the whole window.
#
#   handoff.sh <handoff-file> <objective> [options]
#   handoff.sh --status
#   handoff.sh --watch <record>        # poll loop (armed automatically)
#   handoff.sh --watch-once <record>   # one evaluation, for the loop and tests
#
# A dispatched successor can BLOCK silently and forever — four sessions on this
# machine have been blocked since 2026-06-19 with nobody told. So:
#   * the dispatch is verified against `claude agents --json`, never against
#     this script's own echo, and the matching row's kind and cwd are checked;
#   * check-then-spawn happens under one atomic per-handoff `flock(2)`, so two
#     callers can never point two successors at one runbook. Ownership belongs
#     to the KERNEL: no owner field, no fencing token, no corpse, no age and no
#     grace, and the lock is released even when the holder is SIGKILLed;
#   * the record is written BEFORE the launch and updated after it, so neither a
#     kill in the launch window nor a failed verification can leave a running
#     successor that no record remembers;
#   * every `claude agents --json` read is bounded by a hard timeout, because an
#     unbounded wait freezes the watchdog in a state that looks exactly like
#     health;
#   * only a POSITIVELY observed terminal state releases ownership. A failed or
#     unparseable `agents --json` read is degraded monitoring, never "finished";
#   * a VERIFIED dispatch RETIRES the dispatching seat -- sentinel, terminal
#     state.json, then a detached stop -- so a seat that has handed its work on
#     stops reading as `awaiting input`. The subject is derived from the seat's
#     own environment and bound five ways before anything irreversible happens,
#     the successor is re-verified at act time, and the reversible half is rolled
#     back if it is gone. `--no-retire` / `CLAUDE_HANDOFF_RETIRE=0` opt out.
set -u

CLAUDE_BIN="${CLAUDE_BIN:-claude}"
PROJECTS_DIR="${CLAUDE_PROJECTS_DIR:-$HOME/.claude/projects}"
LOG="${CLAUDE_HANDOFF_LOG:-$HOME/.claude/hook-events.log}"
ARM="${CLAUDE_HANDOFF_ARM:-1}"
# Retirement of the DISPATCHING seat once a handoff verifies. Same shape as ARM:
# an env kill-switch for the whole fleet, a --no-retire flag for one call.
RETIRE="${CLAUDE_HANDOFF_RETIRE:-1}"
# Between SIGTERM and SIGKILL on the seat being retired.
RETIRE_GRACE_SEC="${CLAUDE_HANDOFF_RETIRE_GRACE:-10}"
# Where the "this seat has already handed off" sentinel lives.
# hooks/context-watchdog.mjs reads the same two variables in the same order, so
# the writer and the guard cannot end up looking at different directories.
STATE_DIR="${CLAUDE_HANDOFF_STATE_DIR:-${CLAUDE_CONFIG_DIR:-$HOME/.claude}/session-state}"
# The operational ledger (2026-08-31 lifecycle decision, docs/notes/
# LIFECYCLE-DECISION-context-vs-handoff-2026-08-31.md in your-other-project).
# Dispatch records stay the source of truth for ownership, but they live next
# to their handoff files, scattered across every repo — undiscoverable to a
# coordinator reconstructing after a death. dispatches/ holds one symlink per
# OPEN dispatched lane, pointing at the record; --close and the retire-time
# supersession are the only things that remove one. Resolution order matches
# inject-ops-lanes.sh, or the writer and its readers disagree about where the
# ledger is.
OPS_DIR="${CLAUDE_OPS_DIR:-${CLAUDE_CONFIG_DIR:-$HOME/.claude}/ops}"

# lane_key <resolved-handoff-path> -> stdout <base>-<8hex>; nonzero if no hash.
# The basename half is for humans; the hash suffix is the identity — two
# handoff files with one basename in different directories are different lanes,
# and one file re-dispatched lands on the same lane every time because the key
# is derived from the RESOLVED path, the same identity authority the record and
# the lock use.
lane_key() {
  _lk_b="${1##*/}"; _lk_b="${_lk_b%.md}"
  _lk_b="$(printf '%s' "$_lk_b" | tr -c 'A-Za-z0-9._-' '-' | cut -c1-48)"
  [ -n "$_lk_b" ] || _lk_b="handoff"
  if command -v md5 >/dev/null 2>&1; then _lk_h="$(printf '%s' "$1" | md5 -q 2>/dev/null)"
  else _lk_h="$(printf '%s' "$1" | md5sum 2>/dev/null)"; fi
  _lk_h="${_lk_h%% *}"
  case "$_lk_h" in
    *[!0-9a-f]*|'') return 1 ;;
  esac
  printf '%s-%.8s' "$_lk_b" "$_lk_h"
}

# close_lane <lane-key> <completed|cancelled|superseded> [note...] — the one
# explicit exit from the open dispatched set. A lane is open until a
# disposition closes it: a seat dying, stalling or being killed never closes
# its lane, and worker completion does not imply merge/push/deploy. The
# disposition is written into the record FIRST (the audit line), the symlink
# removed second — a failure between the two leaves the lane open with the
# disposition already recorded, and the next --close of the same lane repairs
# it (rec_put appends; the last write wins).
# SERIALIZED against dispatch: a dispatch registers the lane link and then
# holds the record's lock across its prelaunch checks and the launch itself,
# so a close that ran unlocked could read the link, write a disposition, and
# remove a lane whose successor was about to launch — an unregistered live
# successor, the exact disappearance the ledger exists to stop. So the close
# takes the SAME lock (nonblocking: an in-flight dispatch wins and the close
# refuses), and then re-verifies the link still names the record it validated,
# because a --force re-dispatch can retarget the link between the first read
# and the lock. The legacy .lock sweep is dispatch-only: no close predates the
# .flock design, so there is no legacy claim a close could be racing.
close_lane() {
  _cl_lane="${1:-}"; _cl_disp="${2:-}"
  [ $# -ge 2 ] || die "usage: handoff.sh --close <lane-key> <completed|cancelled|superseded> [one-line note]"
  shift 2
  _cl_note="$*"
  case "$_cl_lane" in
    ''|*[!0-9A-Za-z._-]*) die "--close: the lane key must be one token of [0-9A-Za-z._-] (got: ${_cl_lane:-empty}) — it is a pathname under $OPS_DIR/dispatches" ;;
  esac
  case "$_cl_disp" in
    completed|cancelled|superseded) ;;
    *) die "--close: the disposition must be completed, cancelled or superseded (got: ${_cl_disp:-empty}) — a lane leaves the open set only by an explicit disposition" ;;
  esac
  if [ -n "$_cl_note" ]; then
    rec_ok_value "$_cl_note" || die "--close: the note must be a single line — a record value that spans lines can forge another field"
  fi
  _cl_link="$OPS_DIR/dispatches/$_cl_lane"
  [ -L "$_cl_link" ] || die "--close: no open dispatched lane named $_cl_lane in $OPS_DIR/dispatches — already closed, or never registered (non-dispatched lanes close by editing their file in $OPS_DIR/lanes)"
  _cl_rec="$(readlink "$_cl_link" 2>/dev/null)" || _cl_rec=""
  [ -n "$_cl_rec" ] && [ -f "$_cl_rec" ] || die "--close: lane $_cl_lane points at a record that is missing (${_cl_rec:-unreadable link}) — refusing to silently drop the lane; investigate, then remove $_cl_link by hand if the work is truly closed"
  # The lock path derives from the record, so the record had to be read first;
  # that read is therefore UNLOCKED and is re-verified below, under the lock.
  # Test seam: the recheck closes a two-instruction race — a colliding dispatch
  # retargeting the link between the readlink above and the lock — that no
  # fixture can reach from outside (both reads run microseconds apart in this
  # one process). The seam performs exactly that retarget, here, so the recheck
  # is reachable by a test; it is inert unless the debug variable is set.
  if [ -n "${CLAUDE_HANDOFF_CLOSE_RETARGET_DEBUG:-}" ]; then
    ln -sfn "$CLAUDE_HANDOFF_CLOSE_RETARGET_DEBUG" "$_cl_link" 2>/dev/null || true
  fi
  lock_hold 9 "$_cl_rec.flock"; _cl_lk=$?
  [ "$_cl_lk" = 2 ] && die "--close: could not take the lane's dispatch lock at $_cl_rec.flock — the path is unopenable, a symlink, or the lock backend did not answer; refusing, because a close that cannot exclude an in-flight dispatch can remove the lane that dispatch just registered"
  if [ "$_cl_lk" != 0 ]; then
    _cl_lw="$( exec 9>&- 8>&- 7>&-; tail -1 "$_cl_rec.flock" 2>/dev/null || true )"
    die "--close: a dispatch of this handoff is running right now and holds the lock${_cl_lw:+ (the lock file says: $_cl_lw)} — closing under it could remove the lane the dispatch is registering; retry when the dispatch has finished"
  fi
  _cl_rec2="$(readlink "$_cl_link" 2>/dev/null)" || _cl_rec2=""
  [ "$_cl_rec2" = "$_cl_rec" ] || die "--close: lane $_cl_lane was re-registered while this close was taking the lock (it now points at ${_cl_rec2:-nothing}, was $_cl_rec) — a re-dispatch owns it again; re-run --close only if the NEW dispatch is also to be closed"
  rec_put "$_cl_rec" disposition "$_cl_disp" || die "--close: cannot write the disposition into $_cl_rec — refusing to remove the lane from the open set without an audit line"
  if [ -n "$_cl_note" ]; then
    rec_put "$_cl_rec" disposition_note "$_cl_note" || die "--close: the disposition landed in $_cl_rec but the note did not — the lane is still open; re-run --close to finish"
  fi
  rec_stamp "$_cl_rec" closed_at || true
  if [ -n "${CLAUDE_CODE_SESSION_ID:-}" ]; then rec_put "$_cl_rec" closed_by "${CLAUDE_CODE_SESSION_ID%%-*}" || true; fi
  rm -f "$_cl_link" || die "--close: the disposition is recorded in $_cl_rec but the link $_cl_link could not be removed — the lane still reads open; remove it by hand"
  printf 'closed lane %s (%s)\n  record: %s\n' "$_cl_lane" "$_cl_disp" "$_cl_rec"
}

POLL_SEC=60
HEARTBEAT_MIN=20
MAX_HOURS="${CLAUDE_HANDOFF_MAX_HOURS:-12}"
TRANSCRIPT_GRACE=300 # a transcript may legitimately not exist yet, this long
# `claude agents --json` is the watchdog's only sense organ. Bound it.
AGENTS_TIMEOUT_SEC="${CLAUDE_HANDOFF_AGENTS_TIMEOUT:-45}"
# The filesystem is the watchdog's OTHER sense organ (transcript discovery and
# mtimes). On a hung mount an unbounded stat freezes the poll loop in a state
# that looks exactly like health, so bound those too.
FS_TIMEOUT_SEC="${CLAUDE_HANDOFF_FS_TIMEOUT:-10}"
WATCH_GEN=""
# The terminal fact is GENERATION-SCOPED. A `--force` re-dispatch truncates the
# record and arms a new generation while the old watcher is mid-poll, so a stale
# watcher could write the bare `finished` key into the NEW generation's record;
# the new watcher then read it on its first poll and exited, leaving a verified
# successor with nobody watching (round-4 lifecycle L5). A key a superseded
# generation writes is now unreadable by its successor by construction rather
# than by timing. A bare `--watch-once` (no generation) keeps the old key.
FIN_KEY="finished"
CLOCK_KEY="clocklost"
# ...and so is the EXPIRY fact, for the same reason from the other direction. A
# watcher that expires is replaced by a re-armed one on the next dispatch
# (`reconcile_watch`), and that new watcher gets a new generation. Keyed to the
# record instead, the second expiry found the first episode's `alerted_expired=1`
# and said nothing: "nobody is watching this successor" was announced once per
# record, ever (round-4 correctness C6, the expiry half). This one and
# `clocklost` are scoped to the WATCHER rather than to the generation, because
# bare `--watch <record>` has no generation and left them flat; `fin_key_set`
# derives both from `$_fk_scope` (the generation, else this watcher's pid).
EXP_KEY="expired"
# How many polls an undelivered terminal or expiry alert is retried before it is
# recorded as undelivered. The alert marker is written only after a notifier
# says it reached somebody, so without a retry a single failed `osascript` lost
# the alert permanently (round-4 lifecycle L6).
ALERT_RETRY_MAX=10

NL='
'
CR="$(printf '\r')"
# install.sh installs a Linux settings variant, so Linux is a supported host and
# an osascript-only notifier delivers NOTHING there (round-3 correctness C5).
HOST_OS="$(uname -s 2>/dev/null || printf 'unknown')"


# States seen from `claude agents --json` on this machine. The enum is NOT
# documented and NOT closed, so the disposition table below is total: anything
# outside both lists is reported and keeps ownership, never assumed healthy and
# never treated as completion.
LIVE_STATES=" running busy working active starting queued "
DONE_STATES=" done complete completed stopped failed error "

die() { printf 'handoff: %s\n' "$*" >&2; exit 2; }

# Hooks don't inherit the interactive shell's PATH; node lives under nvm.
NODE="$(command -v node 2>/dev/null || true)"
if [ -z "$NODE" ]; then
  for c in "$HOME"/.nvm/versions/node/*/bin/node /opt/homebrew/bin/node /usr/local/bin/node; do
    [ -x "$c" ] && NODE="$c"
  done
fi
[ -n "$NODE" ] || die "node not found (needed to read \`claude agents --json\`)"

# A numeric control that reaches arithmetic or `sleep` must be validated at the
# point it enters, not where it is used. Unvalidated, a non-numeric
# --heartbeat-min reached `$(( HEARTBEAT_MIN * 60 ))`, emitted an unbound-variable
# error under `set -u`, and STILL exited 0 — so the watch loop ran forever
# without ever evaluating a heartbeat, with its stderr discarded.
# NOT a command substitution that echoes the value: `die` inside `$( )` exits
# only the subshell, so a validator that returns its input cannot fail closed.
# The minimum is per-control and deliberate: a 0-hour deadline is a coherent
# instruction ("expire at once"), while a 0-second poll interval is a busy loop
# and a 0-second timeout means nothing.
need_num() { # $1=label $2=value [$3=minimum, default 1]
  _nmin="${3:-1}"
  case "${2:-}" in
    ''|*[!0-9]*) die "$1 must be a whole number, not '${2:-}'" ;;
  esac
  # 0 is allowed where the minimum permits it, but 00 or 007 is not: a leading
  # zero is read as OCTAL inside $(( )), so 010 would silently mean 8.
  case "$2" in
    0?*) die "$1 must not have a leading zero ('$2') — a leading zero is read as octal in arithmetic" ;;
  esac
  [ "$2" -ge "$_nmin" ] || die "$1 must be at least $_nmin, not '$2'"
  [ "$2" -le 999999 ] || die "$1 is implausibly large ('$2')"
}
need_num CLAUDE_HANDOFF_MAX_HOURS "$MAX_HOURS" 0
need_num CLAUDE_HANDOFF_AGENTS_TIMEOUT "$AGENTS_TIMEOUT_SEC"
need_num CLAUDE_HANDOFF_FS_TIMEOUT "$FS_TIMEOUT_SEC"
# A grace of 0 is a legitimate choice (kill at once), so the floor is 0 rather
# than 1. It is validated HERE and not at its default on line 47 because
# need_num is not defined until line 125. Without this, a non-numeric value
# makes `[ "$_re_n" -lt "$RETIRE_GRACE_SEC" ]` error; the script runs under
# `set -u` and not `set -e`, so the loop is skipped rather than aborted and the
# graceful shutdown silently becomes an immediate SIGKILL.
need_num CLAUDE_HANDOFF_RETIRE_GRACE "$RETIRE_GRACE_SEC" 0

# THE SUBSTITUTION RULE. `$( … )` forks a child that inherits every open
# descriptor, so a substitution running while a claim is held is a process that
# can outlive the holder still holding its lock — reproduced in round 4 (L2/L7):
# a holder SIGKILLed inside `$(sed … | tail)` left the lease HELD, because the
# kernel releases a lock only when the LAST descriptor on the open file
# description closes. Closing the descriptors on the innermost command is not
# enough; the substitution's own subshell keeps them. So every substitution that
# can run under a claim opens with `exec 9>&- 8>&- 7>&-`, and the helpers that
# would otherwise be called in one return through a global instead — a global
# assignment forks nothing at all, which is strictly better than closing.
NOW_UTC=""
EPOCH=0
# THE STATUS IS THE TRI-STATE. The old body ended at the assignment, so a `date`
# that did not answer left NOW_UTC empty and every caller stored that empty
# string as if it were a time. Callers that only log it may ignore the status;
# every caller that PERSISTS it goes through `rec_stamp`, which writes a
# sentinel instead of a blank when the clock will not answer. C3 fixed the
# dispatch site and this comment then declared the class closed while FIVE
# marker writes still stored the empty string (round 6 micro-review): the
# sentence was as much of the defect as the five sites, because it is what a
# later reader trusts instead of grepping for `now_utc`.
#   NON-EMPTY IS NOT SUCCESS. This body was `NOW_UTC="$(date …)"; [ -n "$NOW_UTC" ]`,
# which threw away `date`'s exit status and called any non-empty stdout a time.
# A `date` that PRINTS AND THEN FAILS — a partial write, a signal mid-format, a
# PATH shim that answers wrongly — therefore returned 0 with garbage in
# NOW_UTC, and `rec_stamp` wrote that garbage into the record as a successful
# timestamp with no `HandoffClockLostAtMarker` beside it: a degraded
# observation became a value, inside the function whose entire job is to stop
# that (round 6 micro-review 2, reproduced with a shim printing `partial` and
# exiting 1). The status is checked AND the shape is checked, because a clock
# that exits 0 while printing something that is not a time tells the same lie
# by the other route.
# ONE PLACE for the range arm, so a control can remove it and nothing else: a
# shape mutant and a range mutant that both have to edit the same multi-line
# condition cannot show which arm caught what. Reached ONLY after the shape check
# in `now_utc`, so every field it sees is two digits and the arithmetic cannot
# abort; base 10 is forced for the reason the record's numbers force it, `08` and
# `09` are not octal.
_nu_in_range() { # $1=two-digit field  $2=min  $3=max
  [ "$((10#$1))" -ge "$2" ] && [ "$((10#$1))" -le "$3" ]
}
now_utc() {
  NOW_UTC="$( exec 9>&- 8>&- 7>&-; date -u +%FT%TZ )" || { NOW_UTC=""; return 1; }   # CLAIM:d — the clock; bounded together with this tri-state so no reading that is not a time can be stored as one
  case "$NOW_UTC" in
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z) : ;;
    *) NOW_UTC=""; return 1 ;;
  esac
  # DIGITS IN THE RIGHT PLACES ARE NOT A TIME. The shape check above was the
  # whole test, so `2026-99-99T99:99:99Z` — month 99, day 99, hour 99 — passed it
  # and `rec_stamp` wrote it into the record as a successful timestamp with no
  # `HandoffClockLostAtMarker` beside it (round 6 micro-review 4, reproduced with
  # a `date` shim printing exactly that and exiting 0). That is the same lie this
  # function's own comment says it exists to stop, told by a clock that answers
  # in the right FORM; the form is necessary and was never sufficient. The
  # ranges are the calendar's, not a parse: 60 seconds is allowed because a leap
  # second is a real reading, and the day is bounded at 31 because refusing
  # month-aware day counts here would make this function a date library.
  _nu_in_range "${NOW_UTC:5:2}" 1 12 && _nu_in_range "${NOW_UTC:8:2}" 1 31 \
    && _nu_in_range "${NOW_UTC:11:2}" 0 23 && _nu_in_range "${NOW_UTC:14:2}" 0 59 \
    && _nu_in_range "${NOW_UTC:17:2}" 0 60 && return 0
  NOW_UTC=""
  return 1
}
# 0 = EPOCH is a reading taken just now.  2 = the clock could not be read, and
# EPOCH IS LEFT EXACTLY AS IT WAS.
#
# `EPOCH=0` was the honest "no reading" only if nothing consumed it, and three
# things do. Zero is not neutral in `EPOCH < DEADLINE`: it is FOREVER EARLY. A
# watcher whose `date` fails therefore never expired, never alerted, and held a
# generation lease that told every reconciling dispatch a live watchdog was on
# the job -- the exact state this script exists to prevent, produced by the
# guard meant to make the failure safe (round-5 lifecycle L14). A degraded
# observation may not become a value; the caller has to see that it failed.
epoch() {
  fs_get "$FS_TIMEOUT_SEC" _date_fmt +%s || return 2
  _ep="$FS_VAL"
  # A clock that answers with something that is not a number would abort every
  # `$(( ))` that consumes it under `set -u`, so it is a failed reading too.
  case "$_ep" in ''|*[!0-9]*) return 2 ;; esac
  EPOCH="$_ep"
  return 0
}

# The stamp is bounded and the log line is written either way: nothing reads the
# log back to make a decision, so a clock that did not answer costs a timestamp,
# never a wrong answer. `now_utc` is deliberately NOT bounded the same way -- its
# value is written into the RECORD, where an empty string would be a degraded
# observation becoming a value, so it is bounded together with a tri-state.
_date_fmt() { date "$1"; }   # reached only inside timed_to_file's child   # CLAIM:a
logline() {
  fs_get "$FS_TIMEOUT_SEC" _date_fmt +%FT%T || FS_VAL=""
  printf '%s %s\n' "$FS_VAL" "$1" >> "$LOG" 2>/dev/null || true   # CLAIM:d — an append; a killable append is a TRUNCATED log line, and nothing reads the log back to decide
}

# Run a command with a hard deadline, capturing stdout to a FILE rather than a
# pipe. This is not a stylistic choice: a command substitution does not return
# until every process holding the pipe closes it, so killing the direct child of
# a wrapper that spawned its own children still blocks for as long as the
# grandchild lives — the timeout would be silently ineffective, which is exactly
# the failure it exists to prevent. Waiting on the child alone is what makes the
# deadline real; the grandchildren are then reaped best-effort.
# A killed command exits non-zero, which is what read_agents turns into DEGRADED.
timed_to_file() { # $1=seconds  $2=outfile  rest=command
  _to="$1"; _of="$2"; shift 2
  # SPAWN SITES 1 and 2. The closes are a CORRECTNESS requirement here, not
  # hygiene: every filesystem probe in this script runs through this function, so
  # a child that inherited fd 8 would re-lock its own parent's description —
  # which always succeeds — and report a live watcher as dead.
  "$@" >|"$_of" 2>/dev/null 9>&- 8>&- 7>&- &
  _p=$!
  ( sleep "$_to"; kill -TERM "$_p" 2>/dev/null; sleep 2; kill -KILL "$_p" 2>/dev/null ) >/dev/null 2>&1 9>&- 8>&- 7>&- &   # CLAIM:c — fixed sleeps; the parent kills it before waiting
  _k=$!
  wait "$_p"; _rc=$?
  kill "$_k" 2>/dev/null || true   # CLAIM:b
  wait "$_k" 2>/dev/null || true
  [ "$_rc" = 0 ] || pkill -TERM -P "$_p" 2>/dev/null 9>&- 8>&- 7>&- || true   # SPAWN SITE 3   # CLAIM:d — an exec, so a hung PATH element blocks it — and it lives INSIDE the deadline mechanism, so it cannot be bounded by it; the reaper is best-effort by design
  return "$_rc"
}

# Returns non-zero when delivery FAILED. On a headless box osascript has no GUI
# session to talk to; the durable record of every alert is the log line above,
# which is written first and unconditionally.
notify() { # $1=short message
  logline "{\"hook_event_name\":\"HandoffWatch\",\"message\":\"$1\"}"
  # Test seam: =1 delivers, =fail simulates a delivery that did not reach anyone
  # (a headless box with no GUI session), which must NOT leave a marker.
  if [ -n "${CLAUDE_HANDOFF_NOTIFY_DEBUG:-}" ]; then
    printf 'NOTIFY: %s\n' "$1"
    [ "$CLAUDE_HANDOFF_NOTIFY_DEBUG" = "fail" ] && return 1
    return 0
  fi
  # Bounded at the BACKEND, not around `notify` itself: the test-seam line and the
  # `logline` above go to the CALLER's stdout, and wrapping the whole function
  # would redirect them into timed_to_file's output file instead. A wedged GUI
  # session therefore costs a deadline, not the whole watch loop, and the timeout
  # arrives as a nonzero return -- which is already this function's "delivery
  # FAILED" and needs no new vocabulary.
  case "$HOST_OS" in
    Darwin)
      # The message travels as an ARGUMENT, never as AppleScript source: a
      # handoff basename containing a quote or a trailing backslash made the
      # generated script unparsable, osascript failed, and because `finished=1`
      # was already recorded the loop exited without ever telling anyone
      # (round-3 correctness C7 — reproduced, both forms, on this machine).
      timed_to_file "$FS_TIMEOUT_SEC" /dev/null _notify_darwin "$1"
      ;;
    *)
      timed_to_file "$FS_TIMEOUT_SEC" /dev/null _notify_linux "$1"
      ;;
  esac
}

# Both reached only inside timed_to_file's child, which has already closed 9/8/7.
_notify_darwin() {
  # CLAIM:a
  osascript -e 'on run argv' \
            -e 'display notification (item 1 of argv) with title "Claude handoff" sound name "Glass"' \
            -e 'end run' -- "$1" >/dev/null 2>&1   # SPAWN SITE 4
}
_notify_linux() {
  # No GUI sink we can prove reached anybody = delivery FAILED, so the alert
  # stays unmarked and is retried. The log line in notify is the durable record.
  # `command -v` lives INSIDE the deadline with the send it gates, so the PATH
  # search cannot be the unbounded half of a bounded pair.
  command -v notify-send >/dev/null 2>&1 || return 1   # CLAIM:a
  notify-send "Claude handoff" "$1" >/dev/null 2>&1   # SPAWN SITE 5   # CLAIM:a
}

# EXACTLY ONE watcher generation may write a record. This is the fence every
# watcher-side mutation passes through, re-read AT WRITE TIME rather than at the
# top of the poll: the gap between the two is where a re-dispatch lands.
#   0 = write (we are current, or we have no generation at all)
#   1 = stand down
# An UNOBSERVABLE record is not supersession, and neither is an EMPTY watch_gen
# — that is the truncation window of a re-dispatch that has not armed yet.
gen_is_ours() { # $1=record
  [ -n "$WATCH_GEN" ] || return 0
  rec_read "$1" watch_gen || return 0
  [ -n "$REC_VAL" ] || return 0
  [ "$REC_VAL" = "$WATCH_GEN" ]
}
# THE SAME FENCE, ASKED AS A DIFFERENT QUESTION. `gen_is_ours` answers "should I
# stand down?", and there an unobservable record must NOT stand a watcher down:
# it would let one hung read silence the very `recdegraded` alert whose job is to
# report that hung read. This answers "may I write a marker that durably
# SUPPRESSES this alert for every other generation?", and on a record we could
# not read the only honest answer to that is no.
# Reproduced (round 6, C1): a superseded generation whose `watch_gen` read timed
# out delivered its alert AND wrote `alerted_notranscript=1` into the live
# generation's record; the key is flat, so the LIVE watcher's first notranscript
# alert was suppressed for the life of the record.
# The EMPTY case stays open on purpose and is NOT the same defect: an empty
# `watch_gen` is the truncation window of a `--force` re-dispatch that has not
# armed yet, and it is written up in docs/handoff-successor.md under "Still open
# on this branch". Only the UNREADABLE case moved.
#   0 = the marker may be written; 1 = it may not
gen_may_write() { # $1=record
  [ -n "$WATCH_GEN" ] || return 0
  rec_read "$1" watch_gen || return 1
  [ -n "$REC_VAL" ] || return 0
  [ "$REC_VAL" = "$WATCH_GEN" ]
}

# The terminal fact's key, derived from the generation, so a superseded watcher
# cannot write the fact the CURRENT watcher exits on (F5). Called once, after
# --watch-gen is parsed and validated.
fin_key_set() {
  [ -n "$WATCH_GEN" ] && FIN_KEY="finished_$WATCH_GEN"
  # THE STAND-DOWN KEYS ARE SCOPED TO THE WATCHER, NOT TO THE GENERATION.
  # Losing the clock is a STAND-DOWN: this watcher exits and another is armed in
  # its place, so there is no recovery transition within one watcher's life to
  # clear a marker with — the same shape as leasedegraded, and it gets the same
  # cure. As a FLAT key it announced the first watchdog to lose the clock and
  # silenced every later one on that record: reproduced in round 6 with two
  # generations, `HandoffWatchClockLost` logged twice and "nobody is watching
  # now" delivered once.
  #   Scoping by `$WATCH_GEN` ALONE left that defect standing for the bare
  # `--watch <record>` mode, which the usage line on this script advertises and
  # an operator re-arming by hand uses: no generation means the guard is false,
  # the key stays flat, and the first bare watcher to lose its clock silences
  # every later one — the original bug, in the mode a human is most likely to be
  # running (round 6 micro-review). A watcher always has an identity even when
  # it has no generation, so the fallback is its pid, and the key is derived
  # once, here, rather than at each arming site.
  #   THE CLASS IS THREE KEYS, and this closes the two that need it. `FIN_KEY`
  # stays flat without a generation on purpose: it names a TERMINAL fact about
  # the successor, so a second watcher re-announcing "it finished" is noise, not
  # a lost warning. `leasedegraded_$WATCH_GEN` is the third, and it is
  # unreachable without a generation — the lease is only taken inside
  # `[ -n "$WATCH_GEN" ]` — so it needs nothing.
  #   A PID IS NOT A DURABLE IDENTITY. `pid$$` alone made the key a pure function
  # of a number the kernel hands out again: these two markers have no clearing
  # edge by design, so a bare watcher that later drew a recycled pid read the
  # earlier watcher's `alerted_clocklost_pid<n>` and stood down — losing exactly
  # the "nobody is watching now" alert this scoping exists to preserve, and
  # making the claim below ("each watcher gets its own episode") false over the
  # record's life (round 6 micro-review 2). The pid stays because it is what an
  # operator reading the record can act on; a per-process nonce is appended so a
  # recycled pid alone no longer makes two watchers share a key. `$RANDOM` is a
  # bash builtin — no fork, nothing to time out, and it cannot fail — and it is
  # drawn ONCE per watcher here rather than at each arming site, so one watcher's
  # episode stays one episode.
  #   THE `x` SEPARATORS AND THE THIRD DRAW ARE LOAD-BEARING, and what they buy
  # is PROBABILISTIC. This said a nonce means reuse "cannot make two watchers
  # share a key", which was false twice over (round 6 micro-review 3):
  # `$RANDOM$RANDOM` concatenates without a separator and so is not injective —
  # (1,23) and (12,3) both spell `123` — and even an injective nonce draws from a
  # finite space. `x` makes distinct triples spell distinct keys, and the third
  # draw puts two same-pid watchers colliding at about 1 in 3.5e13. Two watchers
  # sharing a pid AND a triple would still share an episode; no key derived from
  # a pid can promise otherwise without a durable counter, which would cost a
  # record write at every watcher start.
  _fk_scope="$WATCH_GEN"
  [ -n "$_fk_scope" ] || _fk_scope="pid$$r${RANDOM}x${RANDOM}x${RANDOM}"
  EXP_KEY="expired_$_fk_scope"
  CLOCK_KEY="clocklost_$_fk_scope"
  return 0
}

# alert_once <record> <key> <message>
# DELIVERY IS AT-LEAST-ONCE, DELIBERATELY. The "already told" marker is written
# only AFTER delivery succeeds, so a watcher killed between the notification and
# the marker delivers that alert twice. That is the correct trade and not a bug
# to be fixed: marking first means a failed notification — or a kill in the same
# gap — durably suppresses an alert that never reached anybody, and a silent
# stall is the failure this whole script exists to prevent. `osascript` is a
# local, non-transactional sink; exactly-once would need an idempotent endpoint
# keyed by alert id, which is not something a local hook can provide. A
# duplicate nudge is cheap; a lost one is the bug.
# The claim serialises two watchers racing the same event, and uses the same
# kernel lock as the dispatch lock: a claimant that dies mid-delivery drops it
# instantly, so nothing has to decide whether a claim is a corpse.
# EVERY ALERT KEY, ENUMERATED, WITH ITS RECOVERY TRANSITION.
#
# A marker with no way to be cleared makes the FIRST episode the only one that
# record ever announces. Four separate findings turned out to be that one class,
# so the sites are enumerated here with a three-way classification rather than
# patched where they were reported. 18 keys across 19 arming sites — and this
# census is not prose: case DG derives all three numbers and every key name from
# this file and fails if they drift, because in round 6 the counts here read
# "15 keys across 18 arming sites" against a file that really held 17 keys across
# 17 arming sites, i.e. both numbers were wrong and in opposite directions, and a
# stale census is worse than none (it is the thing a reviewer trusts INSTEAD of
# grepping).
#
#   EPISODIC (13) — a condition that can be entered can be left, so each is
#   cleared at the site that positively observes the condition GONE:
#     recdegraded      -> the record read succeeded
#     degraded         -> `claude agents --json` read succeeded
#     no_session       -> the record gained a session id
#     presencedegraded -> the agent-list presence probe answered
#     blocked          -> the state is live and not blocked
#     unknown          -> the state is live and recognised
#     fsdegraded       -> transcript DISCOVERY answered
#     dispatchdegraded -> the dispatch time could be established (two arming
#                         sites: the read TIMED OUT, and the clock was already
#                         lost at dispatch so the key was never written)
#     beatdegraded     -> the heartbeat STATS answered  (split from fsdegraded: one
#                         key for two conditions let either clear the other's alert)
#     notranscript     -> a transcript exists
#     nobeat           -> a heartbeat arrived
#     watchunknown     -> the watcher-liveness probe answered
#     rearm_failed     -> a later re-arm succeeded (and clears `watch_failed` with it)
#
#   WATCHER-SCOPED (4) — no recovery transition EXISTS within one watcher's
#   life, so the key carries the watcher's identity and each watcher gets its own
#   episode:
#     finished_<gen>  expired_<scope>  leasedegraded_<gen>  clocklost_<scope>
#   (clocklost joined them in round 6: as a flat key the first watchdog to lose
#   the clock announced it and every later one on that record was silenced, which
#   is precisely the "nobody is watching now" alert you cannot afford to lose.)
#   <scope> is the generation when there is one and `pid<pid>r<n>x<n>x<n>` when there
#   is not — the nonce because a pid is reissued and these keys never clear:
#   bare `--watch <record>` is an advertised mode with no generation, and scoping
#   by generation ALONE left these two keys flat there — the same defect, in the
#   mode a human runs by hand (round 6 micro-review). `finished_` and
#   `leasedegraded_` keep the generation: see fin_key_set for why neither needs
#   the fallback.
#
#   RECORD-SCOPED, DELIBERATELY (1):
#     armfailed — written by `dispatch`, and a `--force` re-dispatch TRUNCATES the
#     record before arming again, so the record's life is exactly the episode.
#     Do not add a clearing site; there is no poll that could reach one.
#
#   `rearm_<gen>` is not in the count: it is a per-generation delivery retry, not
#   a condition, and its key changes every time the thing it reports happens.
#
# Adding a key means classifying it here. An episodic key without a clearing site
# is a silent monitor.
# ALERT_RESULT says what THIS call did, one word per outcome, because a caller
# that cannot tell "the notifier refused" from "there was nothing to deliver"
# has to guess — and watch_loop guessed in the expensive direction.
#   delivered — notify() ran and succeeded; the marker is written
#   failed    — notify() ran and returned non-zero
#   skipped   — no delivery was ATTEMPTED and it was not ours to attempt:
#               already alerted, a superseded generation, or another claimant
#               is delivering it right now
#   unavailable — no delivery was attempted because the CLAIM could not be
#               ESTABLISHED: the lock path is unopenable, or the lock backend
#               could not answer. That is ours and it is a failure, and calling
#               it `skipped` made the terminal retry unbounded — the budget
#               never advanced, the give-up was never recorded, and the watcher
#               held its lease to the deadline with the finish unannounced
#               (round-5 lifecycle #12). lock_hold's contract says callers must
#               never collapse "someone else holds it" with "I could not tell";
#               this is the caller that did.
# Single-slot global, like FS_VAL and REC_VAL: read it before the next call.
ALERT_RESULT=""
alert_once() {
  _r="$1"; _ak="$2"; _am="$3"
  ALERT_RESULT=skipped
  rec_has "$_r" "alerted_$_ak" && return 0
  # Every `alerted_*` marker is a record write, so it takes the same fence.
  gen_is_ours "$_r" || return 0
  # The same refusal as the dispatch lock, in the shape this caller can express:
  # a legacy claim beside this alert means ours cannot be ESTABLISHED, which is
  # `unavailable` — a failure of ours that spends an attempt — never `skipped`.
  # 2 lands here with 0 on purpose: "a legacy claim holds this alert" and "I could
  # not establish whether one does" are both "I could not take the claim", which
  # is exactly what batch 1 made `unavailable` mean.
  legacy_lock_present "$_r.alert.$_ak"
  case $? in 0|2) ALERT_RESULT=unavailable; return 0 ;; esac
  # 0 = ours; 1 = someone holding this is delivering this very alert right now,
  # so stand down; 2 = we could not establish the claim at all. Only 1 is a
  # stand-down — 2 is an undelivered alert wearing a stand-down's clothes.
  lock_hold 7 "$_r.alert.$_ak.flock"; _ah=$?
  # CLAIM-REGION-BEGIN alert
  if [ "$_ah" != 0 ]; then
    [ "$_ah" = 2 ] && ALERT_RESULT=unavailable
    return 0
  fi
  # Re-read UNDER the lock: the holder we just followed may have finished.
  if rec_has "$_r" "alerted_$_ak"; then lock_drop 7; return 0; fi
  if notify "$_am"; then
    ALERT_RESULT=delivered
    # The fence is re-read HERE, immediately before the write, because `notify` is
    # bounded by FS_TIMEOUT_SEC at the backend rather than instant: a `--force`
    # re-dispatch that truncates the record and arms a new `watch_gen` inside that
    # window would otherwise land this watcher's FLAT `alerted_*` in the NEW
    # generation, and the new watcher's first alert of that kind would be
    # suppressed by a marker left by a watcher that no longer exists.
    # WHAT THIS DOES AND DOES NOT DO: it narrows the window from the whole
    # notifier call to two record operations. It does not close it. Closing it
    # would require `dispatch` to take the alert claim, which would let a wedged
    # notifier block a re-dispatch — a worse failure than a duplicate nudge.
    # ALERT_RESULT stays `delivered` on purpose: delivery is the outcome both
    # callers act on (alert_spent and the terminal retry in watch_loop, which
    # should stop — this watcher is superseded), and the marker is bookkeeping
    # for a generation that no longer exists.
    if gen_may_write "$_r"; then rec_set "$_r" "alerted_$_ak" || true; fi
  else
    ALERT_RESULT=failed
  fi
  # Releasing an UNDELIVERED alert's claim is what allows the retry. The marker
  # is written only on success, so the lock ever stands between two watchers,
  # never between a retry and its alert.
  lock_drop 7
  # CLAIM-REGION-END alert
}

# The ONE place that says whether the last `alert_once` consumed a delivery
# attempt, because there are two bounded retry budgets and the round-4 cure was
# written into only one of them: the terminal site stopped counting polls while
# the expiry site kept counting them, so a single defect shipped twice and had
# to be found twice (round-5 correctness #5 / lifecycle #13). Any future
# `ALERT_RETRY_MAX` loop calls THIS between the alert and the increment.
alert_spent() { # -> 0 if the last alert_once used up an attempt
  case "$ALERT_RESULT" in
    failed|unavailable) return 0 ;;
    *) return 1 ;;
  esac
}

# The terminal alert has ONE author, reached from two places: watch_once, on the
# poll that OBSERVES the finish, and watch_loop, on every later poll while the
# marker is absent. The loop needs its own way in because watch_once returns far
# above its terminal branch once `claude agents --json` degrades, and a finish
# nobody was ever told about is the silent stall this script exists to report.
# Both callers therefore produce the SAME sentence: a retry that reads
# differently from the first attempt is a second alert, not a retry.
alert_finished() { # $1=record  [$2=how it finished, when the caller observed it]
  _afw="${2:-}"
  if [ -z "$_afw" ]; then
    rec_read "$1" "${FIN_KEY}_how" || true
    _afw="$REC_VAL"
  fi
  [ -n "$_afw" ] || _afw="state unknown"
  _afs="${SHORT:-}"
  if [ -z "$_afs" ]; then rec_read "$1" session_id || true; _afs="$REC_VAL"; fi
  [ -n "$_afs" ] || _afs="the successor"
  rec_read "$1" handoff || true
  if [ -n "$REC_VAL" ]; then _afh="${REC_VAL##*/}"; else _afh="the handoff file"; fi
  alert_once "$1" "$FIN_KEY" "successor $_afs finished ($_afw) — review $_afh"
}

# ------------------------------------------------------- reading the agent list
# AGENTS_JSON / AGENTS_OK are set together. AGENTS_OK=0 means the observation
# itself failed (command error, empty output, or JSON that is not an array) —
# a condition that must never be read as "the session is gone".
AGENTS_JSON=""
AGENTS_OK=0
read_agents() {
  # SPAWN SITE 6.
  fs_get "$FS_TIMEOUT_SEC" _agents_tmp || { AGENTS_JSON=""; AGENTS_OK=0; return 1; }
  _af="$FS_VAL"
  [ -n "$_af" ] || { AGENTS_JSON=""; AGENTS_OK=0; return 1; }
  if ! timed_to_file "$AGENTS_TIMEOUT_SEC" "$_af" "$CLAUDE_BIN" agents --json; then   # CLAIM:a
    timed_to_file "$FS_TIMEOUT_SEC" /dev/null rm -f "$_af" || true   # CLAIM:a
    AGENTS_JSON=""; AGENTS_OK=0; return 1
  fi
  # SPAWN SITE 7. ONE bounded probe reads the file, proves it is a JSON array and
  # re-emits it MINIFIED -- a single line by construction, because JSON escapes
  # every newline inside a string. That is what lets the answer come back through
  # fs_get at all: the `cat` this replaces had to run in the parent, because a
  # multi-line value cannot survive fs_get's single-line `read`, and it was the
  # last unbounded read on this path. The parse IS the validation, so the
  # separate validator subshell is gone with it.
  fs_get "$AGENTS_TIMEOUT_SEC" _agents_norm "$_af"; _ran=$?
  timed_to_file "$FS_TIMEOUT_SEC" /dev/null rm -f "$_af" || true   # CLAIM:a
  [ "$_ran" = 0 ] && [ -n "$FS_VAL" ] || { AGENTS_JSON=""; AGENTS_OK=0; return 1; }
  AGENTS_JSON="$FS_VAL"
  AGENTS_OK=1
  return 0
}

# Both reached ONLY inside timed_to_file's child, which has closed 9/8/7 already.
_agents_tmp() { mktemp "${TMPDIR:-/tmp}/handoff-agents.XXXXXX"; }   # CLAIM:a
_agents_norm() {
  # CLAIM:a
  "$NODE" -e '
    const fs = require("fs");
    let a;
    try { a = JSON.parse(fs.readFileSync(process.argv[1], "utf8")); } catch { process.exit(1); }
    if (!Array.isArray(a)) process.exit(1);
    process.stdout.write(JSON.stringify(a));
  ' -- "$1"
}

# lookup <json> <id> <field> — matches on either the short id or the full uuid.
lookup() {
  # Bounded at the HELPER, not at the six call sites: `lookup` is reached from
  # watch_once (x2), the duplicate-dispatch check and the verification block
  # (x3), and a per-call-site fix is six edits a seventh call site escapes.
  #
  # fs_get reads ONE line, so a field containing a newline is truncated. Of the
  # fields asked for -- id, sessionId, state, kind, cwd -- only `cwd` could hold
  # one, and a truncated ROW_CWD cannot match CWD_ABS, so the row is not accepted
  # as verified: it fails CLOSED. The alternative is reading the whole answer
  # back with `cat`, which is the unbounded fork this change exists to remove.
  #
  # SPAWN SITE 7. The marker lives in the CALLER, not next to the `node` line it
  # names, because the caller is what bounds it: `_lookup_raw` runs only inside
  # timed_to_file's child, and that child is the thing that closes 9/8/7. Batch 4
  # moved the node call down into the helper and left this marker behind, which
  # is how the numbered list came to describe four call sites in a file with five.
  fs_get "$AGENTS_TIMEOUT_SEC" _lookup_raw "$1" "$2" "$3" || FS_VAL=""
  printf '%s' "$FS_VAL"
}

_lookup_raw() {   # reached only inside timed_to_file's child
  # CLAIM:a
  printf '%s' "$1" | "$NODE" -e '
    let s = "";
    process.stdin.on("data", d => (s += d));
    process.stdin.on("end", () => {
      let a = [];
      try { a = JSON.parse(s); } catch { return; }
      const [id, f] = process.argv.slice(1);
      for (const x of Array.isArray(a) ? a : []) {
        if (x && (x.id === id || x.sessionId === id)) { process.stdout.write(String(x[f] ?? "")); return; }
      }
    });
  ' -- "$2" "$3"
}

# Is there a background session in THIS directory at all?
#
# No registry row names an objective, so this can never say "our successor" —
# only "a background session here". That is enough for the one question asked of
# it: after a launcher exited without naming a session, is "nothing was launched"
# an OBSERVATION or an assumption? Zero rows here, and none whose cwd could not
# be compared, is the observation; anything else is not.
#
# Sets BG_HERE (how many) and BG_AMBIG (rows that could not be placed). Returns 1
# when the registry itself could not be read — never a count of zero, because an
# unreadable registry is not evidence of absence.
BG_HERE=""; BG_AMBIG=""
_bg_here_raw() {   # $1=the agents JSON  $2=the physical cwd to match
  # Both travel as ARGUMENTS. Reading `$AGENTS_JSON` from the enclosing shell
  # while the caller also passed it made the JSON land in `$1`, where the node
  # program reads the directory to match -- so every row compared against a
  # blob of JSON, nothing ever matched, and "no background session here" came
  # back as an OBSERVATION. Reached only inside timed_to_file's child.
  # CLAIM:a
  printf '%s' "$1" | "$NODE" -e '
    const fs = require("fs");
    let s = "";
    process.stdin.on("data", d => (s += d));
    process.stdin.on("end", () => {
      let a;
      try { a = JSON.parse(s); } catch { return; }   // no output at all = unreadable
      const want = process.argv[1];
      let here = 0, amb = 0;
      for (const x of Array.isArray(a) ? a : []) {
        if (!x || String(x.kind ?? "") !== "background") continue;
        const c = String(x.cwd ?? "");
        if (!c) { amb++; continue; }
        // realpathSync is the physical resolution `cd && pwd -P` does, so a row
        // spelled through a symlinked ancestor is not read as somewhere else.
        let r;
        try { r = fs.realpathSync(c); } catch { r = c; }
        if (r === want) here++;
      }
      process.stdout.write(here + " " + amb);
    });
  ' -- "$2"
}

bg_here() { # $1=physical cwd
  BG_HERE=""; BG_AMBIG=""
  read_agents || return 1
  # SPAWN SITE 7, same route as lookup, and for the same reason: this one runs
  # while fd 9 holds the dispatch lock, and timed_to_file's child is the only
  # thing here that both closes the claim descriptors and cannot outlive a
  # deadline. The answer is two numbers on one line, so fs_get can carry it.
  fs_get "$FS_TIMEOUT_SEC" _bg_here_raw "$AGENTS_JSON" "$1" || return 1
  _bh="$FS_VAL"
  case "$_bh" in *" "*) : ;; *) return 1 ;; esac
  _bh1="${_bh%% *}"; _bh2="${_bh##* }"
  case "$_bh1$_bh2" in ''|*[!0-9]*) return 1 ;; esac
  BG_HERE="$_bh1"; BG_AMBIG="$_bh2"
  return 0
}

# row_present <json> <id> — does the list CONTAIN this session at all?
# `lookup` returns "" both for "no such row" and "the row exists but its state is
# empty", and those are opposite conclusions: absent means finished, present with
# an unreadable state means we do not know. Conflating them made a present row
# with state:"" record finished=1 and fire "finished (gone)" while the successor
# was still there (round-3 correctness C1 — reproduced).
#
# TRI-STATE, for the same reason `read_agents` is: the probe not RUNNING is not
# the probe finding nothing. Every way this can fail -- node absent, node
# killed, a fork that could not be made, input that does not parse -- used to
# exit non-zero and be read by the caller as "the id is not in the list", i.e.
# as the successor having finished. `absence-needs-a-probe-that-could-see-
# presence`: before recording "it is gone", the probe that said so has to be one
# that could have said "it is here".
#   0 = present      the list parsed and names this id
#   1 = ABSENT       the list parsed and does not name it  (the only positive no)
#   2 = not observed the probe itself did not complete
row_present() {
  # SPAWN SITE 7, and the one probe that may NOT go through fs_get: fs_get
  # collapses every failure into 2, which would erase the difference between
  # "answered no" (3) and "did not answer" (anything else) -- the whole point of
  # the tri-state. timed_to_file returns the child's own status, and a child
  # killed on the deadline arrives as a signal status, which is "not observed".
  timed_to_file "$FS_TIMEOUT_SEC" /dev/null _row_present_raw "$1" "$2"
  # 3 is deliberately NOT 1: node itself exits 1 on an uncaught exception, so 1
  # cannot mean "answered no" without meaning "crashed" as well. The absent
  # answer gets a code node will not produce by accident, and everything else --
  # 1, 2, 127, a signal -- is "not observed".
  case $? in
    0) return 0 ;;
    3) return 1 ;;
    *) return 2 ;;
  esac
}

_row_present_raw() {   # reached only inside timed_to_file's child
    # CLAIM:a
    printf '%s' "$1" | "$NODE" -e '
    let s = "";
    process.stdin.on("data", d => (s += d));
    process.stdin.on("error", () => process.exit(2));
    process.stdin.on("end", () => {
      let a;
      try { a = JSON.parse(s); } catch { process.exit(2); }
      if (!Array.isArray(a)) process.exit(2);
      const id = process.argv[1];
      for (const x of a) {
        if (x && (x.id === id || x.sessionId === id)) process.exit(0);
      }
      process.exit(3);
    });
  ' -- "$2"
}

# A record is key=value lines, last write wins (state=launching -> pending ->
# verified). A value carrying a newline could therefore forge a LATER key: an
# objective of $'finish\nsession_id=bogus' made the duplicate-dispatch check
# read a session id that does not exist and start a second successor. Values are
# single-line by contract and the contract is enforced at the write, not trusted
# at the call site. rec_set/rec_put return non-zero on any failure; the dispatch
# path treats that as fatal, because a dispatch whose record did not persist is
# a successor nobody remembers.
# READS RETURN THROUGH A GLOBAL, NOT THROUGH `$( )`, and go through the bounded
# fs_get machinery. Both halves are load-bearing and both were found in round 4:
# a substitution leaks the claim descriptors to a child that can outlive the
# holder (L2), and an UNBOUNDED read inside the poll loop is a watcher frozen on
# a hung mount while its lease still reads "someone is watching" (L7). There is
# no `rec_get` any more, deliberately: a call site missed by this conversion
# fails loudly as an unknown command instead of quietly evaluating to empty.
# `tail`'s STATUS IS NOT `sed`'s, and this function used to be nothing but that
# pipeline — so it returned `tail`'s 0 no matter what happened at the other end
# of the pipe. A record this process may not read came back as a SUCCESSFUL read
# of an empty value, and `rec_read`'s documented tri-state below could never take
# its 2: the whole "0 = observed, 2 = not" contract was unreachable at the only
# place that produces it (round 6 micro-review 4, reproduced on a chmod-000
# record — `rec_get_raw` returned 0, `rec_read` returned 0, `REC_VAL` empty).
# Both callers that branch on that return name the harm in their own comments and
# then suffered it: `watch_is_alive` says an unreadable record "is not 'no
# watcher': concluding that arms a second one" and concluded exactly that, and
# `watch_once` says collapsing the two made a hung mount "announce 'no session
# id'", which it then announced. This is the C4 class — an EACCES read as absence
# — at the record layer, the one layer `path_state` had not been carried up to.
rec_get_raw() {
  sed -n "s/^$2=//p" "$1" 2>/dev/null | tail -1   # runs INSIDE fs_get's bounded, fd-closed child   # CLAIM:a
  _rgs="${PIPESTATUS[0]}"
  [ "$_rgs" = 0 ] && return 0
  # `sed` exits 1 both for a record that is NOT THERE and for one it may not
  # read, so its status alone would turn "no such record" into "could not look"
  # and stop a first dispatch from ever arming a watcher. ENOENT is an
  # observation; everything else is a look that did not happen. The errno-aware
  # backend is the same one `file_exists` and `mtime_of` already use, for the
  # same reason and with the same tri-state.
  path_state "$1"; [ "$?" = 1 ] && return 0
  return 2
}
REC_VAL=""
rec_read() { # $1=record $2=key -> REC_VAL; 0 = observed (may be empty), 2 = not
  fs_get "$FS_TIMEOUT_SEC" rec_get_raw "$1" "$2" || { REC_VAL=""; return 2; }
  REC_VAL="$FS_VAL"
  return 0
}
# `--watch` accepts ANY readable record path, so every record value is untrusted
# input — and bash evaluates array subscripts recursively inside arithmetic, so
# `dispatched_epoch=PIPESTATUS[$(cmd)0]` EXECUTED cmd (reproduced: it wrote a
# file). Numbers leave the record only through here: bounded canonical decimal,
# forced to base 10 so `08` is 8 rather than an octal abort. Empty means "no
# usable number", which every caller already handles.
# THE TRI-STATE IS THE RETURN, not the emptiness of REC_NUM: "the key holds no
# usable number" and "I could not read the record" are different facts and the
# one caller has to tell them apart. It used to answer 0 for both, and a single
# timed-out read then became an age of ZERO — the no-transcript alert for a
# successor ten hours silent was skipped and the poll printed "running,
# heartbeat 0m old" instead (round 6, C2 — reproduced).
#   0 = observed ('' = present but not a usable number);  2 = could not read
REC_NUM=""
rec_num() { # $1=record $2=key -> REC_NUM ('' = no usable number)
  REC_NUM=""
  rec_read "$1" "$2" || return 2
  case "$REC_VAL" in ''|*[!0-9]*) return 0 ;; esac
  [ "${#REC_VAL}" -le 18 ] || return 0
  REC_NUM=$(( 10#$REC_VAL ))
  return 0
}
# LAST WRITE WINS, like every other key, so a marker can be CLEARED. The old
# `grep -q '^key=1$'` matched anywhere in the file, which made every alert
# marker permanent: a successor that went blocked, was attended to, and blocked
# again was announced once and then never again (round-4 correctness C6). An
# episode ends by clearing its marker; the next episode alerts on its own.
rec_has() { rec_read "$1" "$2" || return 1; [ "$REC_VAL" = 1 ]; }
rec_clear() { rec_has "$1" "$2" && rec_put "$1" "$2" 0; return 0; }
rec_ok_value() { case "$1" in *"$NL"*|*"$CR"*) return 1 ;; esac; return 0; }
# Anything printed for a human to PASTE is a shell command, and the values in it
# are not this script's. `_short_backgrounded` is `awk '{print $NF}'` over the
# launcher's own stdout — arbitrary non-whitespace text — and the only validation
# it then passes (`rec_ok_value`) rejects a newline and a CR, nothing else. So a
# printed id can carry `;`, a backtick, `$(`, or a quote, and the operator pastes
# it into a shell (round-5 correctness #11). Single-quote it. No subprocess: a
# `sed`-based quoter would be a new unbounded site under the dispatch claim.
#
# MEASURED, and it is why there is no `--` before the operand at the attach
# sites: `claude attach -- <id>` is rejected by the real CLI ("unknown option
# '--'", claude 2026-08-18), so printing one would hand over a command that
# cannot work. `rm` does accept it, and that site passes it. An id that begins
# with a dash therefore still fails at `claude attach` — visibly, as an unknown
# option, which is the failure mode this quoting is not able to remove.
shq() { # $1=value -> SHQ, a single-quoted shell word
  _sq_in="$1"; _sq_out=""
  while :; do
    case "$_sq_in" in
      *"'"*) _sq_out="$_sq_out${_sq_in%%\'*}'\\''"; _sq_in="${_sq_in#*\'}" ;;
      *) break ;;
    esac
  done
  SHQ="'$_sq_out$_sq_in'"
}

rec_set() { printf '%s=1\n' "$2" >> "$1"; }   # CLAIM:d — see rec_put
rec_put() {
  rec_ok_value "$3" || { logline "{\"hook_event_name\":\"HandoffRecordRejected\",\"key\":\"$2\"}"; return 1; }
  printf '%s=%s\n' "$2" "$3" >> "$1"   # CLAIM:d — an append; the reader (last-write-wins on `k=v`) cannot tell a truncated value from a complete one, so a bound trades a hang for a WRONG ANSWER
}

# A STAMPED MARKER IS A FACT PLUS A TIME, and the FACT is the half that has to
# survive a clock that will not answer. Five marker writes were `now_utc` on one
# line and `rec_put <key> "$NOW_UTC"` on the next, so a failed `date` appended
# `monitoring_expired=` — present, and dated to a blank. Nothing broke loudly,
# which is why it lasted: `rec_has` still saw the marker and every test matched
# `key=.*`. But the record is what a human reads to reconstruct what happened,
# and a blank there is a degraded observation wearing the clothes of a value —
# the one invariant this branch exists to hold. The sentinel is not a time and
# cannot be misread as one, and the failure is logged where the loss happened
# rather than inferred later from an empty field.
#   The marker's PRESENCE is never conditional on the clock: refusing to write
#   it would trade a blank timestamp for a lost fact, which is the worse half.
rec_stamp() { # $1=record $2=key -> the key, stamped with now or with the sentinel
  if now_utc; then rec_put "$1" "$2" "$NOW_UTC"; return $?; fi
  logline "{\"hook_event_name\":\"HandoffClockLostAtMarker\",\"key\":\"$2\",\"rec\":\"$1\"}"
  rec_put "$1" "$2" "clock-unavailable"
}

transcript_for() { # $1=session uuid -> path on stdout
  # The projects directory is keyed by a slug of the cwd, which this script does
  # not recompute: the transcript is found by globbing for the session's own
  # uuid, so a slugging rule change cannot silently point the watchdog at
  # nothing.
  #   0 = OBSERVED (a path on stdout, or empty = observed absent).
  #   2 = could not look, which fs_get turns into the caller's DEGRADED arm.
  # `return 0` used to be unconditional, so a projects directory that could not
  # be ENUMERATED — the glob stays unexpanded, `[ -f ]` is false, nothing is
  # printed — arrived at the caller as a clean "this successor has written no
  # transcript". The same C4 mistake as the two fs probes, one layer up and in a
  # different disguise: there the disambiguator was `test -e`, here it is an
  # unmatched glob, and both answer FALSE for "absent" and for "I was not
  # allowed to look". A watcher then raises `notranscript` about a filesystem it
  # cannot read, or clears `alerted_fsdegraded` on the strength of it.
  [ -n "$1" ] || return 0
  for f in "$PROJECTS_DIR"/*/"$1".jsonl; do [ -f "$f" ] && { printf '%s' "$f"; return 0; }; done   # CLAIM:a
  # NO MATCH IS ONLY AN OBSERVATION IF THE SEARCH HAPPENED. `opendir` is the
  # exact permission the glob needs, so it is the exact question to ask: ENOENT
  # (no projects directory at all) is a real absence, anything else is a look
  # that did not happen. The probe runs ONCE, after the loop, so the healthy
  # path — a transcript that exists — never pays for it.
  # KNOWN BLIND SPOT, recorded rather than dressed up: an individual project
  # SUBdirectory that cannot be searched is still invisible here. Enumerating
  # them would cost one probe per project directory on every poll, inside the
  # bounded child, which trades this narrow blind spot for spurious DEGRADED
  # alerts on a large ~/.claude/projects.
  if command -v perl >/dev/null 2>&1; then   # CLAIM:a
    perl -e 'opendir(my $d, $ARGV[0]) or exit($!{ENOENT} ? 1 : 2); closedir($d); exit 0' "$PROJECTS_DIR" 2>/dev/null   # CLAIM:a
    [ $? = 2 ] && return 2
  fi
  return 0
}

# `test -e` and `test -f` answer FALSE for TWO DIFFERENT FACTS — "there is no
# such file" and "I was not allowed to look" — and both fs probes below used one
# of them as their disambiguator, so an EACCES read as absence at both (round 6,
# C4). No amount of re-testing the path fixes that: the distinction lives in
# errno, not in the answer `test` gives back. perl is already a HARD requirement
# of this script — `lock_tool` refuses to run without it, in those words, BECAUSE
# it is the errno-aware backend — so the same tool answers this question.
#   0 = present.  1 = ABSENT, which is an observation.  2 = could not look.
# Anything perl itself does to fail (missing, killed, a broken interpreter) lands
# in 2 as well: the whole point is that a look which did not happen is never a
# fact about the file.
path_state() { # $1=path
  if command -v perl >/dev/null 2>&1; then   # CLAIM:a
    perl -e 'exit 0 if -e $ARGV[0]; exit($!{ENOENT} ? 1 : 2)' "$1" 2>/dev/null   # CLAIM:a
    case $? in 0) return 0 ;; 1) return 1 ;; *) return 2 ;; esac
  fi
  # No perl. `test` is all there is and it cannot tell the two apart; absence is
  # the answer it gives. Recorded as a known blind spot rather than dressed up
  # as a tri-state — and every path that needs a lock has already died by here.
  [ -e "$1" ] && return 0   # CLAIM:a
  return 1
}
mtime_of() { # portable-enough: BSD stat first, then GNU
  # Exit status is the TRI-STATE signal fs_probe reads, so it must separate "not
  # there" (an observation: empty, status 0) from "could not look" (status 2).
  # Collapsing absence into failure is as wrong as the reverse — it makes every
  # missing artifact read as a hung mount.
  stat -f %m "$1" 2>/dev/null && return 0   # CLAIM:a
  stat -c %Y "$1" 2>/dev/null && return 0   # CLAIM:a
  # `[ -e "$1" ] && return 2` was the disambiguator here, and it carried the same
  # blind spot file_exists did: `-e` is false for EACCES as well as for ENOENT,
  # so a stat this process was not ALLOWED to make reported "not there" (round 6,
  # C4). Only a DEFINITE absence is an observation now; present-but-unstattable
  # and could-not-look both stay 2.
  path_state "$1"; [ "$?" = 1 ] || return 2
  return 0
}
file_exists() { # $1=path -> prints 1 when present; the STATUS is the tri-state
  [ -f "$1" ] && { printf 1; return 0; }   # CLAIM:a
  # A heartbeat source that could not be LOOKED AT was indistinguishable from one
  # that does not exist, so a standing `beatdegraded` alert was CLEARED on the
  # strength of it (round 6, C4 — reproduced through a symlinked handoff file
  # whose target directory lost its search bit, with the stat-timeout arm as the
  # control). `mtime_of` has advertised this tri-state since round 3; this is the
  # sibling that never had one. Same vocabulary: absent is an observation
  # (empty, 0), and "I could not look" is 2, which fs_get turns into FSFAIL.
  path_state "$1"; _fe_st=$?
  # 0 here means the path IS there and is not a regular file — a directory, a
  # socket, a dangling symlink's parent. That is an observation too: there is no
  # file heartbeat, and we looked.
  [ "$_fe_st" = 2 ] && return 2
  return 0
}
# Reached only inside timed_to_file's child, like every other probe here.
file_readable() { [ -r "$1" ] && printf 1; return 0; }   # CLAIM:a
_dir_phys() { cd "$1" 2>/dev/null && pwd -P; }   # CLAIM:a
# `claude --bg` writes its "backgrounded <id>" line to a TTY-detected stdout, so
# the id arrives wrapped in CSI colour (`\033[36m<short>\033[39m`, confirmed with
# `od -c`). Both extractors below failed on it TOGETHER — `$NF` carries the
# escapes through verbatim, and `\b[0-9a-f]{8}\b` cannot match either, because
# the `m` closing `[36m` is a word character so there is no word boundary before
# the id. Two failing extractors look like one absent session: every lookup by
# short id missed, and the watcher's absence rule turned "cannot find the row"
# into `finished_how=gone` — a FALSE FINISH on a live successor, after which it
# stood down. Strip CSI at the point of capture so neither extractor ever sees
# it. Idempotent on clean input, which is the only thing this ever saw in test.
_strip_csi() { printf '%s' "$1" | awk '{gsub(/\033\[[0-9;]*[a-zA-Z]/,""); print}'; }   # CLAIM:a
_short_backgrounded() { _strip_csi "$1" | awk '/^backgrounded/{print $NF; exit}'; }   # CLAIM:a
_short_hexid() { _strip_csi "$1" | grep -oE '\b[0-9a-f]{8}\b' | head -1; }   # CLAIM:a
file_is_symlink() { [ -L "$1" ] && printf 1; return 0; }   # CLAIM:a
# The dispatch boundary's three predicates travel as ONE probe: they are asked
# together, of one path, at one instant, and splitting them into three timed
# children would put three separate windows where the code says "at the boundary".
file_dispatchable() { [ -f "$1" ] && [ -r "$1" ] && [ -s "$1" ] && printf 1; return 0; }   # CLAIM:a
# 0 = a legacy DIRECTORY claim is there, 1 = it is not, 2 = could not tell.
legacy_kind() { if [ -L "$1" ]; then printf L; elif [ -d "$1" ]; then printf d; fi; return 0; }   # CLAIM:a

# Run a filesystem probe under a deadline and echo its result, empty on timeout.
# transcript_for globs a directory and mtime_of stats a file; on an unresponsive
# NFS/FUSE mount either blocks indefinitely, and unlike `agents --json` these had
# no deadline — the watch loop would never reach its next poll or alert, looking
# exactly like health. An untimely answer is DEGRADED (empty), same disposition.
# TRI-STATE. `timeout`, `error` and `the artifact is not there` were all the
# empty string, so a hung mount read as "no transcript" and the watcher lost its
# heartbeat silently instead of reporting DEGRADED (round-3 lifecycle 6/7).
# Returns 0 with the value on a successful observation, 2 when the observation
# itself failed. Callers that need the status use fs_get.
# Deliberately NOT `FS_VAL="$(fs_probe …)"`, which is what this was: that
# substitution forks a subshell holding the claim descriptors for as long as the
# probe runs, which is the L2/L7 leak above. timed_to_file's child closes them
# and is bounded; `read` forks nothing. Between them this path can neither leak a
# descriptor nor wait forever, which is what makes it safe to route every
# observation — including every record read — through it.
# Single-line by contract, which every probe here satisfies. `read` returns 1 at
# EOF without a trailing newline and still assigns what it read, hence `|| :`.
FS_VAL=""
# ONE scratch path per process, truncated by every `timed_to_file` (`>"$_of"`),
# never removed here. It used to be a fresh `$$.$SEQ` file per call followed by
# `rm -f` -- and that `rm` ran in the PARENT, outside every deadline, so a hung
# TMPDIR killed the probe on time and then blocked the caller forever on the very
# next line. The bound this function exists to provide was undone by its own
# cleanup. Truncation happens in `timed_to_file`'s deadline-killed child instead,
# which is inside the bound, and it costs one fewer fork on a path every record
# read goes through. The residue is one small file per process in TMPDIR: no
# trap removes it, because an EXIT trap is inherited by every `$( )` subshell
# and would delete the file out from under a probe that is still running.
#
# A FIXED name is a PREDICTABLE name, and that is a property `mktemp` was also
# buying which this rewrite spent without noticing. On a shared /tmp another
# user can create the name first AS A SYMLINK, and `>` follows symlinks: the
# probe that exists to read a value would truncate whatever the link points at.
# So the file is created under `set -C` -- noclobber is O_EXCL|O_CREAT, which
# refuses an existing file AND refuses a symlink -- and the suffix walks when
# the name is taken. `[ -h ]` does not follow the link, so the second branch can
# tell OUR OWN leftover from a reused pid (regular file, our uid, and a sticky
# /tmp means nobody else could have put it there) from a squatted name, without
# which a long-lived box would walk the suffix and eventually degrade.
#
# Both branches run through timed_to_file rather than as a plain redirect and a
# plain `[ -f ]`, for the reason this whole function exists: they are the FIRST
# filesystem operations of the process and they would run in the PARENT, so a
# hung TMPDIR would block them with no deadline -- the same shape as the `rm`
# above, moved from the end of every call to the start of the first one. The
# answers wanted here are exit codes, so the output goes to /dev/null.
# A walk that finds no usable name returns fs_get's own "not observed" (2)
# rather than writing somewhere unverified; every caller already handles it.
_FS_FILE=""
_fs_make() { set -C; : > "$1"; }   # CLAIM:a
_fs_reusable() { [ ! -h "$1" ] && [ -f "$1" ] && [ -O "$1" ]; }   # CLAIM:a
fs_file_init() {
  [ -n "$_FS_FILE" ] && return 0
  _fs_i=0
  while [ "$_fs_i" -lt 8 ]; do
    _fs_try="${TMPDIR:-/tmp}/handoff-fs.$$.$_fs_i"
    if timed_to_file "$FS_TIMEOUT_SEC" /dev/null _fs_make "$_fs_try"; then
      _FS_FILE="$_fs_try"; return 0
    fi
    if timed_to_file "$FS_TIMEOUT_SEC" /dev/null _fs_reusable "$_fs_try"; then
      _FS_FILE="$_fs_try"; return 0
    fi
    _fs_i=$((_fs_i + 1))
  done
  return 1
}
# A DEGRADED OBSERVATION MAY NOT NAME A CAUSE IT DID NOT OBSERVE. `fs_get`
# collapses every failure into 2 on purpose — a caller deciding what to do next
# needs one answer, "I could not look" — but eleven messages then told the
# operator WHY, and all eleven said "timed out", because that is the only cause
# anyone had in mind when they were written. The probes have a second failure:
# `path_state`/`file_exists`/`mtime_of`/`rec_get_raw`/`transcript_for` return 2
# when they could not look — a lost search bit on a parent directory, EACCES,
# EIO — which is not slow and will not clear on its own. An operator told the
# read was killed goes looking for what killed it; an operator told the probe
# could not look goes looking at permissions. Same invariant as the blank
# timestamp: the reading we did not take may not be reported as one we did.
#   The status separates the two: `timed_to_file` returns the child's RAW status,
# so a probe's own "I could not look" is 2 and 128+N is the signal-shaped range.
#   THE STATUS IS THE ONLY THING THAT WAS OBSERVED, and it is now all the text
# claims. This region has been rewritten three micro-reviews running, and the
# first two rewrites were each falsified by the next:
#   - Micro-review 2 replaced eleven messages that all said "timed out".
#   - Micro-review 3's replacement said 128+N meant the bound expired or the
#     probe was signalled from outside. OVERSTATED: a probe that simply
#     `return 143`s makes `wait` report 143 with no signal anywhere, reproduced
#     in micro-review 4 in 0s under a 5s bound, so neither offered source was
#     true. Its `refused` arm said "a permission or I/O failure, not a timeout";
#     also overstated, because `path_state` documents six lines below that a
#     missing, killed or broken interpreter lands in the same 2.
#   - So the arms stopped naming causes at all. They print the status observed
#     and the bound in force, and offer the readings of that status as
#     possibilities. A third round of instance-fixing would have been a fourth
#     sentence to falsify; case DR pins the shape instead of the sentences.
FS_WHY=""
FS_WHY_TXT=""
#   THE VALUE IS `killed`, AND IT WAS NEVER ALLOWED TO BE `timeout`:
# `tests/claim-census.js --audit` scans the decoded source for the bare word
# `timeout`, because a script of this kind reaching for `timeout(1)` inside a
# held claim is exactly the fork the census exists to notice. A `case` label
# spelled `timeout)` is not a command, but the audit cannot tell, and BLUNTNESS
# IS THE POINT of that scan — narrowing it to accommodate one enum value would
# cost more than the name is worth.
fs_why_set() { # $1=killed|refused|error  $2=the bound in force  $3=the status observed, or a note for `error`
  FS_WHY="$1"
  case "$1" in
    killed)  FS_WHY_TXT="the bounded read produced no value and the probe ended with status $3 under a ${2}s bound — a status in that range means the probe was signalled or returned that number itself, and nothing here can tell those apart" ;;
    refused) FS_WHY_TXT="the probe answered \"I could not look\" (status $3) instead of returning a value — that is the one status it has for every way the look can fail to happen, from a permission or I/O error to a helper it could not run" ;;
    *)       FS_WHY_TXT="the bounded read could not be made at all — $3" ;;
  esac
}
# THE SECOND DEGRADED SHAPE, and it needed its own words. `fs_get` returning 0
# with an EMPTY `FS_VAL` is not a failed read at all: the probe ran, returned
# success and printed nothing, because `file_nlink`, `file_ident` and
# `lease_probe` each end in a `printf`/`return 0` that has no way to say why it
# had nothing to say. `FS_WHY_TXT` is cleared to "" on that path, so every site
# that met this shape wrote its own sentence by hand — and every hand-written
# sentence named a culprit nobody watched. Micro-review 3 wrote "`stat` refused"
# at three sites and "could not open the lease file" at a fourth; micro-review 4
# REPRODUCED BOTH BEING FALSE, with a `stat` that exits 0 printing garbage and a
# lock backend that refuses AFTER the open has succeeded. That is three rounds on
# one class, with two of them introduced by the previous round's fix, so the
# words stop being written at the sites: ONE constructor, and it reports only
# what was seen — that the probe answered and the answer was unusable — and
# offers the rest as possibilities, in the shape the lease-backend message
# already uses.
FS_NOVALUE_TXT=""
fs_novalue_set() { # $1=what was asked for, in the operator's words
  FS_NOVALUE_TXT="the $1 ran, returned success and produced no usable value, so nothing here observed why: the tool it uses may be missing, may have refused, or may have answered in a form this script does not accept"
}
fs_get() { # $1=seconds  rest=shell function + args -> FS_VAL; 0 observed, 2 not
  _fgs="$1"; shift
  FS_VAL=""; FS_WHY=""; FS_WHY_TXT=""
  fs_file_init || { fs_why_set error "$_fgs" "the scratch file the read writes its answer into could not be created"; return 2; }
  timed_to_file "$_fgs" "$_FS_FILE" "$@"; _fgr=$?
  if [ "$_fgr" = 0 ]; then
    IFS= read -r FS_VAL < "$_FS_FILE" 2>/dev/null || :
  else
    # The COLLAPSE TO 2 IS DELIBERATE and stays: callers branch on "observed or
    # not", never on how it failed. Only the message the human reads is allowed
    # to know the difference, and it reads it from FS_WHY_TXT.
    if [ "$_fgr" -ge 128 ] 2>/dev/null; then fs_why_set killed "$_fgs" "$_fgr"
    elif [ "$_fgr" = 2 ]; then fs_why_set refused "$_fgs" "$_fgr"
    else fs_why_set error "$_fgs" "the probe ended with status $_fgr, which is neither a signal-shaped status nor its own \"I could not look\""; fi
    _fgr=2
  fi
  return "$_fgr"
}

# Object identity for a path, as "<dev>:<ino>" — empty when neither stat dialect
# is available, and the callers treat empty as "cannot tell" rather than "same".
# `-c` is tried FIRST because it is GNU-only: BSD stat rejects it and falls
# through, whereas GNU stat ACCEPTS `-f` with a different meaning (filesystem
# status), where %i is the filesystem id — a value that is identical for two
# different files on one disk, i.e. an identity check that can never fail. The
# shape is validated for the same reason.
# Reached ONLY through fs_get -> timed_to_file, whose child has already closed
# fds 9/8/7; the substitutions below therefore inherit nothing to leak. Calling
# it directly from a claim-holding context would reintroduce the L2 class.
file_ident() { # $1=path
  _fi="$(stat -c '%d:%i' "$1" 2>/dev/null || true)"   # CLAIM:a
  case "$_fi" in ''|*[!0-9:]*|*:*:*|:*|*:) _fi="" ;; esac
  if [ -z "$_fi" ]; then
    _fi="$(stat -f '%d:%i' "$1" 2>/dev/null || true)"   # CLAIM:a
    case "$_fi" in ''|*[!0-9:]*|*:*:*|:*|*:) _fi="" ;; esac
  fi
  printf '%s' "$_fi"
}

# How many NAMES this inode has. Same dialect order as file_ident and for the
# same reason: `-c` is GNU-only, and GNU `stat -f` is filesystem status, where
# `%l` is the maximum filename length — a number, on every file, that would sail
# through a shape check and mean nothing. Ask the GNU dialect first, so the BSD
# format string is only ever reached on BSD.
# Reached ONLY through fs_get -> timed_to_file, whose child has already closed
# fds 9/8/7 (the L2 class).
file_nlink() { # $1=path -> link count, empty when neither dialect answers
  _fn="$(stat -c '%h' "$1" 2>/dev/null || true)"
  case "$_fn" in ''|*[!0-9]*) _fn="" ;; esac
  if [ -z "$_fn" ]; then
    _fn="$(stat -f '%l' "$1" 2>/dev/null || true)"
    case "$_fn" in ''|*[!0-9]*) _fn="" ;; esac
  fi
  printf '%s' "$_fn"
}

# Resolve a path to the OBJECT it names: the physical directory, plus the final
# component followed through every symlink.
#
# `cd "$(dirname)" && pwd -P` resolves every component EXCEPT the last, so a
# symlink named as the handoff file — or as the record — keeps its own spelling,
# and every claim derived from that string (the lock path, each watcher lease,
# each alert key) is then a claim on a SPELLING rather than on the object. Two
# names for one thing take two locks and both callers win: two paid successors
# for one handoff (round-4 correctness C3), two watchers of which neither stands
# down and each delivers the same alert (round-5 lifecycle #4). ONE authority for
# both callers, so the two cannot drift apart again.
#
# Bounded, because a symlink cycle is a loop `while [ -L ]` cannot leave on its
# own, and it fails CLOSED: a path it could not resolve is never walked on with
# its own spelling.
RESOLVED=""
resolve_path() { # $1=path  $2=noun for the messages -> RESOLVED
  _rp="$1"; _rn="$2"; _rhop=0
  _rd="$( exec 9>&- 8>&- 7>&-; cd "$(dirname "$_rp")" 2>/dev/null && pwd -P )" || die "cannot resolve the directory of the $_rn: $_rp"
  _rp="$_rd/$( exec 9>&- 8>&- 7>&-; basename "$_rp" )"
  while [ -L "$_rp" ]; do
    [ "$_rhop" -lt 40 ] || die "the $_rn resolves through more than 40 symlinks (a link cycle?): $1"
    # `-L` already said this IS a symlink, so a readlink that fails or comes back
    # empty is a DEGRADED read of it -- never "it is not a link after all". The
    # `|| break` that used to stand here left the path at the LINK's own spelling
    # and walked on, which is precisely the two-identities-for-one-object bug
    # this loop exists to close.
    #
    # `$( )` strips EVERY trailing newline, so a link whose target literally ends
    # in one resolved to the SIBLING at the stripped name -- a different file,
    # which then passed validation and received the paid dispatch (round-5
    # correctness #0).
    # STRIPPING THE NEWLINE BACK OFF DOES NOT FIX IT, and that was the first
    # attempt here. `readlink` without `-n` prints the target's bytes AND a
    # newline, on BSD and GNU alike, so "sib.md" and "sib.md<LF>" produce the
    # BYTE-IDENTICAL output "sib.md<LF>" -- the information needed to tell them
    # apart is gone before the shell sees it, and any amount of stripping picks
    # one of the two files by guesswork. Measured on this machine: both spellings
    # give the same 17 bytes. `-n` asks for the target and nothing else, and is
    # understood by both dialects (this is the same dialect discipline as
    # `file_ident`'s `stat -c` / `stat -f`, except that here the WRONG answer is
    # not rejectable by shape -- it is a valid path to the wrong file).
    # A readlink that does not understand `-n` exits nonzero and this refuses,
    # which is the correct answer: a target that cannot be read exactly cannot be
    # resolved to one object.
    _rl="$( exec 9>&- 8>&- 7>&-; readlink -n "$_rp" 2>/dev/null && printf x )" || _rl=""
    _rl="${_rl%x}"
    [ -n "$_rl" ] || die "cannot read the symlink $_rp (it may have been replaced while the path was being resolved) — refusing to act on an unresolved path"
    rec_ok_value "$_rl" || die "the symlink $_rp names a target that spans lines (it contains a newline or carriage return) — refusing, because such a path can neither be recorded nor resolved to one object"
    case "$_rl" in
      /*) _rp="$_rl" ;;
      *)  _rp="$( exec 9>&- 8>&- 7>&-; dirname "$_rp" )/$_rl" ;;
    esac
    _rd="$( exec 9>&- 8>&- 7>&-; cd "$(dirname "$_rp")" 2>/dev/null && pwd -P )" || die "cannot resolve the directory of the symlink target of $1"
    _rp="$_rd/$( exec 9>&- 8>&- 7>&-; basename "$_rp" )"
    _rhop=$(( _rhop + 1 ))
  done
  RESOLVED="$_rp"
}

# -------------------------------------------------------------------- locking
# ONE primitive for every ownership claim here — the dispatch lock, each watcher
# lease, each alert — and its lifetime belongs to the KERNEL, not to a heuristic.
#
# Two designs preceded this one and both failed in the same place. `mkdir` plus a
# pid file has a pid-LESS window in which a live owner is indistinguishable from
# a corpse. `link(2)` closed that window by staging the pid before the claim
# existed, but a claim identified by a PATH still cannot express object identity:
#   * `claim_break_if_dead` read the owner, tested `kill -0`, then `mv`'d — and
#     `mv` binds the PATHNAME, not the object that was inspected. A breaker that
#     paused between the read and the move removes whatever is at that path when
#     it finally acts, which can be the WINNER'S FRESH CLAIM. Reproduced
#     deterministically (test case BA); a neighbouring interleaving launches TWO
#     successors.
#   * `kill -0 <recorded pid>` cannot tell a dead owner from a RECYCLED pid, so
#     reclaiming is either unsafe or refuses forever.
#   * every crash leaves a corpse that some age or grace value has to reap, and
#     no such value is correct — which is what both rewrites were spent on.
# `flock(2)` has none of these. The lock lives on the open file description, the
# kernel releases it when the last descriptor referring to that description is
# closed — including when the holder is SIGKILLed — and acquisition is atomic
# against every other acquirer. No owner field, no token, no corpse, no age,
# nothing to reclaim, and no cleanup path that can be got wrong.
#
# `flock(1)` is NOT present on macOS (verified here), so the acquire is delegated
# to perl, which is (5.34). Both act on the descriptor THIS SHELL holds open
# (`exec 9>>file`) rather than opening their own: perl's `open($fh, ">&=", $fd)`
# is fdopen, not dup, so the lock is taken on our description and outlives the
# helper process. Verified on this machine: still held after the helper exits,
# refused to a second acquirer, released by the kernel on SIGKILL.
#
# THE ONE RULE FOR CALLERS. Every process spawned while a lock is held must close
# the lock descriptors (`9>&- 8>&- 7>&-`). An inherited descriptor keeps the
# description alive, so a child outliving the holder extends the lock past the
# holder's death — verified both ways: a `sleep 5` child held a SIGKILLed
# holder's lock for its full five seconds, and the same child spawned with `9>&-`
# released it instantly. It is also a CORRECTNESS rule and not only hygiene: a
# probe that inherits the lease descriptor re-locks its own description, which
# always succeeds, so an unclosed fd 8 makes a live watcher read as dead.
# A COMMAND SUBSTITUTION IS A SPAWN SITE TOO, and the previous version of this
# comment claimed a scope it did not have: it enumerated the places that run an
# external command and missed every `$( … )` and every pipeline element, which
# are forked children inheriting the same descriptors. Reproduced in round 4: a
# holder SIGKILLed inside `$(sed … | tail)` left its lease HELD until the
# orphaned child exited. Two rules follow, and the code obeys both:
#   * a helper whose value is wanted under a claim returns through a GLOBAL
#     (`rec_read`/`REC_VAL`, `fs_get`/`FS_VAL`, `epoch`/`EPOCH`,
#     `now_utc`/`NOW_UTC`, `lease_file_of`/`LEASE_FILE`) — no fork at all;
#   * where a substitution is unavoidable it OPENS with `exec 9>&- 8>&- 7>&-`,
#     so the subshell itself loses the descriptors before it runs anything.
# SPAWN SITES — enumerated, classified and counted, because "did every site get
# it" is not answerable by looking at any one of them. The enumeration comes in
# TWO parts, and saying so is the point: the numbered list below covers every
# site that invokes an EXTERNAL COMMAND while a lock can be held AND closes the
# descriptors — two smaller groups follow it for the sites that need neither —
# and it is the part that has to be read one site at a time. The substitution
# class is the other part and is NOT in that list: it is closed by construction
# and countable instead of readable:
#
#     grep -c '^[^#]*( exec 9>&- 8>&- 7>&-' hooks/handoff.sh   # SPAWN_SUBSHELLS=20
#
# (anchored past a leading `#` so this very line does not count itself — a
# self-counting probe is a probe that can never fall behind the code)
#
# ...which is true only of the PROBE. The NUMBER is a different claim, and it
# had already fallen behind: batch 2 added three substitutions and left this
# line reading 34, because nothing ever compared it to anything. A number in a
# comment that no test evaluates is not a control — it is a note that happens to
# be wrong. Case CM runs the grep and asserts it equals the value tagged above,
# so the two cannot drift again; the `SPAWN_SUBSHELLS=` tag is what the test
# parses, and changing either half alone fails the suite. Batch 4 then moved it
# DOWNWARD, 37 to 19, by routing the probes that used to be substitutions
# through `fs_get`, which hands its value back in a global and forks nothing:
# the number is a measurement, not a ratchet, and a fall is as much a signal as
# a rise.
#
# Every `$( … )` and every subshell in this file that can run under a claim opens
# with that sequence, so the count is the coverage: a new substitution written
# without it is a diff no reviewer has to spot, because the number moves. The
# earlier version of this comment gave one number for both parts, which is how a
# list of thirteen came to describe a file with fifty-odd forks in it.
#
# The numbered list is a claim of exactly the same kind, and it went wrong in
# BOTH directions in batch 4 while the number above it stayed honest: `lookup`
# lost its marker when the node call moved into a helper, so the list named a
# site the code no longer marked, and the temp-file `rm` in fs_get stopped
# existing at all, so the list named a site the code no longer had. Neither is
# visible from any one line. Case CM now reconciles the list against the code in
# both directions — every number in the list has a marker somewhere in the file,
# every marker in the file has a number in the list, the numbers run 1..N with
# no gap or repeat, and the headline count equals the length of the list it
# heads — so the enumeration is checked at the same grain as the count.
#
# SPAWN-LIST-BEGIN   (parsed by case CM; markers are counted OUTSIDE this block)
#   ONE ENTRY PER LINE, `#` + spaces + the number + a space. That is a parsing
#   contract, not a layout preference: the two-column version of this list hid
#   sites 5 and 7 from every line-oriented reader, which is the same way the
#   list went stale in the first place.
#   An entry marked in more than one place says so as `at <k> call sites`, and
#   the k is checked. Without it the reconciliation is per-NUMBER, so the very
#   regression that prompted it — one of site 7's five markers going missing —
#   would still read as covered by the other four.
#   CLOSES THE DESCRIPTORS (11), each marked `SPAWN SITE <n>` at its line:
#     1 timed_to_file, the timed command  (covers `claude agents --json` AND
#       every filesystem probe, so this one close is what keeps lease_probe from
#       re-locking its own parent's description)
#     2 timed_to_file, the kill watchdog subshell
#     3 timed_to_file, the pkill grandchild sweep
#     4 notify, osascript (Darwin)
#     5 notify, notify-send (Linux)
#     6 read_agents, mktemp
#     7 node, at 5 call sites, each marked in the CALLER that bounds it
#       rather than at the `node` line it names, because the caller is what
#       holds the deadline: read_agents, lookup, bg_here, row_present, status
#     8 arm_watch, `nohup "$0" --watch`, which must never inherit fd 9
#     9 arm_watch, the arm-proof `sleep 0.1`, which holds fd 9
#    10 dispatch, `claude --bg` — the successor itself, the site that matters most
#    11 watch_loop, `sleep "$POLL_SEC"`, which holds fd 8 for hours
#   NOTHING IS HELD, so nothing to close (3): watch_loop's lease-retry `sleep 0.1`
#     (the lease is not taken yet and fd 9 was closed at spawn); claim_lock's
#     `tail -1` of the diagnostic line, which runs only after the take FAILED;
#     close_lane's `tail -1` of the same diagnostic shape, which likewise runs
#     only in the branch where lock_hold answered "someone else holds it".
#   DELIBERATE INHERITANCE (1): lock_take's perl, which must receive the TARGET
#     descriptor open — locking OUR description is the entire point. It closes
#     the OTHER two: taking the alert lock must not hand perl the lease.
#   RETIRED: fs_get's per-call temp-file `rm` was site 12 until batch 4 gave the
#     function one fixed file per process. Its number is not reissued: a marker
#     reading `SPAWN SITE 12` in some later diff would then mean two different
#     things depending on which version of this list you read it against.
# SPAWN-LIST-END
#
# Fixed descriptor numbers, because bash 3.2 (macOS) has no `exec {var}>`:
#   9 = the dispatch lock   8 = a watcher's generation lease   7 = an alert
# The lock FILE is never unlinked. It holds one diagnostic line, and unlinking it
# would reintroduce the pathname-identity bug this design exists to remove: two
# processes could hold locks on two different inodes at the same path.
LOCK_TOOL=""
DISPATCH_LOCK=""

# THE BACKEND MUST BE ABLE TO READ ERRNO. That is a requirement, not a
# preference, and it is why there is exactly one backend here.
#
# `flock -n` exits 1 for contention AND for ENOLCK/ENOTSUP/EBADF, so on a
# filesystem that cannot lock at all it reports "someone else holds it".
# lease_probe reads that as "a watcher is alive", records the successor as
# watched, and leaves nobody watching (round-4 lifecycle L3). Preferring perl
# only DEMOTED that: on a host with perl missing and flock(1) present, the
# script silently fell back to the backend whose answers it cannot trust, and
# two watchers could each read the backend's error as the other one and BOTH
# stand down (round-5 lifecycle L5).
#
# An ambiguous answer is not the safe answer, so the fallback is gone rather
# than demoted — the same disposition as the legacy lock in claim_lock. A host
# with no errno-aware backend REFUSES TO ARM instead of inventing a watcher,
# which is a loud failure a human fixes in one `xcode-select --install`, rather
# than a quiet one nobody sees until a successor stalls unwatched.
lock_tool() {
  [ -z "$LOCK_TOOL" ] || return 0
  # Test seam: every machine this runs on HAS perl, so `noperl` is the only way
  # to reach the refusal below — and reaching it is the whole point of removing
  # the fallback. Read before the probe, in the same shape as lock_take's.
  if [ "${CLAUDE_HANDOFF_LOCK_TOOL_DEBUG:-}" != noperl ] && command -v perl >/dev/null 2>&1; then   # CLAIM:d — a PATH search, at most once per process — and it is how the bounding-capable backend is FOUND, so bounding it needs the thing it is looking for
    LOCK_TOOL="perl"; return 0
  fi
  # Fails CLOSED, and only where a lock is actually needed, so --status and
  # --help still work on a box without it.
  die "no errno-aware file-locking backend is available (perl is required; flock(1) is deliberately NOT accepted, because it cannot distinguish contention from a filesystem that cannot lock at all) — refusing to dispatch or watch"
}

# Take the lock on an ALREADY-OPEN descriptor.
#   0 = we hold it
#   1 = SOMEONE ELSE holds it (EWOULDBLOCK/EAGAIN — measured 35 on this machine)
#   3 = the lock backend could not answer, which is NOT evidence either way
# Callers must never collapse 1 and 3: for the dispatch lock the difference is
# harmless (both refuse), but for a liveness probe 3-read-as-1 invents a watcher.
_LOCK_PL='use Fcntl qw(:flock); use Errno qw(EWOULDBLOCK EAGAIN);
open(my $fh, ">&=", $ARGV[0]) or exit 3;   # fdopen, NOT dup
exit 0 if flock($fh, LOCK_EX | LOCK_NB);
exit(($! == EWOULDBLOCK || $! == EAGAIN) ? 1 : 3);'
lock_take() { # $1=fd
  # Test seam: makes the "the backend cannot answer" path reachable without
  # having to break a real filesystem. It must be read BEFORE lock_tool, which
  # dies when no tool exists. `broken` breaks every descriptor; `broken:<fd>`
  # breaks exactly one, which is what makes the two OPPOSITE consequences of a
  # broken backend separable: the dispatch lock fails CLOSED (it refuses), while
  # the lease fails OPEN unless the tri-state is honoured (round-4 lifecycle L3).
  case "${CLAUDE_HANDOFF_LOCK_DEBUG:-}" in
    broken) return 3 ;;
    "broken:$1") return 3 ;;
  esac
  lock_tool
  if [ "$LOCK_TOOL" = "perl" ]; then
    # The ONE deliberate descriptor inheritance in this script: perl must
    # receive fd $1 open, because locking OUR description is the whole point.
    # The other two are closed — a probe of the alert lock that inherited fd 8
    # would be holding the lease it is about to ask about.
    case "$1" in
      9) perl -e "$_LOCK_PL" 9 8>&- 7>&- 2>/dev/null; return $? ;;   # CLAIM:d — perl must INHERIT the descriptor it locks; timed_to_file closes 9/8/7 in its child, so that route would defeat the operation. LOCK_EX|LOCK_NB cannot block on the lock; the residual is perl process startup
      8) perl -e "$_LOCK_PL" 8 9>&- 7>&- 2>/dev/null; return $? ;;   # CLAIM:d — see fd 9 above
      7) perl -e "$_LOCK_PL" 7 9>&- 8>&- 2>/dev/null; return $? ;;   # CLAIM:d — see fd 9 above
      *) return 3 ;;
    esac
  fi
  # Unreachable: lock_tool either set "perl" or died. Kept as a fail-closed
  # floor so a future backend added above cannot fall through into a silent
  # "someone else holds it" — the answer that invents watchers.
  return 3
}

# A LOCKING PRIMITIVE NEVER DELETES, RENAMES OR TRUNCATES THE THING IT LOCKS.
# The previous version swept a legacy directory here with `rm -rf` before
# opening the path — and `rm -rf` removes a regular file just as happily, so two
# dispatchers that both evaluated `[ -d ]` before either swept could each unlink
# the other's LIVE lock file and lock a fresh inode at the same pathname. Both
# then held "the" lock and both reached `claude --bg`. That is the
# pathname-identity bug P4 exists to remove, re-entering through the migration
# path; reproduced in round 4 (L1: two inodes, both HOLD). Nothing here removes
# anything now: a legacy claim is REPORTED and refused — see legacy_lock_present.
# 0 = we hold it, 1 = someone else holds it, 2 = we could not tell (the path is
# unopenable, or the lock backend itself failed) — never evidence about who
# holds what.
lock_hold() { # $1=fd  $2=path
  # A symlink at the lock path is not our file. Opening through it locks — and
  # the old diagnostic write TRUNCATED — whatever it points at (round-4
  # correctness C1). Refuse; there is no legitimate reason for one to be here.
  # An unobservable `-L` is already this function's 2 ("we could not tell"), so
  # bounding it needs no new vocabulary and cannot turn a hung mount into a
  # statement about who holds the lock.
  fs_get "$FS_TIMEOUT_SEC" file_is_symlink "$2" || return 2
  if [ "$FS_VAL" = 1 ]; then
    logline "{\"hook_event_name\":\"HandoffLockPathIsSymlink\",\"lock\":\"$2\"}"
    return 2
  fi
  eval "exec $1>>\"\$2\"" 2>/dev/null || return 2   # CLAIM:d — the open IS the lock; a descriptor opened in a killed child is not ours
  lock_take "$1"; _lh=$?
  [ "$_lh" = 0 ] && return 0
  eval "exec $1>&-" 2>/dev/null || true   # CLAIM:b — a close
  [ "$_lh" = 1 ] && return 1
  return 2
}

# The predecessor's claim was a DIRECTORY; P4's lock files carry a `.flock`
# suffix that predecessor never used, so the legacy path and the locked path can
# never be the same object. This REPORTS a legacy claim and does not remove it:
# see claim_lock for why removing it is a decision this layer cannot make.
# TRI-STATE, because bounding it otherwise would make a hung mount say "no
# legacy claim is here" -- a degraded observation becoming a value, which is the
# defect this whole branch is about.
#   0 = a legacy directory claim is there   1 = it is not   2 = could not tell
legacy_lock_present() { # $1=LEGACY path (never a .flock path)
  fs_get "$FS_TIMEOUT_SEC" legacy_kind "$1" || return 2
  [ "$FS_VAL" = d ] || return 1
  logline "{\"hook_event_name\":\"HandoffLegacyLockPresent\",\"lock\":\"$1\"}"
  return 0
}

lock_drop() { # $1=fd — closing the descriptor IS the release
  eval "exec $1>&-" 2>/dev/null || true   # CLAIM:b — a close
}

verify_lock() { # dies unless we still hold the dispatch lock
  [ -n "$DISPATCH_LOCK" ] || die "internal error: no dispatch lock is held"
  # The kernel cannot hand this lock to anyone else while we hold it, so the only
  # thing a fence can still catch is our OWN descriptor being closed by a bug,
  # which would silently drop the lock. Re-taking it on the same description is a
  # no-op while we hold it and impossible once fd 9 is gone.
  lock_take 9; _vl=$?
  [ "$_vl" = 0 ] && return 0
  # A STATUS IS NOT A CAUSE, AND THIS FENCE USED TO READ ONE AS THE OTHER: every
  # non-zero said "the dispatch lock's descriptor is no longer open". `lock_take`
  # answers 1 only for EWOULDBLOCK, and 3 for EVERY other way the question could
  # not be answered — fd 9 closed (perl's `open(">&=")` fails), a mount that
  # cannot lock at all, an fd this backend does not handle, the debug seam.
  # Reproduced with `CLAUDE_HANDOFF_LOCK_DEBUG=broken:9` against a descriptor
  # that was demonstrably still open (round 6 micro-review 5): the refusal was
  # right, the reason was invented. So the descriptor is OBSERVED here rather
  # than inferred from the status — a duplication of fd 9 in a subshell, which
  # is a question this process can answer without the lock backend and without
  # touching the lock. Both readings still refuse: the fence fails CLOSED
  # whatever the answer, and now it fails closed for a reason it watched.
  # THE OBSERVATION AND THE INTERPRETATION ARE SEPARATE STRINGS, and the first
  # version of this fix put an interpretation inside the observation: it read
  # "the descriptor is still open, so it is the lock backend that could not
  # answer", which the status-1 branch below then appended to "reports as held
  # by someone else". One refusal said the backend both answered and could not
  # answer (round 6 micro-review 6, reproduced end to end with a `lock_take`
  # that returns 1 while fd 9 is open). Status 1 is EWOULDBLOCK: the backend DID
  # answer. So this holds only what was watched, and each `die` says what its own
  # status means.
  if ( true >&9 ) 2>/dev/null; then   # CLAIM:b — a descriptor duplication in a subshell; it writes nothing and cannot block
    _vlfd="this process's descriptor for it is still open"
  else
    _vlfd="this process's descriptor for it is gone"
  fi
  # EWOULDBLOCK. The backend answered, and what it answered is that a lock
  # conflicting with this request is held. `flock` on a description we already
  # hold returns success, so the description behind fd 9 is NOT the one holding
  # this file's lock — that is a deduction from the backend's own answer, and it
  # is offered as one rather than dressed as an observation.
  [ "$_vl" = 1 ] && die "the dispatch lock at $DISPATCH_LOCK came back from the lock backend as held by a DIFFERENT open file description, and $_vlfd — either way this process can no longer show the lock is its own, so it refuses to continue rather than risk two successors being started"
  die "the dispatch lock at $DISPATCH_LOCK could not be re-checked: the lock backend answered $_vl, which is not an answer about who holds it, and $_vlfd — refusing to continue so two successors cannot be started"
}

# A refusal at a dispatch-boundary fence must not park the record in the one
# state that refuses every later retry. Every fence that uses this dies BEFORE
# the launcher at the spawn site, so nothing was started, and the honest record
# of that is its own value. `launching` cannot say it (it means "a successor may
# exist that no id names") and neither can `failed` (the launcher ran; the
# registry proved nothing was backgrounded). One enum value per meaning —
# round-5 correctness #4, where every fence's own message promised a retry that
# the duplicate-dispatch guard then refused.
# DELIBERATELY NOT routed through this: `verify_lock`. If the claim cannot be
# verified the record may already belong to another dispatcher, and writing to
# it is the one thing that must not happen.
prelaunch_die() { # $1=record $2=message
  if rec_put "$1" state prelaunch_failed; then
    die "$2 (nothing was launched: the record is left at state=prelaunch_failed, so a plain retry is safe and needs no --force)"
  fi
  die "$2 (nothing was launched, but the record $1 could not be updated to say so — it stays at state=launching, so a retry will refuse until you pass --force)"
}

claim_lock() { # $1=lock path (.flock)  $2=the LEGACY path this design replaced
  # A legacy DIRECTORY at $2 is a claim in the predecessor's shape, and this
  # layer cannot tell a live pre-upgrade launcher from the corpse of one — the
  # mkdir claim has a pid-LESS window, which is the defect that retired it.
  # Sweeping it is deciding, on no evidence, that nobody holds it; if somebody
  # does, both dispatches launch and the handoff is paid for twice (round-5
  # lifecycle #2). Refuse, and name the command the operator runs once they have
  # checked. The cost is zero: the mkdir-shaped claim only ever existed on this
  # branch, before round 3, so no machine is in this state.
  legacy_lock_present "$2"; _llp=$?
  [ "$_llp" = 2 ] && die "could not tell whether a lock in the previous design's shape is still at $2 — $FS_WHY_TXT, and dispatching on an observation that was never made is how two successors get started for one handoff"
  if [ "$_llp" = 0 ]; then
    shq "$2"
    die "a lock in the previous design's shape is still at $2 — refusing to dispatch, because nothing here can tell whether a pre-upgrade launcher still holds it, and removing it while one does would start a second successor for this handoff. Confirm no handoff.sh from before the .flock locks is running, then remove it by hand: rm -rf -- $SHQ"
  fi
  lock_hold 9 "$1"; _rc=$?
  [ "$_rc" = 2 ] && die "could not take the dispatch lock at $1 — the path is unopenable, a symlink, or the lock backend did not answer; refusing to dispatch, because without an exclusive lock two successors can be started for the same handoff"
  if [ "$_rc" != 0 ]; then
    # Runs only after the take FAILED, so no claim is held and nothing to close.
    # `tail`, not `head`: the diagnostic is APPENDED, so the last line is the
    # current holder and the first is whoever held it months ago.
    _lw="$( exec 9>&- 8>&- 7>&-; tail -1 "$1" 2>/dev/null || true )"
    die "another dispatch for this handoff holds the lock and is still running — not starting a second successor (lock: $1${_lw:+ — the lock file says: $_lw})"
  # CLAIM-REGION-BEGIN claim
  fi
  # Diagnostics ONLY — nothing reads this back to make a decision, the lock is
  # the kernel's — written THROUGH THE HELD DESCRIPTOR. A write by PATH follows a
  # symlink and truncates whatever it points at; the descriptor is the only thing
  # we have proven is ours. It appends one line per successful dispatch, which is
  # a handful over a handoff's life.
  now_utc || true   # THE ANNOTATION CONSUMER. A clock reading may be spent in
  # exactly three ways and this is one of them: inside `rec_stamp`, which
  # substitutes the sentinel; in the dispatch pair, written only when
  # `now_utc && epoch` both succeeded; and here, where it neither persists nor
  # decides but annotates the lock file for a human. (This comment used to
  # number it "the SEVENTH and last consumer", which was true before `rec_stamp`
  # folded five of them into one and stale afterwards — the count is now derived
  # by case DP rather than remembered here.) It still may not print a blank where
  # a time belongs, so it borrows rec_stamp's sentinel rather than its own
  # spelling.
  printf 'last acquired by pid %s at %s (informational only: whether it is held NOW is the kernel'"'"'s answer, not this line'"'"'s)\n' \
    "$$" "${NOW_UTC:-clock-unavailable}" >&9 2>/dev/null || true   # CLAIM:d — see rec_put
  DISPATCH_LOCK="$1"
  # No retry loop and nothing to reclaim: a held lock means a LIVE holder by
  # construction, and a dead holder's lock is already gone. The old three-attempt
  # loop existed only to retry after breaking a corpse.
  #
  # No signal trap either, and that is the fix rather than an omission.
  # `trap release_lock EXIT INT TERM` ran cleanup and then RESUMED, so a TERM
  # arriving between the last fence and `claude --bg` released the lock and still
  # spawned a successor. There is now no cleanup to run — process exit closes the
  # descriptor and the kernel releases the lock — and the default action for
  # INT/TERM terminates, which is exactly what is wanted.
  # CLAIM-REGION-END claim
}

# --------------------------------------------------------------- watch leases
# "Is this successor watched" must NEVER be answered by `kill -0 <stored pid>`:
# a pid is not an identity. Once a watcher exits its number is reused, and a
# review reproduced reconciliation accepting an unrelated live process as the
# watcher — leaving a live successor unwatched, the exact failure this script
# exists to prevent. So the record carries a watcher GENERATION and the watcher
# HOLDS an exclusive lock on that generation's lease file for its entire life.
# "Is a watcher alive" then has a kernel answer — can this lock be taken? — with
# no pid, no mtime, no staleness multiple, and no window in which a watcher that
# died a moment ago still reads as alive.
# Sets a global rather than echoing, because `$(watch_lease_file …)` was a
# command substitution running while the lease was held — see THE SUBSTITUTION
# RULE above. Pure parameter expansion forks nothing.
# The path keeps its `.watch.<generation>` shape while the dispatch lock and the
# alert claims moved to `.flock`: those two have a mkdir-shaped predecessor at
# their pathname on every upgrading machine, and this one cannot — a generation
# is minted fresh at every arm, so nothing has ever existed at this path before.
LEASE_FILE=""
lease_file_of() { LEASE_FILE="$1.watch.$2"; }

# Runs in a bounded SUBSHELL (via fs_get), for two reasons: the descriptor must
# not survive in the asking process, and `exec` on a path under an unresponsive
# mount blocks forever — an unbounded liveness probe inside the poll loop is the
# hang that looks exactly like health.
lease_probe() { # $1=lease path -> prints "held", "free", or nothing at all
  lock_hold 8 "$1"; _lp=$?
  # CLAIM-REGION-BEGIN lease
  [ "$_lp" = 0 ] && { lock_drop 8; printf 'free'; return 0; }
  # CLAIM-REGION-END lease
  [ "$_lp" = 1 ] && { printf 'held'; return 0; }
  return 0   # 2: could not tell. Say NOTHING — the caller reads silence as
             # DEGRADED, which is neither of the two real answers.
             #   This comment used to read "could not even open it", which is
             # one of the FOUR ways `lock_hold` produces 2 and the only one it
             # names: an unobservable `-L`, a symlink at the lock path, the open
             # itself, and a lock backend that cannot answer AFTER the open
             # succeeded. The same overstatement the messages one layer up were
             # corrected for, left behind in a comment (round 6 micro-review 5).
}

WATCH_UNKNOWN=0
# WHY it could not tell, for the one alert that reports this state. THREE PATHS
# SET `WATCH_UNKNOWN`, and only two of them are failed reads with an `FS_WHY_TXT`
# to quote: the third is a probe that ANSWERED — successfully — and said
# nothing. Reporting that third path as "the filesystem did not answer" was the
# same defect one layer up as the one `fs_why_set` exists to prevent: a degraded
# observation may not name a cause it did not observe (round 6 micro-review 3).
# So each set-site publishes its own reason here, at the point where it is known,
# rather than letting the alert guess from a variable that is EMPTY on exactly
# that path.
#   Corrected in micro-review 4, and the original claim was overstated: this
# comment used to finish "because `lock_hold` could not open the lease file at
# all", and the message said so too. `lock_hold` returns 2 from four places, and
# only ONE of them is the open — a lock backend that refuses AFTER a successful
# open reaches the same 2, reproduced with the `broken:8` seam against a lease
# file this process had just locked and unlocked. The third path now goes through
# `fs_novalue_set`, which asserts nothing about which component was at fault.
WATCH_UNKNOWN_WHY=""
watch_is_alive() { # $1=record — sets WATCH_UNKNOWN=1 when it could not tell
  WATCH_UNKNOWN=0; WATCH_UNKNOWN_WHY=""
  # An unreadable record is not "no watcher": concluding that arms a second one.
  rec_read "$1" watch_gen || { WATCH_UNKNOWN=1; WATCH_UNKNOWN_WHY="the record could not be read: $FS_WHY_TXT"; return 0; }
  [ -n "$REC_VAL" ] || return 1
  lease_file_of "$1" "$REC_VAL"
  fs_get "$FS_TIMEOUT_SEC" lease_probe "$LEASE_FILE" || { WATCH_UNKNOWN=1; WATCH_UNKNOWN_WHY="the watchdog's lease could not be probed: $FS_WHY_TXT"; return 0; }
  [ "$FS_VAL" = held ] && return 0
  # "free" is a definite answer; empty is not. An empty value means the probe
  # returned without saying anything, which is not evidence that nobody is
  # watching — unobservable liveness counts as watched, and says so.
  [ "$FS_VAL" = free ] || { WATCH_UNKNOWN=1; fs_novalue_set "watchdog-lease probe on $LEASE_FILE"; WATCH_UNKNOWN_WHY="the lease probe reported neither held nor free: $FS_NOVALUE_TXT"; return 0; }
  return 1
}

# arm_watch <record> -> echoes the generation it armed, empty on failure.
arm_watch() {
  _ar="$1"
  epoch
  _ag="$EPOCH.$$.${RANDOM:-0}"
  # The generation is durable BEFORE the fork. Without it, a launcher killed
  # between the fork and the record write left a watcher that the record did not
  # name, so the next dispatch armed a SECOND one against the same record and
  # both alerted.
  rec_put "$_ar" watch_gen "$_ag" || return 1
  # SPAWN SITE 8: the watcher OUTLIVES this dispatch by design, so inheriting
  # the dispatch lock would keep it held for the successor's whole life and every
  # later dispatch for this handoff would refuse.
  nohup "$0" --watch "$_ar" --watch-gen "$_ag" --heartbeat-min "$HEARTBEAT_MIN" --poll-sec "$POLL_SEC" >/dev/null 2>&1 9>&- 8>&- 7>&- &   # CLAIM:b
  _ap=$!
  # Proof of arming is that the watcher HOLDS ITS LEASE — not that our `&`
  # returned, and not that the lease file appeared. The file appears the instant
  # the watcher opens it, which is BEFORE it has taken the lock; a launcher that
  # reports "watched" on its own fork succeeding is the status-flag mistake this
  # script is supposed to avoid. Bounded, like every filesystem observation here.
  _aw=0
  lease_file_of "$_ar" "$_ag"; _alf="$LEASE_FILE"
  while [ "$_aw" -lt 60 ]; do
    fs_get "$FS_TIMEOUT_SEC" lease_probe "$_alf"
    [ "$FS_VAL" = held ] && break
    kill -0 "$_ap" 2>/dev/null || break   # CLAIM:b
    sleep 0.1 9>&- 8>&- 7>&-   # SPAWN SITE 9: holds fd 9   # CLAIM:c
    _aw=$(( _aw + 1 ))
  done
  fs_get "$FS_TIMEOUT_SEC" lease_probe "$_alf"
  [ "$FS_VAL" = held ] || return 1
  # DIAGNOSTIC ONLY, and deliberately not the liveness signal: an operator wants
  # something to `ps`. Every liveness decision goes through lease_probe above.
  rec_put "$_ar" "watch_pid_$_ag" "$_ap" || true
  printf '%s' "$_ag"
}

# ---------------------------------------------------------------- watch-once
watch_once() {
  REC="$1"
  fs_get "$FS_TIMEOUT_SEC" file_readable "$REC" || die "could not tell whether the record $REC is readable — $FS_WHY_TXT; refusing to watch on an observation that was never made"
  [ "$FS_VAL" = 1 ] || die "record not readable: $REC"
  _rb="${REC##*/}"
  # An unreadable RECORD is its own condition, distinct from a record that is
  # readable and has no session id: the first is a failed observation and the
  # second is a statement about the dispatch. Collapsing them made a hung mount
  # announce "no session id", which reads as a broken dispatch rather than as
  # broken monitoring.
  if ! rec_read "$REC" session_id; then
    alert_once "$REC" recdegraded "cannot read the dispatch record $_rb ($FS_WHY_TXT) — monitoring is DEGRADED, check it by hand"
    return 3
  fi
  SHORT="$REC_VAL"
  # The episode this marker names is "the record could not be read", and it ended
  # on the line above. It is cleared HERE, at the observation that makes its own
  # predicate false, and no longer after `read_agents` succeeds below: reaching
  # that clear took TWO successes, so a record that recovered into an agents
  # outage left the marker standing and the NEXT record outage was announced to
  # nobody (shape C, C1 — reproduced as a three-poll sequence before it was
  # touched, with the same poll re-run marker-cleared to prove the silence was
  # this suppression and not a dead process).
  # It must sit AFTER `SHORT="$REC_VAL"`: rec_clear -> rec_has -> rec_read
  # overwrites REC_VAL, the single-slot hazard documented for FS_VAL at the
  # transcript probe below, which is how that arm of the heartbeat once went dark.
  rec_clear "$REC" alerted_recdegraded
  # THE STATUS IS KEPT, because this read GATES A PROBE. `|| true` turned a
  # timed-out read into an empty UUID, and an empty UUID silently skips the
  # second presence probe below — so "the record could not be read" arrived at
  # the terminal decision spelled "absent under the short id", and the watchdog
  # recorded `finished` and stood down on a successor it never observed
  # (round 6 micro-review, reproduced by reading the two sites together).
  rec_read "$REC" session_uuid; _urs=$?
  UUID="$REC_VAL"
  # A record that NEVER had a session id is refused at startup (below, where
  # --watch is parsed). Losing one at poll time is a different event: a
  # re-dispatch truncates the record before it writes the new id, and a watcher
  # that treats that window as fatal EXITS — which silently un-watches the
  # previous successor if the re-dispatch then fails. Conclude nothing, say so
  # once, and keep the loop alive; supersession is decided by watch_gen, not by
  # a missing field.
  if [ -z "$SHORT" ]; then
    alert_once "$REC" no_session "the dispatch record $_rb has no session id — a successor may be running UNWATCHED, check \`handoff.sh --status\`"
    return 3
  fi
  # The id ARRIVED: the episode is over. `dispatch` writes `session_id` after the
  # launch returns, so a watcher armed in that window legitimately sees the field
  # missing for a poll or two — and without this clear the one alert it sent is
  # the only one that record can ever send about a missing id.
  rec_clear "$REC" alerted_no_session

  if ! read_agents; then
    # The observation failed. Ownership is retained and nothing is concluded:
    # an unreadable agent list is indistinguishable from a healthy session, so
    # calling it "finished" here is exactly how a blocked successor goes unseen.
    alert_once "$REC" degraded "cannot read \`claude agents --json\` — monitoring of successor $SHORT is DEGRADED, check it by hand"
    return 3
  fi
  # The list came back: whatever made monitoring degraded is over, so the marker
  # is cleared and a LATER outage is announced again. A marker that is never
  # cleared makes every alert a once-per-record event, which is how a successor
  # that blocked, was attended to and blocked again went unreported the second
  # time (round-4 correctness C6).
  # ONLY the agents-list marker is cleared here. `alerted_recdegraded` was cleared
  # on this line too, which ended the RECORD's episode on the AGENTS list's
  # evidence — two different observations sharing one clearing site. It now
  # clears at the record read itself, above.
  rec_clear "$REC" alerted_degraded

  STATE="$( exec 9>&- 8>&- 7>&-; lookup "$AGENTS_JSON" "$SHORT" state )"   # CLAIM:b
  [ -n "$STATE" ] || STATE="$( exec 9>&- 8>&- 7>&-; lookup "$AGENTS_JSON" "$UUID" state )"   # CLAIM:b
  # PRESENT carries row_present's three answers, not two: 1 present, 0 ABSENT,
  # 2 not observed. A probe that failed used to arrive here as 0 and be read as
  # "the successor is gone".
  PRESENT=0
  _rpu=0
  row_present "$AGENTS_JSON" "$SHORT"; case $? in 0) PRESENT=1 ;; 2) _rpu=1 ;; esac
  if [ "$PRESENT" = 0 ] && [ -n "$UUID" ]; then
    # Asked under the uuid too, even when the short-id probe could not answer:
    # a POSITIVE presence from either spelling is a real observation and settles
    # it. Only when neither probe answered is the question open.
    row_present "$AGENTS_JSON" "$UUID"; case $? in 0) PRESENT=1 ;; 2) _rpu=1 ;; esac
  elif [ "$PRESENT" = 0 ] && [ "$_urs" != 0 ]; then
    # A PROBE THAT WAS NEVER RUN IS NOT A PROBE THAT ANSWERED NO. The uuid
    # spelling could not be read, so the second question was never asked — and
    # the code asks it at all precisely because a row can be keyed by the uuid
    # and not by the short id. Same tri-state as row_present's own 2.
    _rpu=1
  fi
  [ "$PRESENT" = 1 ] || [ "$_rpu" = 0 ] || PRESENT=2

  if [ "$PRESENT" = 2 ]; then
    # The list was readable and the presence probe was not. Its own episode key,
    # not `degraded`: that one is cleared a few lines above on every successful
    # `read_agents`, so reusing it would re-alert on every single poll.
    alert_once "$REC" presencedegraded "cannot tell whether successor $SHORT is still in the agent list — the presence probe itself failed, so monitoring is DEGRADED; check it by hand"
    return 3
  fi
  # Cleared on ANY positive answer, present or absent, because the predicate
  # that raised it ("the probe did not run") is now false — not because some
  # neighbouring condition recovered.
  rec_clear "$REC" alerted_presencedegraded

  # Terminal only on a POSITIVE observation: a valid list that does not contain
  # the id at all, or a state we recognise as terminal. A row that IS there with
  # an empty state is neither — it is an unreadable state, handled below.
  if [ "$PRESENT" = 0 ]; then
    FIN=1
  else
    case "$DONE_STATES" in *" $STATE "*) FIN=1 ;; *) FIN=0 ;; esac
  fi
  if [ "$FIN" = 1 ]; then
    # Fenced at the WRITE, not at the top of the poll: the record may have been
    # truncated and re-armed by a --force dispatch while this poll was running.
    gen_is_ours "$REC" || return 4
    # The FACT that it finished is recorded before, and independently of, the
    # notification. The poll loop keys off this fact, so a notification that
    # cannot be delivered can no longer keep the watchdog running to expiry —
    # and, since L6, cannot make it exit with the alert undelivered either.
    rec_has "$REC" "$FIN_KEY" || rec_set "$REC" "$FIN_KEY"
    if [ "$PRESENT" = 0 ]; then _fw="gone"; else _fw="$STATE"; fi
    # HOW it finished is recorded WITH the fact, because the retry in watch_loop
    # has no successful agent query left to re-derive it from — and a retry that
    # cannot name the outcome would change the sentence. Written once: the value
    # is not `1`, so `rec_has` can never be the guard here.
    rec_read "$REC" "${FIN_KEY}_how" || true
    [ -n "$REC_VAL" ] || rec_put "$REC" "${FIN_KEY}_how" "$_fw" || true
    alert_finished "$REC" "$_fw"
    return 0
  fi

  # `blocked` and `unknown` are two INDEPENDENT predicates over THIS observation,
  # not two arms of one ordering. Each arm used to alert and `return 0` before it
  # could reach the other's clear, so either marker could only ever be cleared by
  # a transition through *live*: blocked -> unknown -> blocked announced the first
  # blocked and then went quiet, and the mirror sequence did the same to `unknown`
  # (shape C, C2 — both directions reproduced, each with the marker-cleared
  # re-poll that proves the third poll's silence was suppression).
  # Compute both predicates, clear each one on its own predicate being FALSE, and
  # only then alert.
  _is_blocked=0
  [ "$STATE" = "blocked" ] && _is_blocked=1
  _is_unknown=0
  if [ "$_is_blocked" = 0 ]; then
    case "$LIVE_STATES" in *" $STATE "*) ;; *) _is_unknown=1 ;; esac
  fi
  # The two are mutually exclusive BY CONSTRUCTION — `_is_unknown` is only
  # computed when `_is_blocked` is 0 — so a runtime assertion that they never
  # coincide could not fire, and a control that cannot fail is not a control.
  # The partition (exactly one alert per ENTRY, none for staying) is pinned in
  # the CU state matrix instead, where a rewrite of these predicates can break it.
  [ "$_is_blocked" = 1 ] || rec_clear "$REC" alerted_blocked
  [ "$_is_unknown" = 1 ] || rec_clear "$REC" alerted_unknown

  # ACCEPTED CONSEQUENCE: a successor oscillating blocked <-> unknown now nudges
  # on every entry, where before it nudged once. That is the same trade this file
  # already takes for blocked <-> live, for the reason the alert header gives: a
  # duplicate nudge is cheap; a lost one is the bug.
  if [ "$_is_blocked" = 1 ]; then
    shq "$SHORT"
    alert_once "$REC" blocked "successor $SHORT is blocked and needs input — claude attach $SHQ"
    return 0
  fi
  if [ "$_is_unknown" = 1 ]; then
    # A row that IS present with an empty state is an unreadable state, not a
    # finished successor — say which of the two it is.
    if [ -z "$STATE" ]; then _us="an unknown state (the list gave none)"; else _us="unknown state '$STATE'"; fi
    alert_once "$REC" unknown "successor $SHORT is listed but reports $_us — not treated as finished, check it by hand"
    return 0
  fi

  # Live. The heartbeat is the newest write to either the successor's transcript
  # or the handoff file it was told to update. It is a WEAK signal — a long
  # silent tool call looks identical to a wedge, and a looping agent keeps it
  # fresh forever — so the alert says "no heartbeat", not "stalled", and only a
  # state observation can establish that the successor is actually blocked.
  fs_get "$FS_TIMEOUT_SEC" transcript_for "$UUID" || {
    # A timed-out discovery is not "no transcript": concluding absence here is
    # what turned a hung mount into a silent loss of the heartbeat signal.
    alert_once "$REC" fsdegraded "cannot read the filesystem to locate successor $SHORT's transcript ($FS_WHY_TXT) — monitoring is DEGRADED, check it by hand"
    return 3
  }
  # FS_VAL IS A SINGLE SLOT. `rec_clear` -> `rec_has` -> `rec_read` -> `fs_get`
  # overwrites it, so the probe's value is consumed BEFORE the clear, not after.
  # Putting the clear first silently handed T the record read's value instead of
  # the transcript path: the transcript arm of the heartbeat went dark and only
  # the handoff file's mtime was left (caught by case BD).
  T="$FS_VAL"
  # Cleared HERE, at the positive observation, and not before the probe. The
  # clear used to sit ABOVE `fs_get transcript_for`, so it fired on every poll
  # BEFORE the thing it describes was observed: a filesystem that stayed hung
  # re-alerted on each cycle (alert_once degraded to alert_always) and the clear
  # never encoded recovery from anything. A marker is cleared by seeing the
  # condition GONE.
  rec_clear "$REC" alerted_fsdegraded
  # KEPT FOR THE SAME REASON as session_uuid above: this read gates the second
  # heartbeat source. `|| true` made an unreadable record indistinguishable from
  # a record with no handoff file, so that arm reported neither a beat nor a
  # failure — and with the transcript arm also silent the poll fell through to
  # `rec_clear alerted_beatdegraded` and returned "healthy", clearing a standing
  # degraded marker on the strength of a read that never happened.
  rec_read "$REC" handoff; _hors=$?
  HO="$REC_VAL"

  # A transcript that never appears is its own condition, not a stale heartbeat:
  # the handoff file's own mtime would otherwise mask it for the first 20m.
  # Before the grace window its absence is just startup.
  if [ -z "$T" ]; then
    DAGE=0
    # A DISTINCT key from `recdegraded`, for the reason beatdegraded was split
    # from fsdegraded: recdegraded's clear fires earlier in THIS poll, on the
    # session_id read, so raising it here would clear-then-raise on every poll —
    # alert_once degraded to alert_always. This key's own clear is the
    # fall-through below, i.e. the negation of the raise rather than a second
    # condition kept in step with it.
    if ! rec_num "$REC" dispatched_epoch; then
      alert_once "$REC" dispatchdegraded "cannot establish when successor $SHORT was dispatched ($FS_WHY_TXT), so the no-transcript deadline cannot be judged — monitoring is DEGRADED, check it by hand"
      return 3
    fi
    if [ -z "$REC_NUM" ] && rec_has "$REC" dispatch_clock_lost; then
      alert_once "$REC" dispatchdegraded "successor $SHORT's dispatch time was never recorded (the clock failed at dispatch), so the no-transcript deadline cannot be judged — monitoring is DEGRADED, check it by hand"
      return 3
    fi
    rec_clear "$REC" alerted_dispatchdegraded
    # NO CLOCK, NO AGE. `watch_once` is also the `--watch-once` entry point,
    # where EPOCH is still its initial 0 and `epoch` leaves it unchanged on
    # failure, so an unchecked call here reported "no transcript in 29785107m"
    # off a record written by a dispatch whose clock had failed, and below it
    # reported a heartbeat "-29785101m old" and cleared `alerted_nobeat` on the
    # strength of that negative age (round 6, C3 and CA-3 — both reproduced).
    if [ -n "$REC_NUM" ]; then
      epoch || return 3
      DAGE=$(( EPOCH - REC_NUM ))
    fi
    if [ "$DAGE" -gt "$TRANSCRIPT_GRACE" ]; then
      alert_once "$REC" notranscript "successor $SHORT has written no transcript in $(( DAGE / 60 ))m — monitoring is DEGRADED, check it by hand"
    fi
  else
    rec_clear "$REC" alerted_notranscript
    rec_clear "$REC" alerted_dispatchdegraded
  fi

  BEAT=0; SRC=""; FSFAIL=0
  # An unreadable record is an unobservable handoff-file arm, counted here so the
  # "both sources unobservable" test below is asked about observations and not
  # about emptiness.
  [ "$_hors" = 0 ] || FSFAIL=1
  if [ -n "$T" ]; then
    if fs_get "$FS_TIMEOUT_SEC" mtime_of "$T"; then
      [ -n "$FS_VAL" ] && [ "$FS_VAL" -gt "$BEAT" ] && { BEAT="$FS_VAL"; SRC="transcript"; }
    else FSFAIL=1; fi
  fi
  if [ -n "$HO" ]; then
    if fs_get "$FS_TIMEOUT_SEC" file_exists "$HO"; then
      if [ -n "$FS_VAL" ]; then
        if fs_get "$FS_TIMEOUT_SEC" mtime_of "$HO"; then
          [ -n "$FS_VAL" ] && [ "$FS_VAL" -gt "$BEAT" ] && { BEAT="$FS_VAL"; SRC="handoff file"; }
        else FSFAIL=1; fi
      fi
    else FSFAIL=1; fi
  fi
  # Both heartbeat sources unobservable = no heartbeat signal at all, which must
  # be SAID rather than reported as a zero beat and dropped.
  if [ "$FSFAIL" = 1 ] && [ "$BEAT" = 0 ]; then
    # A DISTINCT key from the discovery failure above. One key for two conditions
    # meant either could clear the other's alert: a successful transcript lookup
    # silenced a standing "cannot stat the heartbeat" report, and the human was
    # told monitoring had recovered when only half of it had.
    # THE ONE SITE THAT MAY NOT NAME A CAUSE. `FSFAIL` is a running OR over up
    # to four probes above, so `FS_WHY_TXT` here would describe whichever one ran
    # LAST — which is not necessarily one that failed. Naming the wrong cause is
    # the defect being fixed, so this message states only what is known: at least
    # one source, bounded, yielded no reading.
    alert_once "$REC" beatdegraded "cannot stat successor $SHORT's transcript or handoff file (at least one source, probed with a ${FS_TIMEOUT_SEC}s bound, yielded no reading) — monitoring is DEGRADED, check it by hand"
    return 3
  fi
  # Reaching this line IS the raising predicate being false, so the clear is the
  # fall-through of the `if` that raises — not a second condition kept in step
  # with the first. It used to test `FSFAIL = 0` alone, which is narrower than
  # the negation of `FSFAIL=1 && BEAT=0`: with one source answering and the other
  # timing out the poll matched neither the raise nor the clear, so a standing
  # marker survived a half-recovery and the next total outage was silent
  # (shape C, C3 — reproduced, with the marker-cleared re-poll as its control).
  rec_clear "$REC" alerted_beatdegraded
  [ "$BEAT" = 0 ] && return 0

  epoch || return 3   # same rule as the deadline above: no clock, no age
  AGE=$(( EPOCH - BEAT ))
  if [ "$AGE" -gt $(( HEARTBEAT_MIN * 60 )) ]; then
    alert_once "$REC" nobeat "successor $SHORT: no heartbeat for $(( AGE / 60 ))m (state $STATE) — it may be stalled or just quiet"
    return 0
  fi
  # A heartbeat again: the silent episode is over, so the next one is announced.
  rec_clear "$REC" alerted_nobeat
  printf 'handoff: %s %s, heartbeat %sm old (%s)\n' "$SHORT" "$STATE" "$(( AGE / 60 ))" "$SRC"
  return 0
}

# --------------------------------------------------------------------- watch
watch_loop() {
  REC="$1"
  # The deadline is taken BEFORE the lease, and the order is load-bearing for the
  # test that crosses it: holding the lease is the only observable proof this
  # loop has started, so a test that moves the clock has to be able to wait for
  # something that happens strictly AFTER the deadline was computed (case AY).
  # No clock, no deadline, so no watcher. Returning here takes NO lease, which
  # is what makes this honest end-to-end: arm_watch proves arming by probing the
  # lease, finds it free, and reports FAILED TO ARM — so the launcher says
  # nobody is watching instead of a leaseless process pretending to.
  if ! epoch; then
    logline "{\"hook_event_name\":\"HandoffWatchNoClock\",\"gen\":\"$WATCH_GEN\",\"rec\":\"$REC\"}"
    return 0
  fi
  DEADLINE=$(( EPOCH + MAX_HOURS * 3600 ))
  _leased=0
  # The lease is taken FIRST and held for this process's whole life, so "a
  # watcher is running" is a question the kernel answers for any third party
  # before the first poll completes.
  #
  # ...and it is taken ONLY while there is something to watch. A lease means
  # "this process is watching NOW", so a watcher whose deadline has already
  # passed must never publish one: it would hold the lease for the microseconds
  # between here and the expiry write below, and whether the launcher's probe
  # caught that window would decide whether the very same command reported
  # "armed" or "FAILED TO ARM". A zero-hour deadline is a coherent instruction
  # ("expire at once"), and its honest report is that nobody is watching --
  # which is what the arm failure and the expiry alert then BOTH say (case AL).
  if [ -n "$WATCH_GEN" ] && [ "$EPOCH" -lt "$DEADLINE" ]; then
    lease_file_of "$REC" "$WATCH_GEN"
    _wn=0; _wu=0
    while :; do
      lock_hold 8 "$LEASE_FILE"; _wr=$?
      [ "$_wr" = 0 ] && { _leased=1; break; }
      if [ "$_wr" = 2 ]; then
        # Unobservable, not taken. NOT specifically a failed open: `lock_hold`
        # answers 2 from FOUR places — an unobservable `-L` test, a symlink
        # found at the path, the `exec 8>>` open, and a `lock_take` that could
        # not answer AFTER the open succeeded — and this comment used to name
        # only the third (round 6 micro-review 6; the same overstatement was
        # corrected at `lease_probe` one micro-review earlier). Retried first,
        # because a transient inability to TELL should not cost the lease for
        # the watcher's whole life.
        _wu=$(( _wu + 1 ))
        if [ "$_wu" -lt 10 ]; then sleep 0.1 9>&- 8>&- 7>&-; continue; fi
        # Still unobservable. Watching without a provable lease is worse than
        # watching with one and FAR better than not watching at all — the
        # reviewer's "refuse to watch without a lease" trades a duplicate
        # watchdog for none, and an unwatched successor is the failure this
        # script exists to prevent (round-4 lifecycle L4, accepted in part). So
        # it keeps watching, and says so: an unpublishable lease means a second
        # watchdog may be armed, and that is a fact a human is told rather than
        # a silence reconciliation reads as health.
        logline "{\"hook_event_name\":\"HandoffWatchLeaseUnavailable\",\"gen\":\"$WATCH_GEN\",\"rec\":\"$REC\"}"
        rec_stamp "$REC" lease_degraded || true
        # WATCHER-SCOPED, like finished/expired/clocklost -- and generation is
        # the whole of this key's scope, see fin_key_set. The lease is taken once, at
        # the top of this process's life, and never retried — so there is no
        # recovery transition to clear a marker with. A flat `leasedegraded` key
        # therefore reported the FIRST watcher that could not publish a lease and
        # silenced every later one, across re-dispatches, for the life of the
        # record. Keying it by generation makes each watcher's own failure its
        # own episode.
        alert_once "$REC" "leasedegraded_$WATCH_GEN" "the watchdog for ${REC##*/} cannot publish its lease, so a SECOND watchdog may be armed for the same successor — monitoring is DEGRADED"
        break
      # CLAIM-REGION-BEGIN watch
      fi
      # Someone holds this generation's lease. Retried rather than refused at
      # once, because arm_watch proves arming by TAKING the lease for a few
      # microseconds, so a watcher starting in that instant can lose one attempt
      # to its own launcher. A lease still held three seconds later is a second
      # watcher for the same generation — two of those racing every alert is the
      # failure this lease exists to prevent — so stand down.
      _wn=$(( _wn + 1 ))
      if [ "$_wn" -ge 30 ]; then
        logline "{\"hook_event_name\":\"HandoffWatchDuplicate\",\"gen\":\"$WATCH_GEN\",\"rec\":\"$REC\"}"
        return 0
      fi
      sleep 0.1   # CLAIM:c
    done
    # THE DEADLINE IS RE-READ AFTER THE ACQUISITION, not only before it. The
    # guard above and the take are not one step, and the gap is unbounded: the
    # retry loop can spin for seconds against a departing incumbent. A lease
    # published by a watcher that is already expired says "someone is watching"
    # about a process whose next act is to announce that nobody is (round-4
    # lifecycle L8). Drop it and let the expiry path below speak.
    if [ "$_leased" = 1 ]; then
      # A failed re-read leaves EPOCH at the reading taken before the lease —
      # stale by the length of the retry loop, but a real observation. The poll
      # loop below is where a clock that stays unreadable is caught.
      epoch || true
      if [ "$EPOCH" -ge "$DEADLINE" ]; then
        logline "{\"hook_event_name\":\"HandoffWatchExpiredBeforeArming\",\"gen\":\"$WATCH_GEN\",\"rec\":\"$REC\"}"
        lock_drop 8; _leased=0
      fi
    fi
  fi
  _fd=0
  epoch
  while [ "$EPOCH" -lt "$DEADLINE" ]; do
    # EXACTLY ONE watcher per record, and the record's `watch_gen` is what decides
    # which one it is. A `--force` re-dispatch truncates the record and arms a new
    # generation without knowing this process exists, so a superseded watcher has
    # to notice and stand down itself: two watchers race every alert claim, and a
    # stale one that is still ALIVE reads as "a live claimant is delivering it" and
    # SUPPRESSES the current watcher's alert — the silent stall this script exists
    # to prevent. The older deadline is the other half: it would write
    # `monitoring_expired` and announce that nobody is watching a successor that is.
    # An EMPTY watch_gen is NOT supersession — it is the truncation window of a
    # re-dispatch that has not armed yet — so only a different NON-EMPTY generation
    # stands us down.
    if [ -n "$WATCH_GEN" ]; then
      rec_read "$REC" watch_gen || true
      _rg="$REC_VAL"
      if [ -n "$_rg" ] && [ "$_rg" != "$WATCH_GEN" ]; then
        logline "HandoffWatchSuperseded gen=$WATCH_GEN by=$_rg rec=$REC"
        # Drop the lease, do not unlink it: the file is this generation's and
        # unlinking is what reintroduces pathname identity. Unheld reads as free.
        # The drop is REDUNDANT with the `exit 0` that follows this return -- the
        # kernel releases the lock when the descriptor closes -- and no mutation
        # can kill it for that reason (M10, round 3). It stays so the function is
        # correct independent of its caller, not because anything observes it.
        lock_drop 8
        return 0
      fi
    fi
    watch_once "$REC" >/dev/null 2>&1
    # THE TERMINAL FACT IS NOT THE EXIT CONDITION; the fact PLUS a delivered
    # alert is. `finished` is recorded first on purpose — it must survive a
    # crash — but exiting on it regardless of delivery meant a headless box, a
    # transiently broken notifier or an unopenable claim lost the alert forever,
    # which is precisely the silent finish this watchdog exists to report
    # (round-4 lifecycle L6). The RETRY is issued from HERE rather than left to
    # watch_once, because watch_once cannot be reached at all once the agent
    # query degrades.
    if rec_has "$REC" "$FIN_KEY"; then
      rec_has "$REC" "alerted_$FIN_KEY" && return 0
      # SPEND THE BUDGET ON ATTEMPTS, NOT ON POLLS. watch_once reaches the alert
      # only on a poll whose `claude agents --json` SUCCEEDED, so counting polls
      # let a degraded agent query burn all ten retries without calling the
      # notifier once — and the watcher then exited announcing
      # `alert_undelivered` after a SINGLE real attempt, reporting "nobody could
      # be told" without having tried (round-4 micro L6).
      alert_finished "$REC"
      [ "$ALERT_RESULT" = delivered ] && return 0
      # `skipped` is not ours to count: another claimant holds this alert, or
      # this generation no longer owns the record. Neither is a failure of
      # ours, and neither is helped by giving up sooner. `unavailable` IS ours
      # — see alert_spent, which both bounded budgets now share.
      alert_spent && _fd=$(( _fd + 1 ))
      if [ "$_fd" -ge "$ALERT_RETRY_MAX" ]; then
        rec_stamp "$REC" "alert_undelivered_$FIN_KEY" || true
        logline "{\"hook_event_name\":\"HandoffAlertUndelivered\",\"key\":\"$FIN_KEY\",\"rec\":\"$REC\"}"
        return 0
      fi
    fi
    # The watcher is the only long-lived process here, so it is what retries an
    # undelivered rearm alert.
    rec_read "$REC" rearm_pending || true
    _wp="$REC_VAL"
    if [ -n "$_wp" ]; then
      rec_read "$REC" session_id || true
      alert_once "$REC" "rearm_$_wp" "successor $REC_VAL was running UNWATCHED — monitoring re-armed"
    fi
    sleep "$POLL_SEC" 9>&- 8>&- 7>&-   # SPAWN SITE 11: holds fd 8 for hours   # CLAIM:c
    # A watchdog that cannot read the clock cannot honour its deadline. It used
    # to keep the last value and spin here forever, holding a lease that told
    # every reconciling dispatch a live watcher was on the job. So it stands
    # DOWN and drops the lease FIRST: a free lease is what lets a healthy
    # watcher be armed in its place, and the alert is what tells a human that
    # the swap has to happen. Not an expiry — this deadline was never reached,
    # and saying `monitoring_expired` would be a claim about the successor
    # rather than about the watcher.
    if ! epoch; then
      logline "{\"hook_event_name\":\"HandoffWatchClockLost\",\"gen\":\"$WATCH_GEN\",\"rec\":\"$REC\"}"
      [ "$_leased" = 1 ] && { lock_drop 8; _leased=0; }
      gen_is_ours "$REC" || return 0
      rec_put "$REC" watch_clock_lost 1 || true
      rec_read "$REC" session_id || true
      alert_once "$REC" "$CLOCK_KEY" "the handoff watchdog for ${REC_VAL:-that successor} cannot read the clock, so it cannot honour its deadline — it has STOOD DOWN and nobody is watching now"
      return 0
    fi
  done
  # Expiry is action-required, not a quiet exit: from here nobody is watching.
  gen_is_ours "$REC" || return 0
  # THE LEASE GOES FIRST, before the retries below. From this line on this
  # process is not watching anything — it is only trying to deliver one
  # sentence — and a held lease would tell a reconciling dispatch that a watcher
  # is alive, so it would decline to re-arm for as long as the retries ran.
  [ "$_leased" = 1 ] && { lock_drop 8; _leased=0; }
  # CLAIM-REGION-END watch
  rec_stamp "$REC" monitoring_expired || true
  rec_read "$REC" session_id || true
  _xs="$REC_VAL"
  _xn=0
  while :; do
    alert_once "$REC" "$EXP_KEY" "handoff watchdog for $_xs EXPIRED after ${MAX_HOURS}h and the session is still live — nobody is watching it now"
    rec_has "$REC" "alerted_$EXP_KEY" && break
    # The SAME accounting rule as the terminal budget above, from the same
    # author. This loop used to count polls, so ten polls against a held claim
    # spent the whole budget without one delivery attempt and abandoned a live
    # successor to announce that nobody could be told.
    alert_spent && _xn=$(( _xn + 1 ))
    if [ "$_xn" -ge "$ALERT_RETRY_MAX" ]; then
      rec_stamp "$REC" "alert_undelivered_$EXP_KEY" || true
      logline "{\"hook_event_name\":\"HandoffAlertUndelivered\",\"key\":\"$EXP_KEY\",\"rec\":\"$REC\"}"
      break
    fi
    sleep "$POLL_SEC" 9>&- 8>&- 7>&-
  done
}

# -------------------------------------------------------------------- status
status() {
  read_agents || die "\`claude agents --json\` did not return a usable list"
  # SPAWN SITE 7
  ( exec 9>&- 8>&- 7>&-
  printf '%s' "$AGENTS_JSON" | "$NODE" -e '
    let s = "";
    process.stdin.on("data", d => (s += d));
    process.stdin.on("end", () => {
      let a = [];
      try { a = JSON.parse(s); } catch { return; }
      const rows = (Array.isArray(a) ? a : []).filter(x => x && x.kind === "background");
      if (!rows.length) { console.log("no background sessions"); return; }
      for (const r of rows) {
        const age = r.startedAt ? Math.round((Date.now() - r.startedAt) / 60000) : null;
        const flag = r.state === "blocked" ? "  <-- BLOCKED, needs input" : "";
        console.log(`${r.id}  ${String(r.state ?? "?").padEnd(9)} ${age === null ? "" : age + "m old"}  ${r.name || ""}${flag}`);
      }
    });
  ' )
}

# --------------------------------------------------------- watchdog recovery
# A verified record plus a dead watcher is precisely the failure this script
# exists to prevent: a live successor that nobody is watching. The only place
# that reliably notices is a later dispatch for the same handoff — so that
# dispatch re-arms monitoring instead of merely refusing and walking away.
reconcile_watch() { # $1=record  $2=session id
  _rr="$1"; _rs="$2"
  [ "$ARM" = 1 ] || return 0
  _wa=0; watch_is_alive "$_rr" && _wa=1
  # The degraded-probe episode is decided by WHETHER THE PROBE ANSWERED, which is
  # a different question from what it answered — so its two ends live here, above
  # the branch, not inside the alive arm. Putting the clear inside that arm meant
  # a probe that recovered on a poll where the watcher was DEAD took the re-arm
  # path and never reached the clear, leaving the marker set forever anyway.
  if [ "$WATCH_UNKNOWN" = 1 ]; then
    # Unobservable liveness is treated as watched — arming a second watcher on a
    # stat timeout is the worse failure — but it is SAID, because the alternative
    # is a record that is never re-armed and never complains.
    alert_once "$_rr" watchunknown "cannot tell whether successor $_rs's watchdog is alive ($WATCH_UNKNOWN_WHY) — monitoring is DEGRADED, check \`handoff.sh --status\`"
  else
    rec_clear "$_rr" alerted_watchunknown
  fi
  if [ "$_wa" = 1 ]; then
    # Retry a rearm alert that was recorded as pending but never delivered.
    rec_read "$_rr" rearm_pending || true
    _rp="$REC_VAL"
    [ -n "$_rp" ] && alert_once "$_rr" "rearm_$_rp" "successor $_rs was running UNWATCHED — monitoring re-armed"
    return 0
  fi
  _ng="$( exec 9>&- 8>&- 7>&-; arm_watch "$_rr" )"   # CLAIM:b
  if [ -z "$_ng" ]; then
    rec_put "$_rr" watch_failed 1 || true
    alert_once "$_rr" rearm_failed "successor $_rs is running UNWATCHED and re-arming the watchdog FAILED — check it by hand"
    printf 'handoff: successor %s is unwatched and re-arming FAILED\n' "$_rs" >&2
    return 0
  fi
  rec_stamp "$_rr" watch_reattached || true
  # Re-arming SUCCEEDED, so the failure episode is over: clear both the alert
  # marker and the durable flag it set. Neither had a clearing site, so one
  # transient arm failure made a record permanently unable to report the next
  # one, while `watch_failed=1` sat in it describing a watcher that is running.
  rec_clear "$_rr" alerted_rearm_failed
  rec_clear "$_rr" watch_failed
  # Durable and retried. `notify ... || true` here was a single lossy attempt,
  # and because every later reconciliation returned early once a watcher was
  # live, a delivery failure meant the alert was never sent at all — the
  # at-least-once half of the alert contract, silently broken.
  rec_put "$_rr" rearm_pending "$_ng" || true
  alert_once "$_rr" "rearm_$_ng" "successor $_rs was running UNWATCHED — monitoring re-armed"
  printf 'handoff: successor %s was unwatched; re-armed the watchdog (generation %s)\n' "$_rs" "$_ng" >&2
}

# ------------------------------------------------------------------ dispatch
# Class A: an option that takes a value must not swallow a following FLAG.
# `handoff.sh H obj --model --dry-run` assigned "--dry-run" to MODEL, left DRY=0
# and performed a REAL dispatch. All seven value-taking call sites funnel through
# here, so the class is closed in one place rather than site by site.
# `-?*` and not `-*`: a lone "-" is a plausible literal value.
need_val() { # $1=option name, $2=$# at the point of the match, $3=following token
  [ "$2" -ge 2 ] || die "$1 needs a value"
  case "${3:-}" in
    -?*) die "$1 needs a value, but the next argument is '${3:-}', which looks like an option — refusing, because an option that swallows a flag silently disables it" ;;
  esac
}

# ------------------------------------------------------------- retire-self --
#
# After a VERIFIED dispatch the predecessor has nothing left to do, and until now
# nothing ever said so. `dispatch` ended, this process exited, and the seat went
# back to its turn loop and sat `awaiting input` forever. Measured 2026-08-26:
# session 01c496eb had `firstTerminalAt: null` hours after handing off, and
# `claude agents` listed it as awaiting input beside seats that genuinely were --
# so the one signal a human uses to find a seat that needs them is diluted by
# every seat that has already finished.
#
# `claude agents` exposes no stop subcommand, so retirement is two writes and a
# signal: the SENTINEL (so nothing tells this seat to hand off AGAIN), the seat's
# own state.json (so the fleet reads it as terminal), and then the process stop
# that makes the state stick. The daemon re-derives `state` by scanning the
# transcript, so a marker left over a live process is reverted on the next wake:
# `[[a-state-guard-is-a-snapshot-not-a-latch]]` -- the KILL is the durable half,
# and the marker is only what makes the kill legible.
#
# WHOSE process. The record names the SUCCESSOR. A retirement that read its
# subject from the record would kill the session it had just started, so the
# subject is derived from the predecessor's own environment and then BOUND, five
# ways, before anything irreversible happens:
#
#   1. CLAUDE_JOB_DIR's basename is not the successor's short id  (the TRIPWIRE);
#   2. that basename is the first field of CLAUDE_CODE_SESSION_ID (measured on
#      25 live seats 2026-08-26: 25/25 agree, 0 mismatches);
#   3. the state.json INSIDE that directory records that same session id -- this
#      is what turns CLAUDE_JOB_DIR from an assertion into evidence, because an
#      inherited or stale value names a session that is not ours and this is
#      where that shows;
#   4. CLAUDE_PID is a live process whose command is `claude`;
#   5. CLAUDE_PID is an ANCESTOR of this shell. A pid is not an identity -- they
#      are recycled, and every seat on this box runs as the same Unix user -- but
#      an ancestor of the process doing the dispatching is. This is the check
#      that defeats a recycled number, a stale CLAUDE_PID inherited from another
#      seat, and a nested dispatch.
#
# `[[an-armed-watcher-holds-its-boot-config]]`: never let a control NAME a
# subject that can move. Step 1 is the assertion that the two ids never collapsed.

# Both probes are class `a`: reached only through fs_get, so a wedged `ps` or a
# hung `node` on a stalled mount costs a deadline, not the dispatch.
_state_sid() {   # $1=state.json path -> the session id that file records
  # CLAIM:a
  "$NODE" -e '
    try {
      const j = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
      process.stdout.write(String(j.sessionId || ""));
    } catch (e) { /* unreadable and malformed are the same answer: not ours */ }
  ' -- "$1"
}

_seat_ancestry() {   # $1=claimed pid  $2=this pid -> "1" iff $1 is a live claude ancestor of $2
  # ONE `ps`, walked in awk. Walking in the shell would be one fork per
  # generation, under a held claim, on a box where the chain is routinely 4-6
  # deep -- and each of those forks would be a census site of its own.
  # CLAIM:a
  ps -Ao pid=,ppid=,comm= 2>/dev/null | awk -v want="$1" -v cur="$2" '
    { pp[$1] = $2; cm[$1] = $3 }
    END {
      if (!(want in pp)) exit 0
      if (cm[want] !~ /claude/) exit 0
      for (n = 0; n < 512 && cur != "" && cur != "0" && cur != "1"; n++) {
        if (cur == want) { print "1"; exit 0 }
        cur = pp[cur]
      }
    }
  '
}

_mark_terminal() {   # $1=sentinel  $2=state.json  $3=successor short  $4=backup path
  # The sentinel is written BEFORE the state file, not after: the sentinel is
  # what stops context-watchdog telling this seat to hand off a SECOND time, and
  # between the two writes the seat is still live and still making tool calls.
  # Ordering it the other way leaves a window in which the seat reads terminal
  # and is still being told to dispatch.
  #
  # The state write is a rename over a backup, so the whole thing is reversible:
  # the detached killer restores from $4 if it has to abort. Nothing here is
  # irreversible -- that is the point of doing it on this side of the fork.
  # CLAIM:a
  "$NODE" -e '
    const fs = require("fs");
    const path = require("path");
    const [sent, sj, short, bak] = process.argv.slice(1);
    const raw = fs.readFileSync(sj, "utf8");
    const o = JSON.parse(raw);
    fs.mkdirSync(path.dirname(sent), { recursive: true });
    fs.writeFileSync(bak, raw);
    fs.writeFileSync(sent, short + "\n");
    o.state = "done";
    o.tempo = "idle";
    o.detail = "handed off to " + short + "; retired by handoff.sh";
    if (!o.firstTerminalAt) o.firstTerminalAt = new Date().toISOString();
    const tmp = sj + ".retire." + process.pid;
    fs.writeFileSync(tmp, JSON.stringify(o));
    fs.renameSync(tmp, sj);
    process.stdout.write("ok");
  ' -- "$1" "$2" "$3" "$4"
}

# retire_self <successor-short-id> <record> [<successor-lane>] -> sets RETIRED;
# 0 armed or skipped, 2 REFUSED. A refusal is a reportable outcome, never a
# silent no-op: "dispatched" and "retired" are separate claims exactly as
# "dispatched" and "watched" already are, and a retirement that did not happen
# must be visible in the same report. The optional third argument is the lane
# key of the successor just dispatched: when this seat is itself a worker
# (CLAUDE_HANDOFF_LANE set) handing off to a DIFFERENT lane, retirement is the
# "this seat is replaced" signal, so the old lane is closed as superseded.
retire_self() {
  _rt_short="$1"; _rt_rec="$2"; _rt_newlane="${3:-}"

  RETIRED="no (--no-retire)"
  [ "$NORETIRE" = 0 ] || return 0
  RETIRED="no (disarmed by CLAUDE_HANDOFF_RETIRE=0)"
  [ "$RETIRE" = 1 ] || return 0
  # A top-level interactive session has no job to retire. That is not a refusal
  # and must not read like one.
  RETIRED="no (not a background seat: no CLAUDE_JOB_DIR)"
  [ -n "${CLAUDE_JOB_DIR:-}" ] || return 0

  _rt_jd="$CLAUDE_JOB_DIR"
  _rt_me="${_rt_jd##*/}"
  _rt_sid="${CLAUDE_CODE_SESSION_ID:-}"

  # (1) THE TRIPWIRE. If these two ever collapse, the retirement is pointed at
  # the session it just dispatched. Refuse loudly rather than "handle" it.
  if [ "$_rt_me" = "$_rt_short" ]; then
    RETIRED="REFUSED: this seat's job id IS the successor's ($_rt_short) — retiring would kill the session just dispatched"
    rec_put "$_rt_rec" retire_state refused_is_successor || true
    return 2
  fi

  # (2) the job directory names THIS session
  if [ -z "$_rt_sid" ] || [ "$_rt_me" != "${_rt_sid%%-*}" ]; then
    RETIRED="REFUSED: CLAUDE_JOB_DIR ($_rt_me) does not name this session (${_rt_sid:-CLAUDE_CODE_SESSION_ID unset}) — inherited, not ours"
    rec_put "$_rt_rec" retire_state refused_jobdir_not_ours || true
    return 2
  fi

  # (3) and the state.json inside it agrees
  fs_get "$FS_TIMEOUT_SEC" _state_sid "$_rt_jd/state.json" || FS_VAL=""
  if [ "$FS_VAL" != "$_rt_sid" ]; then
    RETIRED="REFUSED: $_rt_jd/state.json records session '${FS_VAL:-unreadable}', not '$_rt_sid'"
    rec_put "$_rt_rec" retire_state refused_state_mismatch || true
    return 2
  fi

  # (4) a live `claude` process, and (5) an ancestor of this shell
  _rt_pid="${CLAUDE_PID:-}"
  case "$_rt_pid" in
    ''|*[!0-9]*)
      RETIRED="REFUSED: CLAUDE_PID is '${_rt_pid:-unset}', not a pid — nothing to stop"
      rec_put "$_rt_rec" retire_state refused_no_pid || true
      return 2 ;;
  esac
  fs_get "$FS_TIMEOUT_SEC" _seat_ancestry "$_rt_pid" "$$" || FS_VAL=""
  if [ "$FS_VAL" != 1 ]; then
    RETIRED="REFUSED: pid $_rt_pid is not a live \`claude\` ancestor of this shell — it is not this seat"
    rec_put "$_rt_rec" retire_state refused_not_ancestor || true
    return 2
  fi

  # Bound: everything below acts on THIS seat.
  _rt_sent="$STATE_DIR/$_rt_sid.handed-off"
  _rt_bak="$_rt_jd/state.json.pre-retire"
  fs_get "$FS_TIMEOUT_SEC" _mark_terminal "$_rt_sent" "$_rt_jd/state.json" "$_rt_short" "$_rt_bak" || FS_VAL=""
  if [ "$FS_VAL" != ok ]; then
    # Read into a local rather than `${FS_WHY_TXT:-...}` inline. Case DR censuses
    # every WRITE to the degraded-reason constructors by subtracting pure `$NAME`
    # and `${NAME}` reads, and it cannot tell `:-` (a read with a fallback) from
    # `:=` (a real assignment) -- so an inline default here would have to be
    # inventoried as a write, and that row would then swallow a genuine `:=`
    # added to this same function later.
    _rt_why="$FS_WHY_TXT"
    [ -n "$_rt_why" ] || _rt_why="the write did not report success"
    RETIRED="FAILED: could not mark $_rt_jd/state.json terminal ($_rt_why)"
    rec_put "$_rt_rec" retire_state retire_failed || true
    return 2
  fi

  rec_put "$_rt_rec" retired_predecessor "$_rt_me" || true
  rec_put "$_rt_rec" retire_state retire_pending || true
  logline "{\"hook_event_name\":\"HandoffRetire\",\"session\":\"$_rt_me\",\"successor\":\"$_rt_short\"}"

  # LANE SUPERSESSION — coupled to retirement on purpose. Only a dispatch that
  # RETIRES this seat replaces it; a side dispatch with --no-retire leaves the
  # dispatcher's own lane untouched (this code is unreachable there: retire_self
  # returned at the --no-retire gate above). This side only VALIDATES: the
  # writes and the link removal happen in retire_exec, AFTER its act-time
  # re-check decides the retirement is real — a supersession written here and
  # a retirement aborted there would leave a live seat whose lane says it was
  # replaced, and the abort path cannot restore what a dead process wrote.
  # Every validation failure errs OPEN (the old lane stays visible; nothing
  # vanishes). A re-dispatch of the SAME handoff file derives the SAME lane key
  # and skips this — the registration's `ln -sfn` already repointed the link.
  #
  # OWNERSHIP, not just presence: CLAUDE_HANDOFF_LANE is a filter hint any
  # plain `claude --bg` child inherits from its parent, so the marker alone
  # must never authorize superseding the lane — the parent may still own it.
  # The record's session_id is the job short id of the seat that was LAUNCHED
  # for the lane; only the seat whose own job dir carries that id may replace
  # it. A mismatch (an inherited marker, a resumed seat under a new job id, a
  # record that predates session_id) skips the supersession — open twice beats
  # vanished, and --close repairs it with an audit line.
  _rt_oldlane="${CLAUDE_HANDOFF_LANE:-}"
  _rt_lane_ok=""
  if [ -n "$_rt_newlane" ] && [ -n "$_rt_oldlane" ] && [ "$_rt_newlane" != "$_rt_oldlane" ] \
     && [ -L "$OPS_DIR/dispatches/$_rt_oldlane" ]; then   # CLAIM:d — a filetest on the ops ledger (the user's home config dir); unbounded if that filesystem hangs, and best-effort by design: a skip errs OPEN
    _rt_oldrec="$(readlink "$OPS_DIR/dispatches/$_rt_oldlane" 2>/dev/null)" || _rt_oldrec=""   # CLAIM:d — reads the link target from the same ledger; a failure leaves _rt_oldrec empty and the check below skips, erring open
    _rt_oldsid=""
    if [ -n "$_rt_oldrec" ] && [ -f "$_rt_oldrec" ] && rec_read "$_rt_oldrec" session_id; then _rt_oldsid="$REC_VAL"; fi   # CLAIM:d — filetest + record read on the old lane's record; a failure leaves the ownership check unsatisfied, erring open
    if [ "$_rt_oldsid" = "$_rt_me" ] && [ -n "$_rt_me" ]; then
      _rt_lane_ok=1
    else
      logline "{\"hook_event_name\":\"HandoffLaneNotOurs\",\"lane\":\"$_rt_oldlane\",\"recorded\":\"${_rt_oldsid:-none}\",\"seat\":\"$_rt_me\"}"
    fi
  fi
  _rt_lane7=""; _rt_rec7=""
  if [ -n "$_rt_lane_ok" ]; then _rt_lane7="$_rt_oldlane"; _rt_rec7="$_rt_oldrec"; fi

  # The stop runs DETACHED, for the same reason the watchdog does: it is about to
  # kill this process's own ancestor, so it cannot be this process. fds 9/8/7 are
  # closed in the spawn -- a child that inherited the dispatch lock would hold it
  # for as long as it lived, and this child deliberately outlives the seat.
  nohup "$0" --retire-exec "$_rt_jd" "$_rt_pid" "$_rt_short" "$_rt_sent" "$_rt_rec" "$_rt_bak" "$_rt_lane7" "$_rt_newlane" "$_rt_me" "$_rt_rec7" >/dev/null 2>&1 9>&- 8>&- 7>&- &   # CLAIM:b
  RETIRED="pending (state=done, sentinel written; stopping pid $_rt_pid)"
  return 0
}

# The irreversible half, in its own process.
#
# Between `state verified` and this point the successor can die -- turn-1 model
# safeguard, a spent tier limit, a transient 529. Retiring the predecessor then
# leaves the work with nobody on it, which is strictly worse than a seat that
# reads awaiting-input. So the successor is re-verified HERE, at act time, and
# the sentinel and the state file are ROLLED BACK if it is gone.
#
# Degraded reads abort too. `claude agents --json` unreadable is not "the
# successor is fine", and only a POSITIVELY observed live successor authorises
# the kill -- the same rule the watch loop already applies in the other
# direction, where only a positively observed terminal state releases ownership.
#
# RESIDUAL, not closed: the successor can still die in the window between this
# re-check and the signal. Closing that needs a fence the killer holds across the
# whole critical section, which is not built. The watchdog armed for the
# successor is what covers it: it alerts on a successor that stops.
retire_exec() {
  _re_jd="${1:-}"; _re_pid="${2:-}"; _re_short="${3:-}"
  _re_sent="${4:-}"; _re_rec="${5:-}"; _re_bak="${6:-}"
  _re_oldlane="${7:-}"; _re_newlane="${8:-}"
  _re_me="${9:-}"; _re_oldrec="${10:-}"
  [ -n "$_re_pid" ] && [ -n "$_re_short" ] || die "--retire-exec needs <jobdir> <pid> <short> <sentinel> <record> <backup> [oldlane] [newlane] [me] [oldrec]"

  _re_reason=""
  if ! read_agents; then
    _re_reason="unverifiable (\`claude agents --json\` could not be read)"
  else
    _re_id="$(lookup "$AGENTS_JSON" "$_re_short" sessionId)"
    _re_state="$(lookup "$AGENTS_JSON" "$_re_short" state)"
    if [ -z "$_re_id" ]; then
      _re_reason="no longer listed by \`claude agents --json\`"
    else
      # ALLOWLIST, not denylist. This tested `$DONE_STATES` for one revision,
      # which is fail-OPEN: every state outside that list authorised the kill,
      # including the empty string (a row that parsed but carried no state), and
      # `blocked` -- a real, reachable state for a successor that hit an approval
      # prompt -- and any enum value added to `claude agents` after this was
      # written. Retirement is irreversible, so the only thing that may authorise
      # it is a POSITIVELY OBSERVED live state.
      case "$LIVE_STATES" in
        *" $_re_state "*) : ;;
        *) _re_reason="not positively live (state '${_re_state:-<empty>}')" ;;
      esac
    fi
  fi

  if [ -n "$_re_reason" ]; then
    [ -f "$_re_bak" ] && mv -f "$_re_bak" "$_re_jd/state.json" 2>/dev/null
    rm -f "$_re_sent" 2>/dev/null || true
    rec_put "$_re_rec" retire_state retire_aborted || true
    # The REASON belongs in the audit trail, not only in a notification. An
    # abort has several causes with different meanings (vanished successor vs a
    # successor that is listed but not live vs an unreadable agent list), and
    # `retire_aborted` alone cannot tell them apart -- so a record read later
    # cannot say whether the seat was spared correctly. The notify below can be
    # undeliverable; the record is the durable half.
    rec_put "$_re_rec" retire_reason "$_re_reason" || true
    notify "predecessor NOT retired: successor $_re_short is $_re_reason — the seat stays alive so the work is not orphaned"
    return 0
  fi

  rm -f "$_re_bak" 2>/dev/null || true

  # LANE SUPERSESSION, here and not in retire_self, because only THIS side has
  # decided the retirement is real: the re-check above passed, the successor is
  # positively live, and the abort path that restores state.json can no longer
  # run. Writing the supersession before that decision left the ledger saying a
  # live seat was replaced whenever the abort fired — the rollback restored the
  # state file and the sentinel but could not un-write the lane.
  #
  # But retire_self's validation is a SNAPSHOT this detached process outlives:
  # between it and this point, a --force re-dispatch of the old handoff can
  # rewrite the SAME record for a NEW live seat and re-register the lane — an
  # act on the stale snapshot would then mark the new seat's record superseded
  # and unlink its lane, removing a LIVE dispatch from the ledger. So the
  # validated record path and owner arrive as ARGUMENTS (never re-derived by
  # following the link, which can have moved), and both facts are re-verified
  # HERE, under the record's dispatch lock — the same lock a dispatch of that
  # handoff holds, so an in-flight re-dispatch wins by holding it. Every
  # failure errs OPEN: the old lane stays visible, closable later by --close
  # with an audit line; open twice beats vanished.
  if [ -n "$_re_oldlane" ] && [ -n "$_re_newlane" ] && [ -n "$_re_me" ] \
     && [ -n "$_re_oldrec" ] && [ -f "$_re_oldrec" ]; then
    lock_hold 9 "$_re_oldrec.flock"; _re_lk=$?
    # Every nonzero status skips identically — "do not act" — and only the
    # audit event differs: 1 is an OBSERVED holder, everything else is "could
    # not tell", where naming a cause would be inventing one.
    if [ "$_re_lk" = 0 ]; then
      _re_now="$(readlink "$OPS_DIR/dispatches/$_re_oldlane" 2>/dev/null)" || _re_now=""
      _re_sid=""
      if [ "$_re_now" = "$_re_oldrec" ] && rec_read "$_re_oldrec" session_id; then _re_sid="$REC_VAL"; fi
      if [ "$_re_sid" = "$_re_me" ]; then
        # SUPERSEDE-ORDER-BEGIN
        # Write-before-remove: the link comes off only after BOTH record writes
        # land, so a failure errs OPEN (a lane that looks open twice) and never
        # CLOSED (work that vanished). The ORDER inside the `&&` chain is an
        # intent pin, not an outcome-testable property: both rec_put calls
        # append to the same file with the same permissions and internally
        # generated, pre-validated values, so no reachable input fails the
        # second write while the first succeeds — a reordered mutant is
        # outcome-unobservable, and the suite pins the order STRUCTURALLY (it
        # asserts these lines' relative positions) instead of pretending a
        # fixture could reach the difference.
        if rec_put "$_re_oldrec" disposition superseded \
           && rec_put "$_re_oldrec" superseded_by "$_re_newlane"; then
          rm -f "$OPS_DIR/dispatches/$_re_oldlane" 2>/dev/null || true
          logline "{\"hook_event_name\":\"HandoffLaneSuperseded\",\"lane\":\"$_re_oldlane\",\"by\":\"$_re_newlane\"}"
        fi
        # SUPERSEDE-ORDER-END
      else
        logline "{\"hook_event_name\":\"HandoffLaneMovedAtAct\",\"lane\":\"$_re_oldlane\",\"recorded\":\"${_re_sid:-none}\",\"seat\":\"$_re_me\"}"
      fi
    elif [ "$_re_lk" = 1 ]; then
      # lock_hold's 1 is "someone else holds it", and the only other taker of
      # this lock is a dispatch of the old handoff — busy is a fact here.
      logline "{\"hook_event_name\":\"HandoffLaneLockBusyAtAct\",\"lane\":\"$_re_oldlane\"}"
    else
      # Status 2 collapses causes (unopenable path, symlink at the lock path,
      # dead lock backend) and no holder was observed — this event states only
      # that the lock was not acquired and names NO cause, so none of the
      # collapsed causes can be named falsely.
      logline "{\"hook_event_name\":\"HandoffLaneLockNotAcquiredAtAct\",\"lane\":\"$_re_oldlane\"}"
    fi
    # Release before the kill loop below: holding the dispatch lock through a
    # grace period would block a re-dispatch of the old handoff for its length.
    exec 9>&-
  fi

  kill -TERM "$_re_pid" 2>/dev/null || true
  _re_n=0
  while [ "$_re_n" -lt "$RETIRE_GRACE_SEC" ]; do
    kill -0 "$_re_pid" 2>/dev/null || break
    sleep 1
    _re_n=$(( _re_n + 1 ))
  done
  if kill -0 "$_re_pid" 2>/dev/null; then
    kill -KILL "$_re_pid" 2>/dev/null || true
    sleep 1
  fi
  # The OUTCOME is durable, both ways. A retirement that silently failed is a
  # seat that still reads awaiting-input with a state file that says otherwise --
  # exactly the confusion this change exists to remove.
  if kill -0 "$_re_pid" 2>/dev/null; then
    rec_put "$_re_rec" retire_state retire_failed || true
    notify "predecessor seat ${_re_jd##*/} would not stop: pid $_re_pid survived SIGKILL — it may still read as awaiting input"
  else
    rec_put "$_re_rec" retire_state retired || true
    logline "{\"hook_event_name\":\"HandoffRetired\",\"session\":\"${_re_jd##*/}\",\"successor\":\"$_re_short\"}"
  fi
  return 0
}


dispatch() {
  FILE="$1"; shift
  # The objective is positional, and an option token must never silently become
  # it: `handoff.sh HANDOFF --dry-run` used to assign "--dry-run" to the
  # objective, leave DRY=0, and perform a REAL dispatch. `--` is the escape for
  # an objective that must start with a dash.
  OBJ=""
  if [ $# -gt 0 ] && [ "$1" = "--" ]; then
    shift
    [ $# -gt 0 ] || die "an objective is required after --"
    OBJ="$1"; shift
  elif [ $# -gt 0 ]; then
    case "$1" in
      -*) die "the objective is missing: '$1' looks like an option. Usage: handoff.sh <handoff-file> <objective> [options]  (use -- before an objective that starts with a dash)" ;;
    esac
    OBJ="$1"; shift
  fi
  # the user 2026-08-21: a CONTINUED session defaults to Fable, so the fleet does
  # not silently run a whole shift on the expensive tier. `${VAR-default}`,
  # not `:-`, so CLAUDE_HANDOFF_MODEL="" still means "inherit whatever
  # `claude --bg` picks"; an explicit --model always wins over both.
  # the user 2026-08-28: "whenever handing off to new sessions, use auto mode,
  # ideally bypass permissions." This used to be PMODE="" — the flag was omitted
  # entirely and the successor booted in the PROMPTING class, which is the one
  # mode that parks an unattended seat forever on a tool-approval prompt that no
  # `SendMessage` can drain (the seat never reaches a tool round, so the message
  # is never read). The default lives here so it holds for every caller, not only
  # the ones who remember the flag. A seat that SHOULD still gate something is
  # given `--permission-mode auto`; one that should prompt like a human session,
  # `--permission-mode manual`. Deliberately NOT an env-var default: a bg seat
  # exports CLAUDE_HANDOFF_MODEL into every seat it dispatches, which is exactly
  # how the Fable default above became dead code inside the fleet — a constant
  # cannot be defeated that way.
  CWD="$PWD"; MODEL="${CLAUDE_HANDOFF_MODEL-claude-fable-5[1m]}"; PMODE="bypassPermissions"; FORCE=0; DRY=0; NOWATCH=0; NORETIRE=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --cwd) need_val "$1" $# "${2:-}"; CWD="$2"; shift 2 ;;
      --model) need_val "$1" $# "${2:-}"; MODEL="$2"; shift 2 ;;
      --permission-mode) need_val "$1" $# "${2:-}"; PMODE="$2"; shift 2 ;;
      --heartbeat-min|--stall-min) need_val "$1" $# "${2:-}"; need_num "$1" "$2"; HEARTBEAT_MIN="$2"; shift 2 ;;
      --poll-sec) need_val "$1" $# "${2:-}"; need_num "$1" "$2"; POLL_SEC="$2"; shift 2 ;;
      --force) FORCE=1; shift ;;
      --dry-run) DRY=1; shift ;;
      --no-watch) NOWATCH=1; shift ;;
      --no-retire) NORETIRE=1; shift ;;
      *) die "unknown option: $1" ;;
    esac
  done

  # `-r` and `-s` are both true of a DIRECTORY, so `handoff.sh docs/ obj` passed
  # every check here and dispatched a successor told to read a directory as its
  # only context.
  # A seat that has ALREADY handed off must not hand off again. The sentinel is
  # written the moment a dispatch verifies, so this is the durable half of the
  # same guard hooks/context-watchdog.mjs applies on the advice side: the hook
  # stops the seat being TOLD to dispatch a second successor, and this stops it
  # succeeding if something tells it anyway. Both are needed -- the hook is one
  # of several things that can say "hand off", and prose in a system prompt is
  # advisory, while this is not.
  if [ "$FORCE" = 0 ] && [ -n "${CLAUDE_CODE_SESSION_ID:-}" ] \
     && [ -f "$STATE_DIR/${CLAUDE_CODE_SESSION_ID}.handed-off" ]; then
    die "this session has already handed off (see $STATE_DIR/${CLAUDE_CODE_SESSION_ID}.handed-off) — refusing to dispatch a second successor, which would duplicate the work; --force to override"
  fi

  [ -r "$FILE" ] || die "handoff file is not readable: $FILE"
  [ -f "$FILE" ] || die "handoff file is not a regular file: $FILE — a directory cannot be a successor's only context"
  [ -s "$FILE" ] || die "handoff file is empty: $FILE — a successor cannot act on nothing"
  # Validated on the RAW argument, before resolution: `$(cd … && pwd)` and
  # `$(basename …)` strip trailing newlines, so a path whose last character is a
  # newline resolves to a DIFFERENT path than the one just proven readable — the
  # checks above would describe one file and the record, prompt and watcher would
  # name another.
  rec_ok_value "$FILE" || die "the handoff file path spans lines (it contains a newline or carriage return) — refusing: resolution would silently strip it and name a different file than the one checked"
  rec_ok_value "$CWD" || die "the --cwd path spans lines (it contains a newline or carriage return) — refusing, for the same reason"
  [ -n "$OBJ" ] || die "an objective is required (one line: what the successor should accomplish)"
  rec_ok_value "$OBJ" || die "the objective must be a single line — a newline in a record value can forge another field and defeat the duplicate-dispatch check"
  # `pwd` is LOGICAL: under a symlinked ancestor (/var -> /private/var on macOS)
  # it echoes the path as spelled, while the successor row reports the PHYSICAL
  # one — the same class as the install.sh $HOME bug fixed in 8bbfdec. Both sides
  # of the comparison below must be physical or a correct dispatch reads as
  # running in the wrong repository.
  # Identity is the OBJECT, not the spelling — resolve_path is the one authority
  # for that, shared with --watch so the dispatcher and its watcher can never
  # disagree about which record they are talking about.
  resolve_path "$FILE" "handoff file"
  FILE_ABS="$RESOLVED"
  # The three checks above proved the SPELLING readable. The target is a
  # different object and gets the same three, or a dangling link dispatches a
  # successor whose only context does not exist.
  [ -r "$FILE_ABS" ] || die "handoff file is not readable once resolved: $FILE_ABS"
  [ -f "$FILE_ABS" ] || die "the handoff path resolves to something that is not a regular file: $FILE_ABS"
  [ -s "$FILE_ABS" ] || die "handoff file is empty once resolved: $FILE_ABS — a successor cannot act on nothing"
  # The hard-link twin of the symlink case above, and resolution cannot close it:
  # neither name is more real than the other, so there is no canonical spelling to
  # resolve to. Two names for one inode get two records, two locks and two
  # dispatches that both launch (round-5 correctness #1). No legitimate handoff
  # has a second name, and no record path could serve both, so refuse rather than
  # pick one. A link count nobody could read is not a link count of 1.
  _nl0=""
  fs_get "$FS_TIMEOUT_SEC" file_nlink "$FILE_ABS"; _nl0r=$?
  [ "$_nl0r" = 0 ] && _nl0="$FS_VAL"
  # `file_nlink` ENDS IN `printf` AND SO ALWAYS RETURNS 0, printing nothing when
  # `stat` does not give it a number — which means `fs_get` succeeds, `FS_WHY_TXT`
  # is cleared to the empty string, and the failure arrives here as an empty value
  # with no reason attached. The old text said "the filesystem did not answer" for
  # both paths, and a naive `$FS_WHY_TXT` here would have printed an empty
  # parenthetical (round 6 micro-review 3). So the reason is chosen by which of
  # the two actually happened.
  #   Corrected in micro-review 4, and the replacement claim was overstated: it
  # said the empty-value path meant "`stat` refused rather than the read timing
  # out". `file_nlink` discards `stat`'s status with `|| true` and then throws
  # away any output that is not all digits, so a `stat` that EXITS 0 printing
  # garbage lands here identically — reproduced with a PATH shim printing
  # `this-is-not-a-number` and exiting 0. The words come from `fs_novalue_set`
  # now, which says the probe answered and the answer was unusable, and leaves
  # the culprit as a possibility rather than a finding.
  if [ "$_nl0r" != 0 ]; then _nlwhy="$FS_WHY_TXT"
  else fs_novalue_set "link-count probe on $FILE_ABS"; _nlwhy="$FS_NOVALUE_TXT"; fi
  [ -n "$_nl0" ] || die "cannot count the names of the handoff file $FILE_ABS ($_nlwhy) — refusing, because a second hard link to it would give a second dispatch its own record and its own lock, and both would launch"
  [ "$_nl0" = 1 ] || die "the handoff file $FILE_ABS has $_nl0 names (hard links) — refusing, because each name gets its own dispatch record and its own lock, so two dispatches would each launch a paid successor for this one handoff. Dispatch one name and remove the others"
  # Remembered for the re-check at the irreversible boundary (C4 below).
  # The reason travels WITH the read, because the second one happens hundreds of
  # lines later and `FS_WHY_TXT` belongs to whatever ran most recently.
  _ino0=""; _ino0why=""
  fs_get "$FS_TIMEOUT_SEC" file_ident "$FILE_ABS" && _ino0="$FS_VAL" || _ino0why="$FS_WHY_TXT"
  [ -n "$_ino0" ] || [ -n "$_ino0why" ] || { fs_novalue_set "identity probe on $FILE_ABS"; _ino0why="$FS_NOVALUE_TXT"; }
  # The record path gets the same treatment for the same reason: if this name is
  # a symlink, dispatch would write through it while --watch (which resolves)
  # leased the target, and the two would claim different paths for one handoff.
  REC="$FILE_ABS.dispatch"
  resolve_path "$REC" "dispatch record"
  REC="$RESOLVED"
  # Derived here, from the resolved path, so the prompt below can name it and
  # the registration write cannot disagree with it.
  LANE="$(lane_key "$FILE_ABS")" || die "cannot derive a lane key for $FILE_ABS (no usable md5 on this box) — refusing to dispatch a successor whose lane could not be registered in $OPS_DIR/dispatches"
  CWD_ABS="$( exec 9>&- 8>&- 7>&-; cd "$CWD" 2>/dev/null && pwd -P )" || die "cwd is not a directory: $CWD"
  # Both of these become record VALUES, and a value that spans lines forges a
  # field: a handoff filename ending in $'\nfinished=1' wrote a literal
  # finished=1 line, which made --watch treat a live successor as complete and
  # exit successfully on its first poll. Validated here as well as at the write,
  # so the refusal names the actual cause instead of failing at record time.
  rec_ok_value "$FILE_ABS" || die "the handoff file's resolved path spans lines (it contains a newline or carriage return) — refusing, because a record value that spans lines can forge another field such as finished=1 and defeat the duplicate-dispatch check"
  rec_ok_value "$CWD_ABS" || die "the resolved --cwd spans lines (it contains a newline or carriage return) — refusing, for the same reason: a multi-line record value can forge a field"

  if [ "$DRY" = 1 ]; then
    # EVERY OPERAND GOES THROUGH shq. This line is the answer `--dry-run` exists
    # to give — "here is the command I would run" — and unquoted it could not
    # give it: `--model 'opus; touch x'` printed as `--model opus; touch x`,
    # which reads as two commands, and a --cwd or a claude path with a space in
    # it printed as two arguments. The operator cannot check a command whose word
    # boundaries are gone (round 6, C5 — reproduced). Same class as `claude
    # attach` and `rm -rf --` (tests/paste-census.awk), and it was the one member
    # of that class the census could not see, because its token is a FLAG with
    # the interpolations in front of it rather than a command name with them
    # behind. `<charter>` and `<prompt>` stay placeholders: the two operands that
    # are megabytes of text are not printable, so this is a faithful rendering
    # rather than a literal paste.
    # The SHQ_ prefix on these names is load-bearing: the census reads SHQ vs RAW
    # off the name, and case DA's negative control rewrites `$SHQ` to break it.
    shq "$CWD_ABS";     SHQ_CWD="$SHQ"
    shq "$CLAUDE_BIN";  SHQ_BIN="$SHQ"
    shq "$FILE_ABS";    SHQ_FILE="$SHQ"
    SHQ_MODEL=""; SHQ_PMODE=""
    if [ -n "$MODEL" ]; then shq "$MODEL"; SHQ_MODEL=" --model $SHQ"; fi
    if [ -n "$PMODE" ]; then shq "$PMODE"; SHQ_PMODE=" --permission-mode $SHQ"; fi
    printf 'handoff: would run in %s:\n  %s --bg%s%s --append-system-prompt <charter> <prompt>\n' \
      "$SHQ_CWD" "$SHQ_BIN" "$SHQ_MODEL" "$SHQ_PMODE"
    printf 'handoff: prompt would name %s with objective: %s\n' "$SHQ_FILE" "$OBJ"
    printf 'handoff: would register lane %s in %s\n' "$LANE" "$OPS_DIR/dispatches"
    return 0
  fi

  # Ownership is claimed at FIRE time, atomically, and held until the record is
  # durable. Without the lock two callers both read "no live successor" and both
  # spawn — the check and the act must be one step.
  # The lock lives at `$REC.flock`; `$REC.lock` is the mkdir/link-shaped path the
  # predecessors of this design left on disk, and it is passed in to be swept
  # BEFORE a descriptor is opened — never by the primitive that does the locking.
  claim_lock "$REC.flock" "$REC.lock"
  # CLAIM-REGION-BEGIN dispatch

  # An unobservable record is not an absent record. Truncating `$REC` on a probe
  # that never answered is exactly how a live successor's row gets overwritten
  # and a second one paid for, so this refuses instead — the same fail-closed
  # direction the reads immediately below already take.
  if [ "$FORCE" = 0 ]; then
    fs_get "$FS_TIMEOUT_SEC" file_exists "$REC" || die "could not tell whether a dispatch record already exists at $REC — $FS_WHY_TXT, and starting a successor on an observation that was never made is how two get started for one handoff"
    _recthere="$FS_VAL"
  else
    _recthere=""
  fi
  if [ "$_recthere" = 1 ]; then
    # COMPOSED AT THE DIE, not here. `FS_WHY_TXT` names what the most recent
    # bounded read did, so a message built in advance would carry the cause of
    # whatever ran before it — the same staleness class as reading a record row
    # taken before the act.
    _recread_a="cannot read the existing dispatch record $REC ("
    _recread_b=") — refusing, because a record that cannot be read cannot rule out a live successor"
    rec_read "$REC" session_id || die "$_recread_a$FS_WHY_TXT$_recread_b"
    PREV="$REC_VAL"
    rec_read "$REC" state || die "$_recread_a$FS_WHY_TXT$_recread_b"
    PREV_ST="$REC_VAL"
    # `launching` means a previous run was killed between writing its intent and
    # parsing the session id: a successor may exist that no id names. Absence of
    # a session id is NOT permission to start another one.
    #
    # EVERY state this launcher writes is named below, and anything else
    # refuses. The shape matters as much as the values: testing only for the two
    # blocking states made every retryable one retryable by falling off the end
    # of an `if`, so naming `prelaunch_failed` there was decoration — deleting
    # that arm changed nothing observable and the case written to pin it passed
    # on the mutant. An enumeration with a closed default is a control that can
    # fail. It is also the right answer on its own terms: a recorded state this
    # version does not recognise — a hand-edit, a half-written line, a newer
    # launcher's vocabulary — cannot rule out a live successor, and the way past
    # it is --force, which skips this whole block.
    case "$PREV_ST" in
      unknown|launching)
        # Refusing is not enough. A successor recorded as `unknown` (its launch
        # succeeded, then the agent read timed out) had a session id and NO
        # watcher, and every later dispatch refused here and walked away —
        # leaving exactly the unwatched live successor this script exists to
        # prevent. If we can name it, re-arm monitoring before refusing.
        [ -n "$PREV" ] && reconcile_watch "$REC" "$PREV"
        die "a previous dispatch for ${FILE_ABS##*/} is recorded as '$PREV_ST' (session ${PREV:-unparsed}) — a successor may be running. Check \`handoff.sh --status\`, then --force if it is truly gone"
        ;;
      ""|prelaunch_failed|failed|pending|verified)
        # `prelaunch_failed`: the dispatch died at one of the boundary fences
        # below, before the launcher ran, so nothing was started and a retry
        # needs no --force. `failed` is a THIRD fact — the launcher ran and the
        # registry proved nothing was backgrounded — retryable for its own
        # reason, not by sharing this one's. `pending`/`verified` name a
        # successor that WAS launched: they pass HERE because the liveness
        # question about it is the session-id check below, which is a better
        # question than the recorded state. "" is a record carrying no state key
        # at all; it asserts nothing, and the same check governs it.
        : ;;
      *)
        die "a previous dispatch for ${FILE_ABS##*/} is recorded in a state this launcher does not recognise ('$PREV_ST', session ${PREV:-unparsed}) — refusing, because a state that cannot be interpreted cannot rule out a live successor. Check \`handoff.sh --status\`, then --force if it is truly gone"
        ;;
    esac
    if [ -n "$PREV" ]; then
      read_agents || die "cannot read \`claude agents --json\`, so a live successor cannot be ruled out — refusing to dispatch (use --force if you are sure)"
      # PRESENCE decides, then state narrows it. `lookup` returns "" both for "no
      # such row" and "the row is there with an unreadable state", and those two
      # want OPPOSITE answers: gone means go ahead, present-but-unreadable means
      # a successor is very likely alive and must not be duplicated.
      # 2 is "the probe did not run", and it must land with the `die` above, not
      # with the fall-through: an unanswerable presence question cannot rule out
      # a live successor, and dispatching on it starts a SECOND one.
      row_present "$AGENTS_JSON" "$PREV"; _dp=$?
      [ "$_dp" = 2 ] && die "the check for a live successor ($PREV) could not be run, so one cannot be ruled out — refusing to dispatch (use --force if you are sure)"
      if [ "$_dp" = 0 ]; then
        PREV_STATE="$( exec 9>&- 8>&- 7>&-; lookup "$AGENTS_JSON" "$PREV" state )"   # CLAIM:b
        PREV_LIVE=1
        case "$DONE_STATES" in *" $PREV_STATE "*) PREV_LIVE=0 ;; esac
        if [ "$PREV_LIVE" = 1 ]; then
          reconcile_watch "$REC" "$PREV"
          die "a live successor ($PREV, ${PREV_STATE:-state unreadable}) is already on record for ${FILE_ABS##*/} — use --force to dispatch anyway"
        fi
      fi
    fi
  fi

  PROMPT="Read the handoff file at $FILE_ABS. It is your only context: nothing from the session that wrote it carries over.
Objective: $OBJ
Record progress back into that file as you go, so a stall is legible from the artifact.
This work is lane $LANE in the operational ledger (~/.claude/ops/ — read its README.md once). Your session ending does NOT close the lane: when the objective is COMPLETE (or the work is cancelled or superseded), run: ~/dotfiles/claude/hooks/handoff.sh --close $LANE completed (or cancelled/superseded) with a one-line note; handing off onward with handoff.sh moves the lane automatically. Anything unresolved you discover and are NOT handing forward must be written to ~/.claude/ops/lanes/ before your window ends."

  # ADVISORY, not enforced: this is prose in a system prompt, and a same-user
  # session can do anything the user could. The launcher enforces ownership,
  # path resolution and dispatch identity; everything below relies on the
  # successor's compliance and is surfaced for review, not machine-guaranteed.
  #
  # CHARTER-BLOCK-BEGIN -- docs/handoff-successor.md reproduces these lines
  # VERBATIM and case CHARTER asserts both directions. A successor is told what
  # it may do by this string and nothing else, so a doc that drifts from it is
  # documentation of a prompt that no session was ever given. Edit both, or the
  # suite fails.
  #   The merge rule is a GATE LIST, not a prohibition. The prohibition it
  # replaced ("do not merge to main") was contradicted by the standing directive
  # to merge whenever mechanically safe, and on 2026-08-26 seat 4b5fd6f9 had to
  # violate this charter to do the correct thing -- 17/17 green, freeze clear,
  # deploy 32925151388 succeeded. A charter the correct action must break is a
  # defect in the charter. What survives is every gate, stated so it can be
  # checked rather than felt.
  CHARTER="You are an unattended successor session dispatched from a handoff file.
- Merge when every required gate below passes, and do not wait for permission to do it. A green merge is EXPECTED to trigger the normal production deploy; that is not a reason to hold one.
- The gates are ALL of: every required CI and review check green on the exact head you are merging; the head you merge is the head that was reviewed; no merge conflict; no deploy or box-side work already in flight; and the deploy freeze CLEAR.
- Read the freeze with scripts/deploy-freeze.sh status where it exists. CLEAR passes. FROZEN and UNKNOWN both FAIL, and UNKNOWN means the signal could not be read, never that no freeze is set. Where no such script exists the gate is UNESTABLISHED, which is also not a pass: say so and establish the deploy state another way before merging.
- After merging, watch the deploy pinned by YOUR merge SHA and confirm the deployed artifact carries the change; a green tick is not a deployment.
- Do not spend money or credits beyond an envelope the handoff file records as already approved.
- Write progress into the handoff file as you go, so a stall is legible from the artifact.
- Stop and report rather than improvising past the objective."
  # CHARTER-BLOCK-END

  set -- --bg
  [ -n "$MODEL" ] && set -- "$@" --model "$MODEL"
  [ -n "$PMODE" ] && set -- "$@" --permission-mode "$PMODE"
  set -- "$@" --append-system-prompt "$CHARTER" "$PROMPT"

  # The INTENT is durable before the launch, and the record is proven writable
  # before a successor can exist. A kill in the window between `claude --bg`
  # returning and the record being written used to leave a running successor
  # with no record at all — which the next caller read as permission to start
  # another one. It now leaves state=launching, which refuses without --force.
  # Every dynamic value goes through rec_put, which validates it. The previous
  # raw printf block bypassed that for cwd= and handoff= — the two of twenty-four
  # record writes that took an unvalidated value (class C).
  _recfail="cannot write the dispatch record $REC — refusing to launch a successor that could not be recorded"
  : > "$REC" || die "$_recfail"   # CLAIM:d — a truncate; see rec_put
  rec_put "$REC" state launching || die "$_recfail"
  # AN UNANSWERED CLOCK IS NOT A TIME. `rec_ok_value` rejects only NL and CR, so
  # an EMPTY string and a zero sail into the record, and `dispatched_epoch=0`
  # then told a later, perfectly healthy watcher that the successor had written
  # no transcript in 29785107 minutes (round 6, C3 — reproduced end to end). The
  # keys are omitted instead, and the FACT of the failure is recorded so the
  # watcher can say "I cannot judge the deadline" rather than invent an age.
  if now_utc && epoch; then
    rec_put "$REC" dispatched_at "$NOW_UTC" || die "$_recfail"
    rec_put "$REC" dispatched_epoch "$EPOCH" || die "$_recfail"
  else
    rec_put "$REC" dispatch_clock_lost 1 || die "$_recfail"
    logline "{\"hook_event_name\":\"HandoffDispatchClockLost\",\"rec\":\"$REC\"}"
  fi
  rec_put "$REC" cwd "$CWD_ABS" || die "$_recfail"
  rec_put "$REC" handoff "$FILE_ABS" || die "$_recfail"
  rec_put "$REC" objective "$OBJ" || die "$_recfail"
  # LANE REGISTRATION — the discoverability half of the 2026-08-31 decision.
  # Fail-closed like every record write: a dispatched successor that a
  # reconstructing coordinator cannot find is the RCA defect with extra steps.
  # `ln -sfn` is idempotent for a re-dispatch (same lane, same record). The
  # link lands BEFORE the prelaunch re-checks and the launch, so a prelaunch
  # failure leaves an open lane pointing at state=prelaunch_failed — which is
  # TRUE: the work exists and is not running.
  rec_put "$REC" lane "$LANE" || die "$_recfail"
  mkdir -p "$OPS_DIR/dispatches" "$OPS_DIR/lanes" 2>/dev/null || die "cannot create the operational ledger at $OPS_DIR — refusing to launch a successor that could not be registered"   # CLAIM:d — creates the ledger dirs in the user's home; unbounded on a hung filesystem, and fail-CLOSED on purpose: no ledger, no launch
  # The lane key's hash half is 8 hex digits, so two DIFFERENT handoff paths
  # can derive one key; `ln -sfn` would then silently repoint the first
  # dispatch's registration at the second's record, leaving the first's live
  # successor with no lane. Same identity, same record (a re-dispatch) passes;
  # anything else refuses. And an occupant that is NOT a symlink refuses too,
  # because `ln -sfn` into a real directory does not fail — it creates the
  # link INSIDE the directory, a registration every reader of the ledger would
  # miss (measured on this platform). RESIDUAL: this runs under the RECORD's
  # lock, which colliding paths do not share, so two simultaneous first
  # dispatches of a colliding pair can still interleave past it; closing that
  # needs a per-lane lock, which is not built. The sequential case — the one a
  # human or a coordinator actually produces — refuses loudly.
  if [ -L "$OPS_DIR/dispatches/$LANE" ]; then   # CLAIM:d — a filetest on the ops ledger; unbounded if that filesystem hangs, fail-closed like the registration it guards
    _lncur="$(readlink "$OPS_DIR/dispatches/$LANE" 2>/dev/null)" || _lncur=""   # CLAIM:d — reads the current registration's target; an unreadable target refuses below rather than overwriting it
    [ "$_lncur" = "$REC" ] || die "lane $LANE is already registered for a different handoff (its record is ${_lncur:-unreadable}, this dispatch's is $REC) — two handoff paths can derive the same lane key, and overwriting the registration would leave the other dispatch's successor with no lane; close or rename one of the two handoff files first"
  elif [ -e "$OPS_DIR/dispatches/$LANE" ]; then   # CLAIM:d — same ledger filetest as above; a non-link occupant refuses because ln -sfn would silently create the link inside a directory
    die "something that is not a lane link occupies $OPS_DIR/dispatches/$LANE — refusing to register over it, because \`ln -sfn\` onto a directory silently creates the link inside it and the lane would look registered while no reader can find it; investigate and remove the occupant by hand"
  fi
  ln -sfn "$REC" "$OPS_DIR/dispatches/$LANE" 2>/dev/null || die "cannot register lane $LANE in $OPS_DIR/dispatches — refusing to launch an unregistered successor"   # CLAIM:d — registers the lane; same property as the mkdir above: a successor a coordinator cannot find must not be launched

  # Last fence before the irreversible step — and the lock is not the only thing
  # that has to still be true. Every check on the handoff file happened before
  # the claim and before the record write, and in that window the file can be
  # removed, truncated or REPLACED: the successor is then dispatched to read a
  # path whose content is gone, and its whole context with it (round-4
  # correctness C4). Re-assert the three predicates AND the object identity here,
  # at the boundary itself.
  fs_get "$FS_TIMEOUT_SEC" file_dispatchable "$FILE_ABS" || prelaunch_die "$REC" "could not re-check the handoff file $FILE_ABS at the dispatch boundary — $FS_WHY_TXT; refusing to spend a dispatch on an observation that was never made"
  [ "$FS_VAL" = 1 ] || prelaunch_die "$REC" "the handoff file $FILE_ABS was removed, emptied or made unreadable after it was checked — refusing to dispatch a successor whose only context is gone"
  # ...and it may not have BECOME a symlink since it was resolved. The resolution
  # loop exited on a path that was not one, but `-L` and the identity read are
  # separate syscalls: replace the regular file with a link to another handoff in
  # that window and BOTH inode reads follow the link and agree, while REC, the
  # lock and every alert key stay on this spelling. A dispatch aimed at the target
  # then takes a different lock, and both launch (round-5 lifecycle #1). Ask again
  # here, where the lock is already held and the next step is irreversible.
  fs_get "$FS_TIMEOUT_SEC" file_is_symlink "$FILE_ABS" || prelaunch_die "$REC" "could not re-check whether $FILE_ABS is a symlink at the dispatch boundary — $FS_WHY_TXT; refusing"
  [ "$FS_VAL" != 1 ] || prelaunch_die "$REC" "the handoff path $FILE_ABS became a symlink after it was resolved — refusing, because this dispatch's lock is on that spelling while the file now lives elsewhere, and a dispatch aimed at the target would take a different lock and launch a second successor"
  _ino1=""; _ino1why=""
  fs_get "$FS_TIMEOUT_SEC" file_ident "$FILE_ABS" && _ino1="$FS_VAL" || _ino1why="$FS_WHY_TXT"
  [ -n "$_ino1" ] || [ -n "$_ino1why" ] || { fs_novalue_set "identity probe on $FILE_ABS"; _ino1why="$FS_NOVALUE_TXT"; }
  # BOTH reads are required. `[ -n "$_ino0" ] && [ -n "$_ino1" ] && ...` made an
  # unreadable identity read as "unchanged", so a stat that timed out -- or a
  # `stat` whose output failed the shape check -- skipped the guard entirely and
  # paid for the successor anyway. A degraded observation is never a value: the
  # branch's own rule, violated at the one site where the next step is
  # irreversible. Fails closed BEFORE the launcher, so the record is left at
  # state=prelaunch_failed and a retry cannot duplicate anything.
  # WHICH of the two reads failed, and why IT failed. Both can fail, and they
  # fail hundreds of lines apart under different conditions; "the filesystem did
  # not answer" named neither the read nor a cause anyone observed — `file_ident`
  # ends in `printf` and so returns 0 while printing nothing, which arrives here
  # as an empty value after a SUCCESSFUL, instant read (round 6 micro-review 3).
  if [ -z "$_ino0" ] || [ -z "$_ino1" ]; then
    if [ -z "$_ino0" ] && [ -z "$_ino1" ]; then _inowhy="neither identity read succeeded — the first: $_ino0why; the second: $_ino1why"
    elif [ -z "$_ino0" ]; then _inowhy="the identity read taken when the file was validated did not produce one: $_ino0why"
    else _inowhy="the identity read taken here at the dispatch boundary did not produce one: $_ino1why"; fi
    prelaunch_die "$REC" "cannot establish the identity of the handoff file $FILE_ABS at the dispatch boundary ($_inowhy) — refusing to dispatch, because a file REPLACED since it was validated would be indistinguishable from one that was not"
  fi
  if [ "$_ino0" != "$_ino1" ]; then
    prelaunch_die "$REC" "the handoff file $FILE_ABS was REPLACED after it was checked ($_ino0 -> $_ino1) — refusing to dispatch a successor pointed at a different file than the one that was validated"
  fi
  verify_lock

  # SPAWN SITE 10, the one that matters most: the successor outlives this
  # process by design, and an inherited fd 9 would hold the dispatch lock for as
  # long as the successor runs — every later dispatch for this handoff would
  # refuse. Pinned from the child's side by case BE.
  # A nonzero exit here is NOT evidence that nothing was launched: `claude --bg`
  # can background a session, print its id, and still exit nonzero afterwards on
  # a client-side error. Recording that as `failed` — the one previous state a
  # retry walks straight past — is what pays for the second successor. This is
  # the money lesson already written down for the registrar: "intent sent, outcome
  # unknown" is its own state, and it is not the retryable one. So the exit
  # status decides nothing on its own; the id does, and failing that, the
  # registry.
  _lrc=0
  OUT="$( exec 9>&- 8>&- 7>&-; cd "$CWD_ABS" 2>/dev/null && CLAUDE_HANDOFF_LANE="$LANE" "$CLAUDE_BIN" "$@" 2>&1 )" || _lrc=$?   # CLAIM:d — the operation the claim EXISTS to protect, not work done incidentally under it. A ceiling is coherent (expiry maps onto the existing state=unknown + bg_here path) but choosing it wrong turns a slow cold start into a false "may be running". Proposed 600s; filed in docs/handoff-successor.md, "Still open on this branch"
  # Both parses run under the held dispatch lock, between the launch and the
  # record write — the one window where a wedged fork costs a successor nobody
  # is watching. They read a string already in memory, so a deadline can only
  # ever be hit by the fork itself, and an unanswered parse falls through to the
  # empty-SHORT arm below, which is the registry-decides path.
  fs_get "$FS_TIMEOUT_SEC" _short_backgrounded "$OUT" || FS_VAL=""
  SHORT="$FS_VAL"
  if [ -z "$SHORT" ]; then
    fs_get "$FS_TIMEOUT_SEC" _short_hexid "$OUT" || FS_VAL=""
    SHORT="$FS_VAL"
  fi
  if [ -z "$SHORT" ]; then
    # Nothing to verify against, so the registry is the only witness left. It
    # cannot identify OUR successor, but it can answer the question that decides
    # the state: was anything backgrounded in this directory at all?
    if ! bg_here "$CWD_ABS"; then
      rec_put "$REC" state unknown || true
      notify "a successor may have been launched for ${FILE_ABS##*/} — claude --bg exited $_lrc without naming a session and \`claude agents --json\` could not be read; check by hand"
      die "could not parse a session id from claude --bg output (exit $_lrc), and \`claude agents --json\` could not be read to find out whether one was started anyway — an unreadable registry is not evidence that nothing was launched, so this is recorded as state=unknown and an unforced retry is refused (--force to override): $OUT"
    fi
    if [ "$BG_HERE" != 0 ] || [ "$BG_AMBIG" != 0 ]; then
      rec_put "$REC" state unknown || true
      notify "a successor may have been launched for ${FILE_ABS##*/} — claude --bg exited $_lrc without naming a session, and background sessions are running in $CWD_ABS; check \`claude agents\` by hand"
      die "could not parse a session id from claude --bg output (exit $_lrc), and \`claude agents --json\` lists $BG_HERE background session(s) in $CWD_ABS (and $BG_AMBIG whose directory could not be placed) — one of them may be this successor, so this is recorded as state=unknown and an unforced retry is refused (--force to override): $OUT"
    fi
    # The registry was READ, and it shows nothing backgrounded here: no successor
    # exists, so this one is retryable and says so.
    rec_put "$REC" state failed || true
    die "claude --bg exited $_lrc without naming a session, and \`claude agents --json\` lists no background session in $CWD_ABS — nothing was launched, so this is recorded as state=failed and can simply be retried: $OUT"
  fi

  # A successor now exists. Name it, and move off `launching`, before verifying:
  # a verification that fails must leave a remembered maybe-running session
  # rather than an orphan the next call cheerfully duplicates.
  verify_lock
  rec_put "$REC" session_id "$SHORT" || die "launched $SHORT but could not record it in $REC — check \`handoff.sh --status\` by hand"
  rec_put "$REC" state pending || die "launched $SHORT but could not record it in $REC — check \`handoff.sh --status\` by hand"

  # Verify against the artifact, never against the launcher's own echo — and
  # check the row is the thing we asked for, not merely an id that exists.
  if ! read_agents; then
    rec_put "$REC" state unknown || true
    notify "successor $SHORT was launched but \`claude agents --json\` is unreadable — cannot confirm it, check by hand"
    die "launched $SHORT but could not read \`claude agents --json\` to confirm it; recorded as state=unknown in $REC"
  fi
  UUID="$( exec 9>&- 8>&- 7>&-; lookup "$AGENTS_JSON" "$SHORT" sessionId )"   # CLAIM:b
  if [ -z "$UUID" ]; then
    rec_put "$REC" state unknown || true
    notify "successor $SHORT is not listed by \`claude agents --json\` — it may still be running, check by hand"
    die "session $SHORT is not listed by \`claude agents --json\`; recorded as state=unknown in $REC so a retry cannot duplicate it (--force to override)"
  fi
  ROW_KIND="$( exec 9>&- 8>&- 7>&-; lookup "$AGENTS_JSON" "$SHORT" kind )"   # CLAIM:b
  ROW_CWD="$( exec 9>&- 8>&- 7>&-; lookup "$AGENTS_JSON" "$SHORT" cwd )"   # CLAIM:b
  if [ "$ROW_KIND" != "background" ]; then
    rec_put "$REC" state unknown || true
    die "session $SHORT is listed as kind='$ROW_KIND', not 'background'; recorded as state=unknown in $REC"
  fi
  # An EMPTY answer is not "the directory matches". `lookup` returns "" both for
  # a key that is absent and for one whose value could not be read, and this is
  # the site that decides whether the successor is reading the right repository:
  # the old `[ -n "$ROW_CWD" ] && …` skipped the comparison on an empty value and
  # went on to record `verified` (round-5 correctness #8). The kind check
  # immediately above already dies on an empty value; a degraded observation may
  # not become a value here either.
  if [ -z "$ROW_CWD" ]; then
    rec_put "$REC" state unknown || true
    die "session $SHORT is listed without a readable working directory, so it cannot be confirmed to be running in '$CWD_ABS' rather than somewhere it would read the wrong repository; recorded as state=unknown in $REC (--force to dispatch anyway)"
  fi
  # Resolved the same way as CWD_ABS, so a spelling difference is not read as a
  # different directory. If it cannot be resolved (gone, or unreachable), the
  # string as reported is compared — a mismatch then is still worth refusing on.
  fs_get "$FS_TIMEOUT_SEC" _dir_phys "$ROW_CWD" || FS_VAL=""
  ROW_CWD_P="$FS_VAL"
  [ -n "$ROW_CWD_P" ] || ROW_CWD_P="$ROW_CWD"
  if [ "$ROW_CWD_P" != "$CWD_ABS" ]; then
    rec_put "$REC" state unknown || true
    die "session $SHORT is running in '$ROW_CWD', not the requested '$CWD_ABS' — it would read the wrong repository; recorded as state=unknown in $REC"
  fi

  verify_lock
  rec_put "$REC" session_uuid "$UUID" || die "verified $SHORT but could not commit the record $REC"
  rec_put "$REC" state verified || die "verified $SHORT but could not commit the record $REC"
  logline "{\"hook_event_name\":\"HandoffDispatch\",\"session\":\"$SHORT\",\"handoff\":\"$FILE_ABS\"}"

  WATCHED="no (--no-watch)"
  if [ "$NOWATCH" = 0 ] && [ "$ARM" = 1 ]; then
    # arm_watch proves the watcher started by reading the lease IT wrote, not by
    # its own fork returning.
    # The substitution closes the descriptors FIRST. Without that, the subshell
    # that runs arm_watch inherits fd 9 — a spawn site nothing enumerated —
    # and the dispatch lock outlives this process for as long as that subshell
    # lives (round-4 correctness C2 / the L2 class).
    GEN="$( exec 9>&- 8>&- 7>&-; arm_watch "$REC" )"   # CLAIM:b
    if [ -n "$GEN" ]; then
      rec_read "$REC" "watch_pid_$GEN" || REC_VAL=""
      WATCHED="generation $GEN (holding its lease; pid ${REC_VAL:-unrecorded} is diagnostic)"
    else
      rec_put "$REC" watch_failed 1 || true
      WATCHED="FAILED TO ARM"
      alert_once "$REC" armfailed "successor $SHORT is dispatched but UNWATCHED — the watchdog did not start"
    fi
  elif [ "$NOWATCH" = 0 ]; then
    WATCHED="no (disarmed by CLAUDE_HANDOFF_ARM=0)"
  fi

  # Armed BEFORE the report, exactly as the watchdog is, and for the same reason:
  # the report is a claim about what happened, so everything it claims must
  # already have happened. retire_self only ARMS -- the irreversible stop runs in
  # the detached child, well after this process has printed and exited.
  retire_self "$SHORT" "$REC" "$LANE" || true

  # Nothing to release: process exit closes fd 9 and the kernel drops the lock.
  shq "$SHORT"
  printf 'handoff: dispatched %s (%s)\n  handoff : %s\n  record  : %s\n  watchdog: %s\n  retired : %s\n  attach  : claude attach %s\n' \
    "$SHORT" "$UUID" "$FILE_ABS" "$REC" "$WATCHED" "$RETIRED" "$SHQ"
    # CLAIM-REGION-END dispatch
}

# ---------------------------------------------------------------------- main
[ $# -gt 0 ] || die "usage: handoff.sh <handoff-file> <objective> [options] | --status | --watch <record> | --close <lane> <completed|cancelled|superseded> [note]"

MODE_TAKEN=""
case "$1" in
  --status) MODE_TAKEN="--status"; status; exit 0 ;;
  --watch|--watch-once)
    MODE_TAKEN="$1"; MODE="$1"; REC="${2:-}"; shift $(( $# > 1 ? 2 : 1 ))
    [ -n "$REC" ] || die "$MODE needs a record path"
    # Two spellings of one record are two leases, two alert namespaces and two
    # watchers of which neither stands down, so the same alert is delivered
    # twice (round-5 lifecycle #4). Dispatch resolves the record for exactly
    # this reason; a watcher started by hand through an alias must land on the
    # same object, so it uses the same authority.
    resolve_path "$REC" "record"
    REC="$RESOLVED"
    while [ $# -gt 0 ]; do
      case "$1" in
        --heartbeat-min|--stall-min) need_val "$1" $# "${2:-}"; need_num "$1" "$2"; HEARTBEAT_MIN="$2"; shift 2 ;;
        --poll-sec) need_val "$1" $# "${2:-}"; need_num "$1" "$2"; POLL_SEC="$2"; shift 2 ;;
        # A generation is minted as <epoch>.<pid>.<random>, and it becomes part
        # of record KEYS (watch_pid_<gen>, finished_<gen>) and of the lease
        # PATHNAME. rec_put validates values but not keys, so an unconstrained
        # generation off the command line could forge a record line or a lease
        # path; constrain it here, where it enters.
        --watch-gen)
          need_val "$1" $# "${2:-}"
          case "$2" in
            ''|*[!0-9A-Za-z._-]*) die "--watch-gen must be one token of [0-9A-Za-z._-] (got: $2) — it becomes a record key and a lease pathname" ;;
          esac
          WATCH_GEN="$2"; shift 2 ;;
        *) die "unknown option: $1" ;;
      esac
    done
    fin_key_set
    # Startup validation, which is NOT the same as the poll-time check inside
    # watch_once: there is nothing to watch if the record never named a session,
    # and refusing here is what keeps that a hard error while a session id that
    # disappears mid-flight stays recoverable.
    [ -r "$REC" ] || die "record not readable: $REC"
    rec_read "$REC" session_id || die "cannot read the record $REC ($FS_WHY_TXT)"
    [ -n "$REC_VAL" ] || die "record has no session_id: $REC"
    [ "$MODE" = "--watch" ] && { watch_loop "$REC"; exit 0; }
    watch_once "$REC"; exit $?
    ;;
  # The END of the header block is DERIVED, never retyped: the literal `2,26p`
  # that used to be here stopped mid-sentence ("...looks exactly like") and
  # dropped the whole final bullet, because the block grew and the number did
  # not. `set -u` is the first line that is not part of the block, so the last
  # comment line before it is the last line of the contract (case DH).
  -h|--help)
    _hend="$(awk '/^set -u$/{print NR-1; exit}' "$0")"
    sed -n "2,${_hend}p" "$0"; exit 0 ;;
  --retire-exec)
    MODE_TAKEN="--retire-exec"; shift
    retire_exec "$@"; exit 0 ;;
  --close)
    MODE_TAKEN="--close"; shift
    close_lane "$@"; exit 0 ;;
  --*) die "unknown option: $1" ;;
esac

# A mode branch must EXIT. If one returns here it failed part-way — a `die` inside
# a command substitution kills only that subshell, and an arithmetic error does
# the same — and the mode branches have already shifted their arguments away, so
# the fall-through used to reach `dispatch` and abort with `$1: unbound variable`,
# reporting a shell error instead of the actual failure. Worse, with arguments
# left over it would have DISPATCHED a successor nobody asked for.
[ -z "$MODE_TAKEN" ] || die "$MODE_TAKEN did not complete (it failed before it could exit; see $LOG) — refusing to fall through to a dispatch"
[ $# -gt 0 ] || die "usage: handoff.sh <handoff-file> <objective> [options]   (also --status, --watch <record>, --watch-once <record>, --close <lane> <disposition> [note], --help; --no-retire keeps this seat alive)"

dispatch "$@"
