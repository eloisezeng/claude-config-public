#!/usr/bin/env bash
# Tests for hooks/handoff.sh — plain bash, no bats dependency.
# No test spawns a real session: `claude` is a shim on PATH whose canned output
# and canned failures make every branch reachable — including blocked, missing
# transcript, an unreadable agent list, and two callers racing to dispatch.
set -u
SCRIPT="$(cd "$(dirname "$0")/.." && pwd)/hooks/handoff.sh"
fail=0

# ---- hang guards for the watch-loop cases ------------------------------------
# A guard is not a deadline. When one fires the case reports a CORRECTNESS verdict
# ("the loop never exited on the durable fact"), so a guard set near the case's
# real duration manufactures that verdict about code that was working. AI shipped
# with `sleep 20` over a ~13s duration and produced exactly that on its first
# full-suite run under concurrent load; measured standalone the same case takes
# 13s on this tree and 15s on the previous one, so the margin was 1.3-1.5x.
#
# Enumerated rather than fixed in place, because it is a class: this file has 9
# inline `sleep N; kill -9` guards.
#   6 of them (AY, BL, BL2, BM, BX, CA) arm the guard AFTER an `await_rec` on the
#     very fact that ends the loop, so the process is already on its way out and
#     the guard is a formality.
#   3 of them (AI, CB, CD) arm it immediately after launch, so the guard races the
#     real duration. All three are paced by the same thing -- the hook's alert
#     retry budget, ALERT_RETRY_MAX retries each costing one full poll plus the
#     `--poll-sec 1` sleep.
# Those three take the derived guard below, so raising ALERT_RETRY_MAX in the hook
# cannot quietly turn any of them back into a flake. It is read from the hook by
# value: a literal here would be the same stale-constant bug one level up.
WATCH_RETRY_MAX="$(sed -n 's/^ALERT_RETRY_MAX=\([0-9][0-9]*\)$/\1/p' "$SCRIPT" | head -1)"
[ -n "$WATCH_RETRY_MAX" ] || {
  echo "FAIL[setup]: cannot read ALERT_RETRY_MAX from $SCRIPT -- every watch-loop hang guard below would be a guess"
  fail=1; WATCH_RETRY_MAX=10
}
WATCH_HANG_GUARD=$(( WATCH_RETRY_MAX * 8 + 30 ))
assert_contains() { case "$2" in *"$1"*) ;; *) echo "FAIL[$3]: expected to contain: $1 -- got: $2"; fail=1;; esac; }
assert_missing()  { case "$2" in *"$1"*) echo "FAIL[$3]: expected NOT to contain: $1"; fail=1;; *) ;; esac; }
assert_eq()       { [ "$1" = "$2" ] || { echo "FAIL[$3]: expected '$2' got '$1'"; fail=1; }; }
assert_file()     { [ -f "$1" ] || { echo "FAIL[$2]: expected file to exist: $1"; fail=1; }; }
assert_no_file()  { [ ! -f "$1" ] || { echo "FAIL[$2]: expected file to be absent: $1"; fail=1; }; }
# Ownership here is a kernel lock on an open file description, so "is it held?"
# is a question about the KERNEL, not about the file -- the lock file itself is
# created on first use and never unlinked, and its content is a diagnostic line
# nobody reads for a decision. This probe is written INDEPENDENTLY of the
# product's own lock_hold: a probe that reuses the implementation under test
# cannot fail when that implementation is wrong. perl reaches the same flock(2)
# by a different path, opening the path fresh in a process of its own.
# 0 = held by someone else, 1 = free, 2 = could not even open it,
# 3 = THE PATH DOES NOT EXIST, which is not an answer about a lock at all.
#
# The `>>` this used to open with CREATED the path, so every "exists and is not
# held" assertion in the suite was two claims of which the probe silently
# supplied the first: `assert_not_held` on a path nothing had ever made passed,
# and would have passed against a product that never created a lock file at all
# (round-4 test finding T2 — the same class as round 3's M4, a control that
# cannot fail). It opens read-only now, which flock(2) is happy with, and a
# missing path is reported as its own state rather than manufactured.
lock_is_held() { # $1=path
  [ -e "$1" ] || return 3
  perl -MFcntl=:flock -e 'open(my $f, "<", $ARGV[0]) or exit 2; exit(flock($f, LOCK_EX|LOCK_NB) ? 1 : 0)' "$1"
}
assert_not_held() { # $1=path  $2=case
  lock_is_held "$1"; _lh=$?
  case "$_lh" in
    1) ;;
    0) echo "FAIL[$2]: the lock at $1 is still HELD"; fail=1 ;;
    3) echo "FAIL[$2]: $1 does not exist, so 'not held' asserts nothing -- the lock file is created on first use and never unlinked, so its absence is itself the bug"; fail=1 ;;
    *) echo "FAIL[$2]: could not open $1 to observe whether its lock is held"; fail=1 ;;
  esac
  return 0
}
assert_held() { # $1=path  $2=case
  lock_is_held "$1"; _lh=$?
  case "$_lh" in
    0) ;;
    1) echo "FAIL[$2]: expected the lock at $1 to be HELD, but it is free"; fail=1 ;;
    3) echo "FAIL[$2]: $1 does not exist, so it cannot be held by anyone"; fail=1 ;;
    *) echo "FAIL[$2]: could not open $1 to observe whether its lock is held"; fail=1 ;;
  esac
  return 0
}
# A live holder for the cases that need one. It reports readiness only AFTER
# flock has returned, so no case can race its own fixture.
# (This one CREATES the path on purpose: it is the fixture, not the probe.)
hold_lock() { # $1=path  $2=readiness file -> echoes the holder's pid
  : > "$2"
  perl -MFcntl=:flock -e '
    open(my $f, ">>", $ARGV[0]) or exit 2;
    flock($f, LOCK_EX) or exit 3;
    open(my $r, ">", $ARGV[1]) or exit 4; print $r "held\n"; close $r;
    sleep 300;
  ' "$1" "$2" >/dev/null 2>&1 &
  _hp=$!
  disown "$_hp" 2>/dev/null || true
  _hn=0
  while [ ! -s "$2" ] && [ "$_hn" -lt 100 ]; do sleep 0.1; _hn=$(( _hn + 1 )); done
  printf '%s' "$_hp"
}
# A record is key=value lines and `finished=1` is a SUBSTRING of
# `alerted_finished=1`, so a substring assertion cannot tell the durable fact
# from the "already told" marker — which is the exact distinction several of
# these cases exist to pin. These match whole lines.
assert_rec()         { grep -q "^$2\$" "$1" 2>/dev/null || { echo "FAIL[$3]: expected record line '$2' in $1 -- got: $(cat "$1" 2>/dev/null)"; fail=1; }; }
# LAST WRITE WINS in a record, so `grep "^alerted_x=1$"` stays true forever once
# the marker has ever been set -- it cannot tell "still alerted" from "alerted,
# then cleared". Every episode assertion below needs the CURRENT value, which is
# the last line for that key.
assert_rec_last() { # $1=record $2=key $3=expected value $4=case
  local got; got="$(sed -n "s/^$2=//p" "$1" 2>/dev/null | tail -1)"
  [ "$got" = "$3" ] || { echo "FAIL[$4]: expected the LAST '$2' in $1 to be '$3' -- got '${got:-<absent>}'"; fail=1; }
}
assert_rec_missing() { grep -q "^$2\$" "$1" 2>/dev/null && { echo "FAIL[$3]: expected NO record line matching '$2' in $1 -- got: $(cat "$1" 2>/dev/null)"; fail=1; }; return 0; }
# An armed watchdog is a separate process, so anything it writes has to be
# WAITED for. Bounded, and every case that uses it also asserts the artifact, so
# a timeout surfaces as the assertion failing rather than as a silent pass.
# Waiting on fact X is NOT evidence for fact Y. Two writes the hook makes back to
# back are still two writes, and under load the gap between them is arbitrarily
# wide: BL awaited `alert_undelivered_...` in the record and then read the event
# log, which the hook writes on the NEXT line, and failed once in ten runs with
# no mutation involved. Fence a read on the fact you are reading -- either wait
# for the writing process to EXIT, or await the very line you are about to
# assert (this helper takes any file, so `await_rec "$CLAUDE_HANDOFF_LOG" ...`
# is the idiom). Of the 15 event-log assertions in this suite, 11 are fenced by
# the writer's exit, 2 await the log line itself, and the remaining 2 -- BJ and
# BL -- were fenced on a neighbouring fact until this was written down.
await_rec() { # $1=record $2=grep pattern $3=max tenths of a second
  local n=0
  while [ "$n" -lt "$3" ]; do
    grep -q "$2" "$1" 2>/dev/null && return 0
    sleep 0.1; n=$(( n + 1 ))
  done
  return 1
}

# Last-write-wins records mean `grep -q "^k=1$"` stays true forever once set, so
# a marker that goes 1 -> 0 -> 1 is unwaitable with it: the second episode's
# assertion passes on the FIRST episode's line. Wait on the LAST value instead.
await_rec_last() { # $1=record $2=key $3=expected $4=max tenths
  local n=0 got
  while [ "$n" -lt "$4" ]; do
    got="$(sed -n "s/^$2=//p" "$1" 2>/dev/null | tail -1)"
    [ "$got" = "$3" ] && return 0
    sleep 0.1; n=$(( n + 1 ))
  done
  echo "FAIL[$5]: waited ${4}00ms for the last '$2' in $1 to be '$3' -- it is '${got:-<absent>}'"; fail=1
  return 1
}

# A watcher's argv spells the record PHYSICALLY (/private/var/...) while these
# tests spell it /var/..., so every `pkill -f "handoff.sh --watch $REC"` in this
# suite was a silent no-op: it left the incumbent alive, still holding its lease,
# reading as a healthy watcher to the next case -- and leaked a process polling
# for an hour after the suite exited. Kill by the pid the record names.
retire_watchers() { # $1=record
  local g p n
  for g in $(sed -n 's/^watch_pid_\([^=]*\)=.*/\1/p' "$1" 2>/dev/null | sort -u); do
    p="$(sed -n "s/^watch_pid_$g=//p" "$1" | tail -1)"
    [ -n "$p" ] && kill "$p" 2>/dev/null
    n=0
    # The lease is what the next case reads, and the kernel drops it when the
    # process actually dies -- which is after `kill` returns, not at it.
    while [ "$n" -lt 100 ]; do lock_is_held "$1.watch.$g"; [ "$?" = 0 ] || break; sleep 0.1; n=$(( n + 1 )); done
  done
  return 0
}

# A value-taking option that forgets need_val makes `shift 2` a silent no-op
# under `set -u`, so the option loop re-reads the same token FOREVER. A hang is
# not a pass, and it must not leak a CPU-spinning orphan either: kill the
# descendants before the subshell, or the spinner is reparented and runs on after
# the suite exits.
RB_CODE=0; RB_OUT=""; RB_HUNG=0
run_bounded() { # $1=seconds  rest=command... -> RB_CODE / RB_OUT / RB_HUNG
  local secs="$1"; shift
  RB_HUNG=0
  ( "$@" >"$tmp/rb.out" 2>&1; echo "$?" > "$tmp/rb.code" ) &
  local bp=$! n=0
  rm -f "$tmp/rb.code"
  while [ "$n" -lt $(( secs * 10 )) ] && kill -0 "$bp" 2>/dev/null; do sleep 0.1; n=$(( n + 1 )); done
  if kill -0 "$bp" 2>/dev/null; then
    pkill -9 -P "$bp" 2>/dev/null || true
    kill -9 "$bp" 2>/dev/null || true
    RB_HUNG=1; RB_CODE=137
  else
    RB_CODE="$(cat "$tmp/rb.code" 2>/dev/null || echo 1)"
  fi
  RB_OUT="$(cat "$tmp/rb.out" 2>/dev/null)"
  wait "$bp" 2>/dev/null || true
}

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin" "$tmp/projects/-slug" "$tmp/work"

UUID="11111111-2222-3333-4444-555555555555"
SHORT="11111111"

# ---- the shim -------------------------------------------------------------
# Behaviour is driven by files in $tmp so each case can re-point it.
cat > "$tmp/bin/claude" <<'SHIM'
#!/usr/bin/env bash
for a in "$@"; do
  if [ "$a" = "agents" ]; then
    [ -f "$SHIM_AGENTS_HANG" ] && sleep 30
    [ -f "$SHIM_AGENTS_FAIL" ] && exit 7
    # Seam for the fencing token: a third party takes the dispatch lock over
    # while the dispatcher is mid-flight (the agents read is the one point where
    # a dispatch is provably still pre-launch). The path to steal is read from a
    # file so only the case that asks for it is affected, and it is stolen once.
    if [ -f "$SHIM_STEAL" ]; then
      _lk="$(cat "$SHIM_STEAL")"; rm -f "$SHIM_STEAL"
      rm -f "$_lk"; printf '%s\tstolen\t1\n' "$$" > "$_lk"
    fi
    # The same seam for the OTHER thing a dispatch has already validated and is
    # about to rely on: the handoff file itself. The agents read is the last
    # point that is provably still pre-launch, so a file removed or replaced
    # here is removed or replaced strictly between validation and the spawn.
    # Each fires once, and only for the case that asks for it. Case BO.
    if [ -n "${SHIM_HO_REMOVE:-}" ] && [ -f "$SHIM_HO_REMOVE" ]; then
      _hp="$(cat "$SHIM_HO_REMOVE")"; rm -f "$SHIM_HO_REMOVE"; rm -f "$_hp"
    fi
    if [ -n "${SHIM_HO_REPLACE:-}" ] && [ -f "$SHIM_HO_REPLACE" ]; then
      _hp="$(cat "$SHIM_HO_REPLACE")"; rm -f "$SHIM_HO_REPLACE"
      rm -f "$_hp"; printf '# a DIFFERENT file, same path\n\nDo something else.\n' > "$_hp"
    fi
    # The third thing that can change under an already-validated path: its TYPE.
    # A HARD LINK is made first, so the symlink planted here points at the very
    # inode that was validated -- both identity reads then agree and only the
    # `-L` question can catch the swap. Case CG.
    if [ -n "${SHIM_HO_SYMLINK:-}" ] && [ -f "$SHIM_HO_SYMLINK" ]; then
      _hp="$(cat "$SHIM_HO_SYMLINK")"; rm -f "$SHIM_HO_SYMLINK"
      ln "$_hp" "$_hp.twin" && { rm -f "$_hp"; ln -s "$_hp.twin" "$_hp"; }
    fi
    # One-shot seam for the retirement's ACT-TIME re-verification. The successor
    # has to disappear strictly BETWEEN the dispatch's verification and the
    # retirement's re-read, and a case cannot hit that window by racing, because
    # BOTH reads come through this same shim. Keying the flip on the record
    # already saying `state=verified` places it exactly there: a dispatch reads
    # the agent list twice before that line is written (the pre-dispatch live
    # check and the verification itself), and the retirement's re-read is the
    # first read after it. The swap happens BEFORE the cat, so the read that
    # trips the condition is the read that sees the new list. Case RETIRE-9.
    if [ -n "${SHIM_AGENTS_AFTER:-}" ] && [ -f "$SHIM_AGENTS_AFTER" ] \
       && grep -q '^state=verified$' "${SHIM_AGENTS_AFTER_REC:-/nonexistent}" 2>/dev/null; then
      cp "$SHIM_AGENTS_AFTER" "$SHIM_AGENTS"; rm -f "$SHIM_AGENTS_AFTER"
    fi
    cat "$SHIM_AGENTS"; exit 0
  fi
done
printf '%s\n' "$@" >> "$SHIM_BG_ARGS"
# Which of the dispatcher's lock descriptors survived into the successor, asked
# from the CHILD's side -- the only side that can answer it. `:` writes nothing,
# so an inherited descriptor is observed without corrupting the lock file behind
# it. Case BE.
{ : >&7; } 2>/dev/null && echo 7 >> "$SHIM_FDS"
{ : >&8; } 2>/dev/null && echo 8 >> "$SHIM_FDS"
{ : >&9; } 2>/dev/null && echo 9 >> "$SHIM_FDS"
# The cwd the successor is ACTUALLY launched in. Asserting the agents row's cwd
# only proves the shim echoed what the test wrote; the `cd` in the spawn command
# is invisible unless the shim reports where it really ran.
pwd > "$SHIM_BG_CWD"
echo spawn >> "$SHIM_SPAWNS"
# Blocks INSIDE the dispatch's launch substitution until released, so a case can
# SIGKILL the dispatcher while that substitution's own subshell is still alive.
if [ -n "${SHIM_BG_BLOCK:-}" ] && [ -f "$SHIM_BG_BLOCK" ]; then
  printf 'blocked\n' > "$SHIM_BG_BLOCK.ready"
  _n=0
  while [ ! -f "$SHIM_BG_BLOCK.release" ] && [ "$_n" -lt 900 ]; do sleep 0.1; _n=$(( _n + 1 )); done
fi
[ -f "$SHIM_BG_SLOW" ] && sleep 2
cat "$SHIM_BG_OUT"
# `claude --bg` can background a session, print its id, and still exit nonzero
# afterwards on a client-side error -- so the exit status is not evidence about
# whether a successor exists. Case CI. Written AFTER the output, because the
# whole point is that the id was printed.
if [ -n "${SHIM_BG_RC:-}" ] && [ -f "$SHIM_BG_RC" ]; then exit "$(cat "$SHIM_BG_RC")"; fi
SHIM
chmod +x "$tmp/bin/claude"
export SHIM_AGENTS="$tmp/agents.json" SHIM_BG_ARGS="$tmp/bg-args.txt" SHIM_BG_OUT="$tmp/bg-out.txt"
export SHIM_AGENTS_FAIL="$tmp/agents-fail" SHIM_BG_SLOW="$tmp/bg-slow" SHIM_SPAWNS="$tmp/spawns.txt"
export SHIM_AGENTS_HANG="$tmp/agents-hang" SHIM_BG_CWD="$tmp/bg-cwd.txt"
export SHIM_STEAL="$tmp/steal-lock-path"
export SHIM_FDS="$tmp/inherited-fds.txt"
export SHIM_BG_BLOCK="$tmp/bg-block"
export SHIM_HO_REMOVE="$tmp/ho-remove" SHIM_HO_REPLACE="$tmp/ho-replace"
export SHIM_HO_SYMLINK="$tmp/ho-symlink" SHIM_BG_RC="$tmp/bg-rc"
printf 'backgrounded \xc2\xb7 %s\n  claude agents   list sessions\n' "$SHORT" > "$SHIM_BG_OUT"
# The row must match what dispatch asked for: kind=background AND the resolved cwd.
# $3 exists because a fixture that can only say kind="background" makes the
# dispatch's kind check unfalsifiable: deleting the check outright kept the suite
# green (round-3 test finding T5).
live_json() { printf '[{"id":"%s","cwd":"%s","kind":"%s","startedAt":1787000000000,"sessionId":"%s","state":"%s"}]\n' "$SHORT" "${2:-$tmp/work}" "${3:-background}" "$UUID" "$1" > "$SHIM_AGENTS"; }
live_json "running"

export CLAUDE_BIN="$tmp/bin/claude"
export CLAUDE_PROJECTS_DIR="$tmp/projects"
export CLAUDE_HANDOFF_LOG="$tmp/events.log"
export CLAUDE_HANDOFF_NOTIFY_DEBUG=1
# Arming a real poll loop per dispatch would leave stray background processes
# behind for hours; cases K and R cover arming and expiry explicitly.
export CLAUDE_HANDOFF_ARM=0

# ---- hermeticity: this suite runs INSIDE the thing it tests -------------------
# Every one of these is exported by a background seat, and this suite is run from
# inside one. Left inherited they do not merely add noise, they change verdicts:
#
#   CLAUDE_JOB_DIR / CLAUDE_CODE_SESSION_ID / CLAUDE_PID together are the whole
#     retirement binding. Inherited, they all point at the SESSION RUNNING THE
#     TESTS -- a live seat, a state.json the daemon owns, and a pid that really
#     is a `claude` ancestor of this script. Case A's ordinary dispatch would
#     then satisfy every one of the five checks and stop the suite mid-run, and
#     it would look like a hang rather than like a test killing its own host.
#     The retirement cases below set all three EXPLICITLY, at a sleeper of their
#     own making, which is also the only way `no test may kill a real session`
#     survives someone later running this file by hand.
#   CLAUDE_HANDOFF_MODEL changes the `--model` the dispatcher passes, which case
#     AB2 asserts is the default.
#   FORCE_COLOR / CLI_COLOR / COLORTERM make `node` colourise into a pipe, so
#     every number this suite derives arrives wrapped in ANSI and compares
#     unequal to itself -- the same poisoning class as
#     [[handoff-session-id-ansi-poisoning]], one level up.
unset CLAUDE_JOB_DIR CLAUDE_CODE_SESSION_ID CLAUDE_PID
unset CLAUDE_HANDOFF_MODEL FORCE_COLOR CLI_COLOR COLORTERM
export CLAUDE_HANDOFF_STATE_DIR="$tmp/session-state"

HO="$tmp/work/HANDOFF-thing.md"
printf '# Handoff\n\nDo the thing.\n' > "$HO"
REC="$HO.dispatch"
transcript="$tmp/projects/-slug/$UUID.jsonl"
: > "$transcript"
GO() { bash "$SCRIPT" "$HO" "$1" --cwd "$tmp/work" "${@:2}"; }
# Any case that ARMS a real watchdog needs its own handoff file: the watcher
# outlives the dispatch that started it, and one still polling the record a
# later case is asserting about is a flake, not a test.
GOF() { bash "$SCRIPT" "$1" "$2" --cwd "$tmp/work" "${@:3}"; }
NEWHO() { # $1=name -> a fresh handoff file with a record nobody else touches
  _h="$tmp/work/HANDOFF-$1.md"
  printf '# Handoff\n\nDo %s.\n' "$1" > "$_h"
  rm -f "$_h.dispatch" "$_h.dispatch".* 2>/dev/null
  printf '%s' "$_h"
}

# ---- A. dispatch happy path ----------------------------------------------
out="$(GO "finish the thing" 2>&1)"; code=$?
assert_eq "$code" "0" A
assert_contains "$SHORT" "$out" A
assert_file "$REC" A
# The exact KEY, not the value somewhere in the file: writing the uuid under any
# other key leaves the watcher unable to find the transcript, and a substring
# search for the value cannot tell the two apart (round-3 test finding T11).
assert_rec "$REC" "session_uuid=$UUID" A
assert_rec "$REC" "state=verified" A
# ...and dispatch itself must persist the epoch the transcript-age check reads.
# Case N used to supply this line by hand, so deleting the production write
# changed nothing (round-3 test finding T3).
assert_rec "$REC" "dispatched_epoch=[0-9][0-9]*" A
assert_contains "finish the thing" "$(cat "$SHIM_BG_ARGS")" A
assert_contains "--bg" "$(cat "$SHIM_BG_ARGS")" A
assert_contains "--append-system-prompt" "$(cat "$SHIM_BG_ARGS")" A
# the absolute handoff path must reach the successor, not a relative one
assert_contains "$HO" "$(cat "$SHIM_BG_ARGS")" A
# ...and it must be LAUNCHED in the requested cwd. This test runs from the repo
# directory, so a dropped `cd` shows up as the repo path rather than $tmp/work.
assert_eq "$(cd "$tmp/work" && pwd -P)" "$(cd "$(cat "$SHIM_BG_CWD")" && pwd -P)" A

# ---- B. dispatch not visible in `agents --json` fails, and is REMEMBERED --
# A launched-but-unconfirmed successor must never be forgotten: forgetting it is
# what lets the retry start a second one against the same handoff.
rm -f "$REC"; printf '[]\n' > "$SHIM_AGENTS"
out="$(GO "finish the thing" 2>&1)"; code=$?
[ "$code" != "0" ] || { echo "FAIL[B]: expected non-zero when the session is absent from agents --json"; fail=1; }
assert_contains "agents" "$out" B
assert_file "$REC" B
assert_contains "state=unknown" "$(cat "$REC")" B
# and a retry must refuse rather than duplicate
live_json "running"
out="$(GO "retry" 2>&1)"; code=$?
[ "$code" != "0" ] || { echo "FAIL[B]: a state=unknown record must block an unforced retry"; fail=1; }
assert_contains "may be running" "$out" B
out="$(GO "retry" --force 2>&1)"; code=$?
assert_eq "$code" "0" B

# ---- C. double dispatch refused, --force overrides -----------------------
out="$(GO "again" 2>&1)"; code=$?
[ "$code" != "0" ] || { echo "FAIL[C]: expected refusal while a live successor is on record"; fail=1; }
assert_contains "$SHORT" "$out" C
out="$(GO "again" --force 2>&1)"; code=$?
assert_eq "$code" "0" C

# a record whose session is no longer live must NOT block a new dispatch
printf '[]\n' > "$SHIM_AGENTS"
out="$(GO "again" --dry-run 2>&1)"; code=$?
assert_eq "$code" "0" C

# an UNREADABLE agent list must not be read as "no live successor"
live_json "running"; GO "seed" --force >/dev/null 2>&1
: > "$SHIM_AGENTS_FAIL"
out="$(GO "again" 2>&1)"; code=$?
[ "$code" != "0" ] || { echo "FAIL[C]: a failed agents query must not clear the way for a second dispatch"; fail=1; }
assert_contains "cannot be ruled out" "$out" C
rm -f "$SHIM_AGENTS_FAIL"

# ---- D. input validation --------------------------------------------------
out="$(bash "$SCRIPT" "$tmp/nope.md" "x" 2>&1)"; code=$?
[ "$code" != "0" ] || { echo "FAIL[D]: missing file must fail"; fail=1; }
assert_contains "not readable" "$out" D
: > "$tmp/work/EMPTY.md"
out="$(bash "$SCRIPT" "$tmp/work/EMPTY.md" "x" 2>&1)"; code=$?
[ "$code" != "0" ] || { echo "FAIL[D]: empty file must fail"; fail=1; }
assert_contains "empty" "$out" D
out="$(bash "$SCRIPT" "$HO" 2>&1)"; code=$?
[ "$code" != "0" ] || { echo "FAIL[D]: missing objective must fail"; fail=1; }
assert_contains "objective" "$out" D

# ---- E. --dry-run spawns nothing -----------------------------------------
rm -f "$SHIM_BG_ARGS" "$REC"
out="$(GO "dry" --dry-run 2>&1)"; code=$?
assert_eq "$code" "0" E
assert_contains "--bg" "$out" E
assert_no_file "$SHIM_BG_ARGS" E
assert_no_file "$REC" E

# ---- F. watch: blocked alerts exactly once -------------------------------
GO "watch me" >/dev/null 2>&1
live_json "blocked"
out="$(bash "$SCRIPT" --watch-once "$REC" 2>&1)"
assert_contains "NOTIFY" "$out" F
assert_contains "blocked" "$out" F
out="$(bash "$SCRIPT" --watch-once "$REC" 2>&1)"
assert_missing "NOTIFY" "$out" F

# ---- G. watch: the heartbeat alert fires at the CONFIGURED boundary -------
# Both artifacts count as a heartbeat, so both must be aged for the alert.
# The ages straddle --heartbeat-min 20 (19m quiet, then 21m quiet), so a
# hardcoded threshold in the script fails this case instead of passing it. The
# offsets are relative to now, not a fixture date, so nothing here expires.
age_artifacts() { # $1=minutes ago
  local t
  t="$(date -v-"$1"M '+%Y%m%d%H%M' 2>/dev/null || date -d "$1 minutes ago" '+%Y%m%d%H%M')"
  touch -t "$t" "$transcript" "$HO"
}
rm -f "$REC"; live_json "running"; GO "watch me" >/dev/null 2>&1
: > "$transcript"
out="$(bash "$SCRIPT" --watch-once "$REC" --heartbeat-min 20 2>&1)"
assert_missing "NOTIFY" "$out" G
age_artifacts 19            # inside the configured window: silence
out="$(bash "$SCRIPT" --watch-once "$REC" --heartbeat-min 20 2>&1)"
assert_missing "NOTIFY" "$out" G
age_artifacts 21            # past it: alert, exactly once
out="$(bash "$SCRIPT" --watch-once "$REC" --heartbeat-min 20 2>&1)"
assert_contains "NOTIFY" "$out" G
assert_contains "no heartbeat" "$out" G
out="$(bash "$SCRIPT" --watch-once "$REC" --heartbeat-min 20 2>&1)"
assert_missing "NOTIFY" "$out" G
touch "$HO" "$transcript"

# ---- H. watch: finished alerts once and exits 0 --------------------------
rm -f "$REC"; live_json "running"; GO "watch me" >/dev/null 2>&1
: > "$transcript"
live_json "done"
out="$(bash "$SCRIPT" --watch-once "$REC" 2>&1)"; code=$?
assert_eq "$code" "0" H
assert_contains "NOTIFY" "$out" H
assert_contains "finish" "$out" H

# ---- I. an UNOBSERVED state must not read as healthy or as finished ------
# The state enum is not closed; a state we have never seen must be reported,
# never treated as "fine" and never as completion (fail open, loudly).
rm -f "$REC"; live_json "running"; GO "watch me" >/dev/null 2>&1
: > "$transcript"
live_json "wedged-somehow"
out="$(bash "$SCRIPT" --watch-once "$REC" 2>&1)"
assert_contains "wedged-somehow" "$out" I
assert_contains "unknown state" "$out" I
assert_missing "alerted_finished" "$(cat "$REC")" I

# ---- J. --status flags blocked sessions ----------------------------------
live_json "blocked"
out="$(bash "$SCRIPT" --status 2>&1)"; code=$?
assert_eq "$code" "0" J
assert_contains "$SHORT" "$out" J
assert_contains "blocked" "$out" J

# ---- K. arming is proven by the watcher's OWN lease, not by the fork ------
# Reporting "watched" because `&` returned is the status-flag mistake: the fork
# succeeding says nothing about a watcher existing. The record names a watcher
# GENERATION and the pid recorded FOR that generation, and the proof of arming
# is the lease the watcher itself wrote.
KHO="$(NEWHO armed)"; KREC="$KHO.dispatch"
live_json "done"
out="$(CLAUDE_HANDOFF_ARM=1 GOF "$KHO" "armed" 2>&1)"; code=$?
assert_eq "$code" "0" K
kgen="$(sed -n 's/^watch_gen=//p' "$KREC" | tail -1)"
[ -n "$kgen" ] || { echo "FAIL[K]: no watcher generation was recorded"; fail=1; }
assert_contains "watch_pid_$kgen=" "$(cat "$KREC")" K
assert_contains "watchdog: generation $kgen" "$out" K
assert_file "$KREC.watch.$kgen" K
# ...and it must be a WORKING watcher: this session is already done, so a real
# poll reaches the durable `finished` fact and the watcher exits on its own.
# ...and it is the GENERATION's fact, not a bare `finished`: a stale watcher
# writing the bare key into a re-dispatched record made the new watcher exit on
# its first poll (round-4 lifecycle L5).
await_rec "$KREC" "^finished_$kgen=1\$" 100
assert_rec "$KREC" "finished_$kgen=1" K
assert_rec_missing "$KREC" "finished=1" K
kill "$(sed -n "s/^watch_pid_$kgen=//p" "$KREC" | tail -1)" 2>/dev/null || true
live_json "running"

# ---- L. a FAILED agents query is degraded monitoring, never completion ---
rm -f "$REC"; GO "watch me" >/dev/null 2>&1
: > "$transcript"
: > "$SHIM_AGENTS_FAIL"
out="$(bash "$SCRIPT" --watch-once "$REC" 2>&1)"; code=$?
assert_eq "$code" "3" L
assert_contains "DEGRADED" "$out" L
assert_missing "finished" "$out" L
assert_missing "alerted_finished" "$(cat "$REC")" L
out="$(bash "$SCRIPT" --watch-once "$REC" 2>&1)"
assert_missing "NOTIFY" "$out" L
rm -f "$SHIM_AGENTS_FAIL"

# ---- M. MALFORMED agents JSON is degraded too, not "gone" ----------------
rm -f "$REC"; live_json "running"; GO "watch me" >/dev/null 2>&1
: > "$transcript"
printf '{"not":"an array"' > "$SHIM_AGENTS"
out="$(bash "$SCRIPT" --watch-once "$REC" 2>&1)"; code=$?
assert_eq "$code" "3" M
assert_contains "DEGRADED" "$out" M
assert_missing "alerted_finished" "$(cat "$REC")" M
live_json "running"

# ---- N. a transcript that never appears is reported on its own -----------
# The handoff file's own mtime is fresh, so this must not be masked by it.
rm -f "$REC"; GO "watch me" >/dev/null 2>&1
rm -f "$transcript"
out="$(bash "$SCRIPT" --watch-once "$REC" 2>&1)"
assert_missing "NOTIFY" "$out" N   # inside the startup grace window
# Age the value dispatch WROTE (rewrite in place). Appending a fresh
# `dispatched_epoch=1` manufactured the very state under test, so the alert fired
# even with the production write deleted.
grep -q '^dispatched_epoch=[0-9][0-9]*$' "$REC" || { echo "FAIL[N]: dispatch did not persist a dispatched_epoch to age"; fail=1; }
awk '/^dispatched_epoch=/{print "dispatched_epoch=1"; next} {print}' "$REC" > "$REC.aged" && mv "$REC.aged" "$REC"
out="$(bash "$SCRIPT" --watch-once "$REC" 2>&1)"
assert_contains "no transcript" "$out" N
assert_contains "DEGRADED" "$out" N
: > "$transcript"

# ---- O. two callers racing must produce exactly ONE successor ------------
rm -f "$REC" "$SHIM_SPAWNS"; : > "$SHIM_BG_SLOW"
GO "race" >/dev/null 2>&1 &
p1=$!
GO "race" >/dev/null 2>&1 &
p2=$!
wait $p1; wait $p2
rm -f "$SHIM_BG_SLOW"
spawns="$(wc -l < "$SHIM_SPAWNS" | tr -d ' ')"
assert_eq "$spawns" "1" O
# The lock FILE stays: it is created on first use and never unlinked, because a
# lock identified by a pathname is two locks the moment someone recreates it.
# What must be true after both callers have exited is that nobody HOLDS it.
assert_not_held "$REC.flock" O

# ---- P. a mismatched cwd fails the dispatch ------------------------------
rm -f "$REC"; live_json "running" "$tmp/somewhere-else"
out="$(GO "wrong dir" 2>&1)"; code=$?
[ "$code" != "0" ] || { echo "FAIL[P]: a successor running in the wrong cwd must fail the dispatch"; fail=1; }
assert_contains "somewhere-else" "$out" P
# Whole line, and the LAST state wins: a substring search over the whole record
# accepted `notstate=unknown` while the effective state stayed `pending`, which
# is what lets a later unforced dispatch proceed (round-3 test finding T10).
assert_rec "$REC" "state=unknown" P
assert_eq "$(sed -n 's/^state=//p' "$REC" | tail -1)" "unknown" P
live_json "running"

# ---- P2. a row of the wrong KIND is not the successor we launched ---------
# An interactive row that happens to carry the id must not verify the dispatch:
# the background session may still be starting, and accepting the wrong row
# records `verified` for a successor nobody is watching.
rm -f "$REC" "$SHIM_SPAWNS"; live_json "running" "$tmp/work" "interactive"
out="$(GO "wrong kind" 2>&1)"; code=$?
[ "$code" != "0" ] || { echo "FAIL[P2]: a row of kind=interactive must not verify the dispatch"; fail=1; }
assert_contains "interactive" "$out" P2
assert_rec "$REC" "state=unknown" P2
assert_eq "$(sed -n 's/^state=//p' "$REC" | tail -1)" "unknown" P2
assert_rec_missing "$REC" "state=verified" P2
assert_not_held "$REC.flock" P2
live_json "running"

# ---- Q. a lock FILE left by a dead process is not a lock ----------------
# Every earlier design had to reap a corpse: a `mkdir` directory, or a claim file
# naming a pid, left behind by a process that was SIGKILLed or died on a panic.
# Deciding whether such a corpse was dead needed an age or a pid, and neither is
# correct -- that is what two rewrites were spent on. Here the file left behind
# carries no ownership at all: the lock lived on the dead process's open file
# description and the kernel released it when that process's last descriptor
# closed. So a leftover file with arbitrary content is simply a file, and the
# next dispatch takes the lock with no grace period and no reaping step.
rm -f "$REC"; rm -rf "$REC.lock" "$REC.flock"
printf '999999\tdeadtoken\t1\n' > "$REC.flock"
out="$(GO "after a crash" 2>&1)"; code=$?
assert_eq "$code" "0" Q
assert_contains "state=verified" "$(cat "$REC")" Q
assert_not_held "$REC.flock" Q

# ---- R. watchdog expiry is action-required, not a quiet exit -------------
rm -f "$REC"; live_json "running"; GO "expire me" >/dev/null 2>&1
: > "$transcript"
out="$(CLAUDE_HANDOFF_MAX_HOURS=0 bash "$SCRIPT" --watch "$REC" 2>&1)"; code=$?
assert_eq "$code" "0" R
assert_contains "EXPIRED" "$out" R
assert_contains "monitoring_expired=" "$(cat "$REC")" R


# ---- S. a LIVE lock holder is never overrun, at any age -----------------
# Age-stealing a live holder is how two dispatches both spawn: the loser of the
# mkdir waited out an arbitrary timeout and then deleted a lock whose holder was
# still working. There is no timeout to wait out now -- but the fixture has to
# be a REAL holder to prove it, because the lock file's content is no longer a
# claim and seeding text into it would test nothing at all.
rm -f "$REC" "$SHIM_SPAWNS"; rm -rf "$REC.lock" "$REC.flock"
printf 'diagnostic-only, not a claim\n' > "$REC.flock"
holder="$(hold_lock "$REC.flock" "$tmp/s.ready")"
assert_held "$REC.flock" S                 # the fixture really holds it
touch -t 200001010000 "$REC.flock"         # ancient, and irrelevant: age is not ownership
out="$(GO "should refuse" 2>&1)"; code=$?
kill "$holder" 2>/dev/null || true
[ "$code" != "0" ] || { echo "FAIL[S]: a lock held by a LIVE holder must never be broken"; fail=1; }
assert_contains "still running" "$out" S
assert_no_file "$SHIM_SPAWNS" S
# The refusal quotes the file's first line so an operator has somewhere to look,
# and the loser must not WRITE to it -- the "last acquired by" line is written
# only on a successful take, so finding it here would mean a failed take had
# still stamped the file.
assert_contains "diagnostic-only, not a claim" "$out" S
assert_eq "$(head -1 "$REC.flock")" "diagnostic-only, not a claim" S
rm -f "$REC.flock"

# ---- T. an option token can never become the objective -------------------
# `handoff.sh HANDOFF --dry-run` used to assign "--dry-run" to the objective,
# leave DRY=0, and perform a REAL dispatch.
rm -f "$REC" "$SHIM_SPAWNS" "$SHIM_BG_ARGS"
out="$(bash "$SCRIPT" "$HO" --dry-run 2>&1)"; code=$?
[ "$code" != "0" ] || { echo "FAIL[T]: an option in the objective position must be refused"; fail=1; }
assert_contains "objective is missing" "$out" T
assert_no_file "$SHIM_SPAWNS" T
assert_no_file "$REC" T
# -- is the documented escape for an objective that must start with a dash
out="$(bash "$SCRIPT" "$HO" -- "--not-an-option" --cwd "$tmp/work" --dry-run 2>&1)"; code=$?
assert_eq "$code" "0" T
assert_contains -- "--not-an-option" "$out" T

# ---- U. a value-taking option with no value errors, it does not spin -----
# `shift 2` with one argument left fails silently under `set -u`, so the loop
# re-read the same token forever. A hang is indistinguishable from a slow agent.
run_bounded 10 bash "$SCRIPT" "$HO" "obj" --cwd
[ "$RB_HUNG" = 0 ] || { echo "FAIL[U]: --cwd with no value hangs instead of erroring"; fail=1; }
assert_contains "needs a value" "$RB_OUT" U

# ---- U2. EVERY value-taking option refuses a missing value AND a flag -----
# Case U covered --cwd only, so removing need_val from a single arm kept the
# suite green — and `--model --dry-run` then swallows the safety flag and
# performs a REAL dispatch, which is the exact class-A failure (finding T9).
rm -f "$REC" "$SHIM_SPAWNS"
for opt in --cwd --model --permission-mode --heartbeat-min --stall-min --poll-sec; do
  run_bounded 10 bash "$SCRIPT" "$HO" "obj" "$opt"
  [ "$RB_HUNG" = 0 ] || { echo "FAIL[U2]: $opt with no value HANGS (the option loop re-reads the token)"; fail=1; }
  [ "$RB_CODE" != "0" ] || { echo "FAIL[U2]: $opt with no value must fail"; fail=1; }
  assert_contains "needs a value" "$RB_OUT" "U2 $opt"
  run_bounded 10 bash "$SCRIPT" "$HO" "obj" "$opt" --dry-run
  [ "$RB_HUNG" = 0 ] || { echo "FAIL[U2]: '$opt --dry-run' HANGS"; fail=1; }
  [ "$RB_CODE" != "0" ] || { echo "FAIL[U2]: '$opt --dry-run' must fail rather than consume the flag as a value"; fail=1; }
  assert_contains "looks like an option" "$RB_OUT" "U2 $opt"
done
# ...and the same for the watch entry's own value-taking options.
printf 'session_id=%s\nstate=verified\n' "$SHORT" > "$tmp/u2.dispatch"
for opt in --heartbeat-min --stall-min --poll-sec --watch-gen; do
  run_bounded 10 bash "$SCRIPT" --watch-once "$tmp/u2.dispatch" "$opt"
  [ "$RB_HUNG" = 0 ] || { echo "FAIL[U2]: watch $opt with no value HANGS"; fail=1; }
  [ "$RB_CODE" != "0" ] || { echo "FAIL[U2]: watch $opt with no value must fail"; fail=1; }
  assert_contains "needs a value" "$RB_OUT" "U2 watch $opt"
done
assert_no_file "$SHIM_SPAWNS" U2
assert_no_file "$REC" U2

# ---- V. a newline in the objective cannot forge a record field -----------
# The record is key=value with last-write-wins, so an objective of
# $'finish\nsession_id=bogus' made the duplicate-dispatch check read a session
# id that does not exist and start a SECOND successor against a live one.
rm -f "$REC" "$SHIM_SPAWNS"
out="$(GO "$(printf 'finish\nsession_id=bogus')" 2>&1)"; code=$?
[ "$code" != "0" ] || { echo "FAIL[V]: a multi-line objective must be refused"; fail=1; }
assert_contains "single line" "$out" V
assert_no_file "$SHIM_SPAWNS" V

# ---- W. a record that could not be written aborts BEFORE any spawn -------
# A launched successor whose record did not persist is a successor nobody
# remembers, and the next caller reads the absence as permission to start one.
rm -f "$REC" "$SHIM_SPAWNS"; live_json "running"
: > "$REC"; chmod 444 "$REC"
out="$(GO "unwritable" --force 2>&1)"; code=$?
chmod 644 "$REC"
[ "$code" != "0" ] || { echo "FAIL[W]: an unwritable record must abort the dispatch"; fail=1; }
assert_contains "cannot write the dispatch record" "$out" W
assert_no_file "$SHIM_SPAWNS" W

# ---- X. a record left at state=launching blocks an unforced retry --------
# This is the kill-window shape: `claude --bg` started a successor and the
# process died before the id could be parsed. There is no session id to check,
# and that absence is NOT permission to start another one.
rm -f "$REC" "$SHIM_SPAWNS"
printf 'state=launching\nhandoff=%s\n' "$HO" > "$REC"
out="$(GO "retry after a kill" 2>&1)"; code=$?
[ "$code" != "0" ] || { echo "FAIL[X]: state=launching must block an unforced retry"; fail=1; }
assert_contains "may be running" "$out" X
assert_contains "launching" "$out" X
assert_no_file "$SHIM_SPAWNS" X
out="$(GO "retry after a kill" --force 2>&1)"; code=$?
assert_eq "$code" "0" X

# ---- Y. a live successor with a dead watchdog gets monitoring re-armed ---
# A verified record plus a dead watcher is the exact failure this script exists
# to prevent. Refusing the duplicate is not enough — nobody is watching.
YHO="$(NEWHO unwatched)"; YREC="$YHO.dispatch"
live_json "running"; GOF "$YHO" "watched" >/dev/null 2>&1
: > "$transcript"
printf 'watch_gen=g-dead\nwatch_pid_g-dead=999999\n' >> "$YREC"
out="$(CLAUDE_HANDOFF_ARM=1 GOF "$YHO" "again" 2>&1)"; code=$?
[ "$code" != "0" ] || { echo "FAIL[Y]: a live successor on record must still refuse a duplicate"; fail=1; }
assert_contains "re-armed the watchdog" "$out" Y
assert_contains "watch_reattached=" "$(cat "$YREC")" Y
ygen="$(sed -n 's/^watch_gen=//p' "$YREC" | tail -1)"
[ "$ygen" != "g-dead" ] || { echo "FAIL[Y]: the dead watcher generation was not replaced"; fail=1; }
assert_file "$YREC.watch.$ygen" Y
ypid="$(sed -n "s/^watch_pid_$ygen=//p" "$YREC" | tail -1)"
kill -0 "$ypid" 2>/dev/null || { echo "FAIL[Y]: the re-armed watcher is not running"; fail=1; }
kill "$ypid" 2>/dev/null || true

# ---- Z. a HANGING agents query is degraded monitoring, not a frozen loop -
# read_agents is the watchdog's only sense organ; an unbounded wait looks
# exactly like health and never reaches the degraded branch.
rm -f "$REC"; live_json "running"; GO "watch me" >/dev/null 2>&1
: > "$transcript"; : > "$SHIM_AGENTS_HANG"
start="$(date +%s)"
out="$(CLAUDE_HANDOFF_AGENTS_TIMEOUT=2 bash "$SCRIPT" --watch-once "$REC" 2>&1)"; code=$?
elapsed=$(( $(date +%s) - start ))
rm -f "$SHIM_AGENTS_HANG"
assert_eq "$code" "3" Z
assert_contains "DEGRADED" "$out" Z
[ "$elapsed" -lt 20 ] || { echo "FAIL[Z]: the agents query was not bounded (took ${elapsed}s)"; fail=1; }

# ---- AA. an alert that was NOT delivered is retried, not suppressed ------
# The marker used to be written before the notification, so a failed delivery
# (a headless box with no GUI session) durably silenced the alert forever.
rm -f "$REC"; live_json "running"; GO "watch me" >/dev/null 2>&1
: > "$transcript"; live_json "blocked"
out="$(CLAUDE_HANDOFF_NOTIFY_DEBUG=fail bash "$SCRIPT" --watch-once "$REC" 2>&1)"
assert_contains "blocked" "$out" AA
assert_missing "alerted_blocked" "$(cat "$REC")" AA
out="$(bash "$SCRIPT" --watch-once "$REC" 2>&1)"
assert_contains "NOTIFY" "$out" AA           # retried on the next poll
assert_contains "alerted_blocked" "$(cat "$REC")" AA
out="$(bash "$SCRIPT" --watch-once "$REC" 2>&1)"
assert_missing "NOTIFY" "$out" AA            # and only once it landed
live_json "running"

# ---- AB. requested model and permission mode reach `claude --bg` ---------
rm -f "$REC" "$SHIM_BG_ARGS"; live_json "running"
GO "routed" --force --model claude-opus-5 --permission-mode acceptEdits >/dev/null 2>&1
args="$(cat "$SHIM_BG_ARGS")"
assert_contains "$(printf -- '--model\nclaude-opus-5')" "$args" AB
assert_contains "$(printf -- '--permission-mode\nacceptEdits')" "$args" AB

# ---- AB2. with NO --model, the dispatch defaults to Fable ----------------
# your standing word: a continued session runs on Fable unless its limit is
# spent. The default lives in the launcher so it holds for every caller, not
# only the ones who remember it.
rm -f "$REC" "$SHIM_BG_ARGS"; live_json "running"
GO "defaulted" --force >/dev/null 2>&1
args="$(cat "$SHIM_BG_ARGS")"
assert_contains "$(printf -- '--model\nclaude-fable-5[1m]')" "$args" AB2

# ---- AB3. CLAUDE_HANDOFF_MODEL="" opts back out to claude's own default --
# The empty string is a real choice ("inherit"), which is why the default uses
# ${VAR-default} and not ${VAR:-default}.
rm -f "$REC" "$SHIM_BG_ARGS"; live_json "running"
CLAUDE_HANDOFF_MODEL="" bash "$SCRIPT" "$HO" "inherited" --cwd "$tmp/work" --force >/dev/null 2>&1
args="$(cat "$SHIM_BG_ARGS")"
assert_missing "--model" "$args" AB3

# ---- AB4. an explicit --model still wins over the default ----------------
rm -f "$REC" "$SHIM_BG_ARGS"; live_json "running"
GO "override" --force --model 'opus[1m]' >/dev/null 2>&1
args="$(cat "$SHIM_BG_ARGS")"
assert_contains "$(printf -- '--model\nopus[1m]')" "$args" AB4
assert_missing "claude-fable-5" "$args" AB4


# ---- AC. a DIRECTORY left by the mkdir-based predecessor is REFUSED -----
# Two predecessors put a DIRECTORY at this path, and both later designs broke on
# it in their own way: `ln <src> <DIR>` does not fail EEXIST (it links INSIDE the
# directory and succeeds, so a foreign path read as a claim we had won), and
# `exec 9>>` on a directory simply fails, which would make every dispatch on an
# upgraded machine die "could not open the dispatch lock" forever.
# This used to SWEEP the directory, and that was a claim this layer cannot make:
# the mkdir design has a pid-LESS window, so a live pre-upgrade launcher and the
# corpse of a dead one look exactly alike from here. Removing it while somebody
# holds it starts a second successor for the same handoff and pays for the
# handoff twice (round-5 lifecycle #2). So the dispatch refuses, logs what it
# saw, removes NOTHING, and names the command the operator runs once they have
# checked -- a decision only a human has the evidence to make.
rm -f "$REC" "$SHIM_SPAWNS"; rm -rf "$REC.lock" "$REC.flock"; : > "$CLAUDE_HANDOFF_LOG"
mkdir -p "$REC.lock"; printf '999999\n' > "$REC.lock/pid"
out="$(GO "after an upgrade" 2>&1)"; code=$?
[ "$code" != "0" ] || { echo "FAIL[AC]: a claim in the previous design's shape must refuse the dispatch"; fail=1; }
assert_contains "previous design's shape" "$out" AC
acrecp="$( cd "$(dirname "$REC")" && pwd -P )/$( basename "$REC" )"
assert_contains "rm -rf -- '$acrecp.lock'" "$out" AC   # the operator's own command, spelled out and pasteable (case DA)
assert_no_file "$SHIM_SPAWNS" AC                     # nothing was launched
assert_no_file "$REC" AC                             # ...and nothing was recorded
[ -d "$REC.lock" ] || { echo "FAIL[AC]: the legacy claim was removed by a dispatch that cannot know whether anyone holds it"; fail=1; }
assert_contains "HandoffLegacyLockPresent" "$(cat "$CLAUDE_HANDOFF_LOG")" AC
assert_missing "HandoffLegacyLockRemoved" "$(cat "$CLAUDE_HANDOFF_LOG")" AC
# ANCHOR: the refusal is the ONLY obstacle. Cleared by hand -- which is exactly
# what the message asks for -- the same dispatch runs to a verified successor,
# so this case pins a refusal and not a broken upgrade path. It also leaves the
# shared fixture clean: a directory left here would refuse every later case.
rm -rf "$REC.lock"
out="$(GO "after an upgrade" 2>&1)"; code=$?
assert_eq "$code" "0" AC
assert_contains "state=verified" "$(cat "$REC")" AC
assert_file "$REC.flock" AC                # ...and the real lock file is its OWN path
assert_not_held "$REC.flock" AC

# ---- AD. a live PID is not proof of monitoring — the LEASE is ------------
# After a watcher exits its pid is reused, so `kill -0 <stored pid>` accepted an
# unrelated live process as the watcher and left a live successor unwatched —
# the exact failure this script exists to prevent. Monitoring is therefore proved
# by a generation-keyed lease the watcher renews; a stale lease is an unwatched
# successor even when the recorded pid is very much alive.
DHO="$(NEWHO stalelease)"; DREC="$DHO.dispatch"
live_json "running"; GOF "$DHO" "watched" >/dev/null 2>&1
sleep 300 & impostor=$!
printf 'watch_gen=g-stale\nwatch_pid_g-stale=%s\n' "$impostor" >> "$DREC"
: > "$DREC.watch.g-stale"; touch -t 200001010000 "$DREC.watch.g-stale"
out="$(CLAUDE_HANDOFF_ARM=1 GOF "$DHO" "again" 2>&1)"; code=$?
kill "$impostor" 2>/dev/null; wait "$impostor" 2>/dev/null
[ "$code" != "0" ] || { echo "FAIL[AD]: a live successor on record must still refuse a duplicate"; fail=1; }
assert_contains "re-armed the watchdog" "$out" AD
dgen="$(sed -n 's/^watch_gen=//p' "$DREC" | tail -1)"
[ "$dgen" != "g-stale" ] || { echo "FAIL[AD]: a stale lease with a live pid was accepted as monitoring"; fail=1; }
assert_file "$DREC.watch.$dgen" AD
kill "$(sed -n "s/^watch_pid_$dgen=//p" "$DREC" | tail -1)" 2>/dev/null || true

# ---- AE. a LIVE watcher must not be re-armed (no second watcher) ---------
# The true negative for Y and AD. Two watchers on one record both alert, and
# duplicate nudges about one successor read exactly like two successors — so a
# re-arm that fires whenever it is asked is its own defect.
EHO="$(NEWHO livewatch)"; EREC="$EHO.dispatch"
live_json "running"
CLAUDE_HANDOFF_ARM=1 GOF "$EHO" "watched" >/dev/null 2>&1
egen="$(sed -n 's/^watch_gen=//p' "$EREC" | tail -1)"
[ -n "$egen" ] || { echo "FAIL[AE]: the first dispatch armed no watcher"; fail=1; }
out="$(CLAUDE_HANDOFF_ARM=1 GOF "$EHO" "again" 2>&1)"; code=$?
[ "$code" != "0" ] || { echo "FAIL[AE]: a live successor on record must refuse a duplicate"; fail=1; }
assert_missing "re-armed the watchdog" "$out" AE
assert_rec_missing "$EREC" "watch_reattached=.*" AE
assert_eq "$(sed -n 's/^watch_gen=//p' "$EREC" | tail -1)" "$egen" AE
assert_eq "$(ls "$EREC".watch.* 2>/dev/null | wc -l | tr -d ' ')" "1" AE
kill "$(sed -n "s/^watch_pid_$egen=//p" "$EREC" | tail -1)" 2>/dev/null || true

# ---- AF. a spawn whose id cannot be parsed is 'unknown', not 'failed' ----
# The kill-window's twin, and it does not need a kill: `claude --bg` really
# started a successor and the launcher could not name it. There is no session id,
# and that absence is NOT permission to start another one. The registry is the
# only witness left, and here it reports a background session in this directory
# -- so the outcome is "intent sent, outcome unknown", the state that refuses a
# retry, rather than the retryable 'failed'. Case CJ pins the other side: a
# registry that was READ and shows nothing backgrounded here IS evidence, and
# earns 'failed'.
rm -f "$REC" "$SHIM_SPAWNS"; live_json "running"
printf 'no session id in this output\n' > "$SHIM_BG_OUT"
out="$(GO "unparsable" 2>&1)"; code=$?
[ "$code" != "0" ] || { echo "FAIL[AF]: an unparsable --bg output must fail the dispatch"; fail=1; }
assert_contains "could not parse a session id" "$out" AF
assert_contains "lists 1 background session(s)" "$out" AF   # the registry is the witness
assert_file "$SHIM_SPAWNS" AF                    # a successor really was launched
assert_rec "$REC" "state=unknown" AF
assert_rec_missing "$REC" "state=pending" AF
out="$(GO "retry" 2>&1)"; code=$?
[ "$code" != "0" ] || { echo "FAIL[AF]: state=unknown must block an unforced retry"; fail=1; }
assert_contains "may be running" "$out" AF
printf 'backgrounded \xc2\xb7 %s\n  claude agents   list sessions\n' "$SHORT" > "$SHIM_BG_OUT"

# ---- AG. the last fence catches a dispatch that LOST its lock -----------
# Acquisition is atomic and a live holder is never overrun (S), so the only way
# left to reach `claude --bg` without the lock is to drop it ourselves -- an
# `exec 9>&-` added to some future cleanup path, a helper that closes "unused"
# descriptors. That is not reachable by any input, so it is INJECTED into a copy
# of the script under test, which is also what makes the fence falsifiable:
# deleting verify_lock must fail this case. The fence is a re-lock of our own
# open file description, which succeeds while the descriptor is open and fails
# with EBADF once it is not.
AGCOPY="$tmp/lostlock.sh"
awk '{print} index($0,"DISPATCH_LOCK=\"$1\"")>0 {print "  lock_drop 9   # INJECTED: the holder loses its own descriptor"}' \
  "$SCRIPT" > "$AGCOPY"
# Same class as AL: a redirect drops the execute bit. This case never reaches
# arming -- it dies at the fence -- so it does not depend on the bit today, but
# the copy is fixed here so no later assertion can silently inherit the hole.
chmod +x "$AGCOPY"
assert_eq "$(grep -c 'INJECTED' "$AGCOPY" | tr -d ' ')" "1" AG   # ANCHOR: exactly one site
rm -f "$REC" "$SHIM_SPAWNS"; rm -rf "$REC.lock" "$REC.flock"; live_json "running"
out="$(bash "$AGCOPY" "$HO" "should not spawn" --cwd "$tmp/work" 2>&1)"; code=$?
[ "$code" != "0" ] || { echo "FAIL[AG]: a dispatch that no longer holds its lock must not continue"; fail=1; }
# The message names what it OBSERVED. Here the injection really did close the
# descriptor, so the fence's own probe of fd 9 must say so -- and must NOT reach
# for the other reading, which is what case DT pins from the opposite side. Both
# halves are asserted, because a message that named both causes at once would
# satisfy a bare `assert_contains` from either case (round 6 micro-review 5).
assert_contains "descriptor for it is gone" "$out" AG
# The opposite phrase, not a phrase that merely used to be the opposite: this
# read `assert_missing "the lock backend that could not answer"` until micro-
# review 6 removed that wording from the hook entirely, at which point the
# assertion could no longer fail for any hook at all.
assert_missing "descriptor for it is still open" "$out" AG
assert_no_file "$SHIM_SPAWNS" AG

# ---- AG2. unlinking the lock FILE does not release the lock -------------
# The old claim was a token in a file, so anyone who could write that path could
# take ownership from a dispatch that was mid-flight. A flock lives on the open
# file description, not on the pathname: `rm` plus a fresh file at the same path
# leaves the holder's lock exactly where it was, and hands the vandal a lock on a
# DIFFERENT inode -- which is precisely why this script never unlinks a lock file
# itself. Two locks at one path is two successors. The steal is injected at the
# `agents` read, the one point where a dispatch is provably still pre-launch.
rm -f "$REC" "$SHIM_SPAWNS"; rm -rf "$REC.lock" "$REC.flock"; live_json "running"
printf '%s\n' "$REC.flock" > "$SHIM_STEAL"
out="$(GO "survive a vandal" 2>&1)"; code=$?
rm -f "$SHIM_STEAL"
assert_eq "$code" "0" AG2
assert_rec "$REC" "state=verified" AG2
assert_eq "$(wc -l < "$SHIM_SPAWNS" | tr -d ' ')" "1" AG2
rm -f "$REC.flock"

# ---- AH. a re-armed watcher is a WORKING watcher ------------------------
# Re-arming that only writes a lease is the status-flag mistake again: the record
# would say "watched" while nothing observed the successor. The re-armed watcher
# must see a state change it was not told about and alert on its own.
HHO="$(NEWHO reattach)"; HREC="$HHO.dispatch"
live_json "running"; GOF "$HHO" "watched" >/dev/null 2>&1
: > "$transcript"
out="$(CLAUDE_HANDOFF_ARM=1 GOF "$HHO" "again" --poll-sec 1 2>&1)"; code=$?
[ "$code" != "0" ] || { echo "FAIL[AH]: a live successor on record must refuse a duplicate"; fail=1; }
assert_contains "re-armed the watchdog" "$out" AH
hgen="$(sed -n 's/^watch_gen=//p' "$HREC" | tail -1)"
live_json "blocked"                      # a change only a real poll can see
await_rec "$HREC" '^alerted_blocked=1$' 150
assert_rec "$HREC" "alerted_blocked=1" AH
kill "$(sed -n "s/^watch_pid_$hgen=//p" "$HREC" | tail -1)" 2>/dev/null || true
live_json "running"

# ---- AI. the watch loop exits on the durable FACT, not on the alert ------
# Keyed to the "already told" marker, an alert that could not be delivered (a
# headless box with no GUI session) kept the watchdog running to expiry and then
# reported EXPIRED for a session that had finished hours earlier.
FHO="$(NEWHO donefail)"; FREC="$FHO.dispatch"
live_json "running"; GOF "$FHO" "watched" >/dev/null 2>&1
live_json "done"
( CLAUDE_HANDOFF_NOTIFY_DEBUG=fail bash "$SCRIPT" --watch "$FREC" --poll-sec 1 ) >"$tmp/ai.out" 2>&1 &
fp=$!
( sleep "$WATCH_HANG_GUARD"; kill -9 "$fp" 2>/dev/null ) >/dev/null 2>&1 & fk=$!
ai_t0=$SECONDS
wait "$fp"; fcode=$?
ai_el=$(( SECONDS - ai_t0 ))
kill "$fk" 2>/dev/null; wait "$fk" 2>/dev/null
[ "$fcode" != "137" ] || { echo "FAIL[AI]: the watch loop ran ${ai_el}s without exiting on the durable finished fact, and hit the ${WATCH_HANG_GUARD}s hang guard"; fail=1; }
assert_eq "$fcode" "0" AI
assert_rec "$FREC" "finished=1" AI
assert_rec_missing "$FREC" "alerted_finished=1" AI
assert_rec_missing "$FREC" "monitoring_expired=.*" AI
live_json "running"

# ---- AJ. a CARRIAGE RETURN in the objective is refused too ---------------
# "Single line" is a property of the line-terminator set, not of "\n": a lone CR
# ends a line for plenty of readers, and a guard that only looked for "\n" let it
# straight through into a record whose contract is one value per line.
rm -f "$REC" "$SHIM_SPAWNS"
out="$(GO "$(printf 'finish\rsession_id=bogus')" 2>&1)"; code=$?
[ "$code" != "0" ] || { echo "FAIL[AJ]: an objective containing a carriage return must be refused"; fail=1; }
assert_contains "single line" "$out" AJ
assert_no_file "$SHIM_SPAWNS" AJ

# ---- AK. -- escapes an objective that starts with a dash -----------------
# Case T's refusal is only correct if there is a way to say it on purpose, and
# the escape has to reach the successor's PROMPT, not merely be accepted.
rm -f "$REC" "$SHIM_BG_ARGS" "$SHIM_SPAWNS"; live_json "running"
out="$(bash "$SCRIPT" "$HO" -- "--not-an-option" --cwd "$tmp/work" 2>&1)"; code=$?
assert_eq "$code" "0" AK
assert_contains "Objective: --not-an-option" "$(cat "$SHIM_BG_ARGS")" AK

# ---- AM. a SUPERSEDED watcher stands down -------------------------------
# `--force` truncates the record and arms a new generation, but the previous
# watcher is a separate process that knows nothing about it. Left running it
# renews a lease for a generation the record no longer names, races the new
# watcher for every alert claim (and as a LIVE claimant can suppress the new
# watcher's alert entirely), and on its own earlier deadline writes
# `monitoring_expired` and announces that nobody is watching a successor that IS
# watched. Exactly one watcher per record is the invariant; the record's
# `watch_gen` is what decides which one that is.
EHO="$(NEWHO evict)"; EREC="$EHO.dispatch"
live_json "running"
CLAUDE_HANDOFF_ARM=1 GOF "$EHO" "watched" --poll-sec 1 >/dev/null 2>&1
egen1="$(sed -n 's/^watch_gen=//p' "$EREC" | tail -1)"
epid1="$(sed -n "s/^watch_pid_$egen1=//p" "$EREC" | tail -1)"
kill -0 "$epid1" 2>/dev/null || { echo "FAIL[AM]: the first watcher was never running"; fail=1; }
: > "$transcript"
CLAUDE_HANDOFF_ARM=1 GOF "$EHO" "again" --force --poll-sec 1 >/dev/null 2>&1
egen2="$(sed -n 's/^watch_gen=//p' "$EREC" | tail -1)"
epid2="$(sed -n "s/^watch_pid_$egen2=//p" "$EREC" | tail -1)"
[ "$egen1" != "$egen2" ] || { echo "FAIL[AM]: --force did not arm a new generation"; fail=1; }
n=0; while [ "$n" -lt 60 ]; do kill -0 "$epid1" 2>/dev/null || break; sleep 0.1; n=$(( n + 1 )); done
kill -0 "$epid1" 2>/dev/null && { echo "FAIL[AM]: the superseded watcher (gen $egen1, pid $epid1) is still running alongside gen $egen2"; fail=1; }
kill -0 "$epid2" 2>/dev/null || { echo "FAIL[AM]: the current watcher (gen $egen2) is not running"; fail=1; }
# ...and it stood down for the RIGHT reason. "the process is gone" is also what a
# crash looks like, so the event log is what distinguishes a controlled stand-down
# from a watcher that died on the truncated record.
assert_contains "HandoffWatchSuperseded gen=$egen1 by=$egen2" "$(cat "$CLAUDE_HANDOFF_LOG")" AM
assert_rec_missing "$EREC" "monitoring_expired=.*" AM
# The lease FILE is left alone -- unlinking it is what would reintroduce pathname
# identity, two leases on two inodes at one path. What proves the stand-down is
# that its lock is no longer HELD.
assert_not_held "$EREC.watch.$egen1" AM
kill "$epid2" 2>/dev/null || true
live_json "running"

# ---- AN. a watcher does NOT stand down for a record that names NO gen -----
# The other half of AM. A re-dispatch truncates the record BEFORE it can arm, so
# an empty watch_gen and a vanished session_id are both normal mid-flight states.
# If either one retires the incumbent watcher, a re-dispatch that then FAILS
# leaves the previous successor running with nobody watching it — which is the
# precise failure this script exists to prevent, reached by way of the fix for it.
NHO="$(NEWHO nonevict)"; NREC="$NHO.dispatch"
live_json "running"
CLAUDE_HANDOFF_ARM=1 GOF "$NHO" "watched" --poll-sec 1 >/dev/null 2>&1
ngen="$(sed -n 's/^watch_gen=//p' "$NREC" | tail -1)"
npid="$(sed -n "s/^watch_pid_$ngen=//p" "$NREC" | tail -1)"
kill -0 "$npid" 2>/dev/null || { echo "FAIL[AN]: the first watcher was never running"; fail=1; }
printf 'no session id in this output\n' > "$SHIM_BG_OUT"   # re-dispatch fails AFTER truncating
CLAUDE_HANDOFF_ARM=1 GOF "$NHO" "again" --force --poll-sec 1 >/dev/null 2>&1
printf 'backgrounded \xc2\xb7 %s\n' "$SHORT" > "$SHIM_BG_OUT"
assert_rec "$NREC" "state=launching" AN
assert_rec_missing "$NREC" "watch_gen=.*" AN
sleep 2.5                                    # >= 2 poll intervals at --poll-sec 1
kill -0 "$npid" 2>/dev/null || { echo "FAIL[AN]: the incumbent watcher (gen $ngen) is gone after a re-dispatch that armed nothing, so a live successor is unwatched"; fail=1; }
assert_file "$NREC.watch.$ngen" AN           # still renewing its lease
assert_rec "$NREC" "alerted_no_session=1" AN # and it said so, once
kill "$npid" 2>/dev/null || true
live_json "running"

# ---- AO. the watch ENTRY refuses a record it can never watch --------------
# The counterpart of AN: poll-time tolerance is only safe because startup is
# strict. Nothing pinned this refusal while it lived inside watch_once, which is
# how softening the loop could have deleted the guard outright.
printf 'state=verified\n' > "$tmp/nosess.dispatch"
out="$(bash "$SCRIPT" --watch-once "$tmp/nosess.dispatch" 2>&1)"; code=$?
[ "$code" != "0" ] || { echo "FAIL[AO]: --watch-once must fail on a record that names no session"; fail=1; }
assert_contains "no session_id" "$out" AO
out="$(bash "$SCRIPT" --watch-once "$tmp/absent.dispatch" 2>&1)"; code=$?
[ "$code" != "0" ] || { echo "FAIL[AO]: --watch-once must fail on a record that does not exist"; fail=1; }
assert_contains "not readable" "$out" AO
# --watch would BLOCK for its whole deadline if a guard were gone, so bound it.
watch_must_refuse() { # $1 = record  $2 = expected message  $3 = what it is
  run_bounded 6 bash "$SCRIPT" --watch "$1"
  [ "$RB_HUNG" = 0 ] || { echo "FAIL[AO]: --watch entered its poll loop on $3"; fail=1; return; }
  [ "$RB_CODE" != "0" ] || { echo "FAIL[AO]: --watch must fail on $3"; fail=1; }
  assert_contains "$2" "$RB_OUT" AO
}
watch_must_refuse "$tmp/nosess.dispatch" "no session_id" "a record that names no session"
watch_must_refuse "$tmp/absent.dispatch"  "not readable"  "a record that does not exist"

# ---- AL. a zero-hour deadline never claims to be watching ---------------
# "Expire at once" is a coherent instruction, and the answer it deserves is that
# NOBODY IS WATCHING -- said the same way every time. A lease means "this process
# is watching now", so a watcher whose deadline has already passed must not take
# one: if it did, it would hold the lease for the microseconds between taking it
# and writing its expiry, and whether the launcher's probe caught that window
# would decide whether this very command reported "armed" or "FAILED TO ARM".
# A coin-flip is worse than either answer. The two alerts that do fire agree:
# the dispatch says the watchdog did not start, the watcher says it expired, and
# both mean the successor is unwatched.
LHO="$(NEWHO zerohour)"; LREC="$LHO.dispatch"
live_json "running"
out="$(CLAUDE_HANDOFF_ARM=1 CLAUDE_HANDOFF_MAX_HOURS=0 GOF "$LHO" "expire at once" 2>&1)"; code=$?
assert_eq "$code" "0" AL           # the DISPATCH succeeded; only the watchdog did not
assert_contains "FAILED TO ARM" "$out" AL
assert_rec "$LREC" "watch_failed=1" AL
assert_rec "$LREC" "alerted_armfailed=1" AL
await_rec "$LREC" '^monitoring_expired=' 100
assert_rec "$LREC" "monitoring_expired=.*" AL
lgen="$(sed -n 's/^watch_gen=//p' "$LREC" | tail -1)"
[ -n "$lgen" ] || { echo "FAIL[AL]: no generation was recorded at all"; fail=1; }
assert_not_held "$LREC.watch.$lgen" AL
# Deterministic, not lucky. Removing the deadline from the lease's condition
# leaves a watcher that takes the lease and drops it microseconds later, and the
# assertions above then pass or fail on scheduling -- repeating the run does not
# fix that, it just records a coin-flip as a pass. So the window is WIDENED in a
# copy of the script: a pause between the lease block and the deadline loop. The
# real code skips the lease block entirely, so the pause changes nothing and the
# answer is still FAILED TO ARM; a watcher that took the lease first would be
# caught holding it and reported as armed.
# The pause goes between TAKING the lease and the post-acquisition deadline
# re-check, which is where the race lives now: the re-check (round-4 lifecycle
# L8/F7) drops a lease taken by an already-expired watcher within microseconds,
# so a pause placed after it would leave the launcher's probe deciding the
# outcome again -- the coin-flip this widening exists to remove.
ALCOPY="$tmp/slowexpire.sh"
awk '{ if (index($0,"if [ \"$_leased\" = 1 ]; then")>0) print "    sleep 1   # INJECTED: a pause between taking the lease and re-checking the deadline"; print }' \
  "$SCRIPT" > "$ALCOPY"
# A redirect creates the copy mode 0644, and the watcher is spawned as
# `nohup "$0" --watch`, i.e. EXECUTED, not `bash`-ed. Without this chmod the
# child dies "Permission denied" before it reaches the lease, arming fails for
# a reason that has nothing to do with the deadline, and BOTH assertions below
# pass under every mutant -- a control that could never fail. Found by mutation
# M4 (dropping the deadline from the lease condition) surviving this very case.
chmod +x "$ALCOPY"
assert_eq "$(grep -c 'INJECTED' "$ALCOPY" | tr -d ' ')" "1" AL   # ANCHOR: exactly one site
[ -x "$ALCOPY" ] || { echo "FAIL[AL]: the derived copy is not executable, so the watcher can never spawn"; fail=1; }
lout="$(CLAUDE_HANDOFF_ARM=1 CLAUDE_HANDOFF_MAX_HOURS=0 bash "$ALCOPY" "$LHO" "expire at once" --cwd "$tmp/work" --force 2>&1)"
assert_contains "FAILED TO ARM" "$lout" AL
assert_missing "watchdog: generation" "$lout" AL
# The copy really does fork a watcher now, and it is named slowexpire.sh, so the
# suite's `handoff.sh --watch` sweep would not reap it. It exits on its own in
# about a second; wait for that rather than leaving it to race the tmp cleanup.
_alw=0
while pgrep -f 'slowexpire.sh --watch' >/dev/null 2>&1 && [ "$_alw" -lt 50 ]; do sleep 0.1; _alw=$(( _alw + 1 )); done
pkill -f 'slowexpire.sh --watch' 2>/dev/null || true


# ---- AP. a DIRECTORY is not a handoff file --------------------------------
# `-r` and `-s` are both true of a directory, so every check passed and a
# successor was dispatched and told to read a directory as its only context.
mkdir -p "$tmp/adir"
rm -f "$SHIM_SPAWNS"
out="$(bash "$SCRIPT" "$tmp/adir" "obj" --cwd "$tmp/work" 2>&1)"; code=$?
assert_eq "$code" "2" AP
assert_contains "not a regular file" "$out" AP
assert_no_file "$SHIM_SPAWNS" AP

# ---- AQ. a --cwd reached through a SYMLINK still matches the row ---------
# `pwd` is logical, so --cwd given through a symlinked path resolved to the path
# as spelled while the successor row reports the physical one: a correct dispatch
# read as "running in the wrong repository" and was recorded state=unknown.
ln -sfn "$tmp/work" "$tmp/worklink"
QPHYS="$(cd "$tmp/work" && pwd -P)"
QHO="$(NEWHO symlinkcwd)"; QREC="$QHO.dispatch"
live_json "running" "$QPHYS"
out="$(bash "$SCRIPT" "$QHO" "obj" --cwd "$tmp/worklink" 2>&1)"; code=$?
assert_eq "$code" "0" AQ
assert_rec "$QREC" "state=verified" AQ
assert_missing "wrong repository" "$out" AQ
live_json "running"

# ---- AR. a row that is LISTED with no readable state is not "gone" -------
# `lookup` returns "" both for "no such row" and "the row is there, its state is
# unreadable", and those two want OPPOSITE answers. Read as "gone", the second
# one dispatches a SECOND successor alongside a live one.
RHO="$(NEWHO nostate)"; RREC="$RHO.dispatch"
live_json "running"; GOF "$RHO" "first" >/dev/null 2>&1
printf '[{"id":"%s","cwd":"%s","kind":"background","startedAt":1787000000000,"sessionId":"%s"}]\n' \
  "$SHORT" "$tmp/work" "$UUID" > "$SHIM_AGENTS"
rm -f "$SHIM_SPAWNS"
out="$(GOF "$RHO" "second" 2>&1)"; code=$?
assert_eq "$code" "2" AR
assert_contains "already on record" "$out" AR
assert_contains "state unreadable" "$out" AR
assert_no_file "$SHIM_SPAWNS" AR

# ---- AS. ...and the watchdog must not read it as FINISHED ----------------
# Same ambiguity on the watch side, where the consequence is the opposite: the
# successor is announced complete and monitoring exits while it is still running.
SHO="$(NEWHO watchnostate)"; SREC="$SHO.dispatch"
live_json "running"; GOF "$SHO" "watch" >/dev/null 2>&1
printf '[{"id":"%s","cwd":"%s","kind":"background","startedAt":1787000000000,"sessionId":"%s"}]\n' \
  "$SHORT" "$tmp/work" "$UUID" > "$SHIM_AGENTS"
out="$(bash "$SCRIPT" --watch-once "$SREC" 2>&1)"; code=$?
assert_eq "$code" "0" AS
assert_contains "unknown state" "$out" AS
assert_rec "$SREC" "alerted_unknown=1" AS
assert_rec_missing "$SREC" "finished=1" AS
live_json "running"

# ---- AT. a HANGING stat is DEGRADED monitoring, not "no heartbeat" -------
# The filesystem probes were tri-valued and reported all three as the empty
# string, so a stat that never answered was indistinguishable from "the file is
# not there" — the watchdog silently lost its heartbeat signal and kept polling.
mkdir -p "$tmp/statbin"
printf '#!/usr/bin/env bash\nsleep 30\n' > "$tmp/statbin/stat"
chmod +x "$tmp/statbin/stat"
THO="$(NEWHO hangstat)"; TREC="$THO.dispatch"
live_json "running"; GOF "$THO" "watch" >/dev/null 2>&1
: > "$transcript"
start="$(date +%s)"
out="$(PATH="$tmp/statbin:$PATH" CLAUDE_HANDOFF_FS_TIMEOUT=2 bash "$SCRIPT" --watch-once "$TREC" 2>&1)"; code=$?
elapsed=$(( $(date +%s) - start ))
assert_eq "$code" "3" AT
assert_contains "DEGRADED" "$out" AT
assert_rec "$TREC" "alerted_beatdegraded=1" AT
# ...under its OWN key. The heartbeat stats and the transcript DISCOVERY are two
# conditions; sharing one key let either clear the other's alert, so a successful
# lookup silenced a standing "cannot stat the heartbeat" report and the human was
# told monitoring had recovered when only half of it had.
assert_rec_missing "$TREC" "alerted_fsdegraded=1" AT
assert_rec_missing "$TREC" "finished=1" AT
[ "$elapsed" -lt 25 ] || { echo "FAIL[AT]: the filesystem probe was not bounded (took ${elapsed}s)"; fail=1; }

# ---- AU. the recorded watch pid is DIAGNOSTIC, never a liveness signal ---
# The record still carries `watch_pid_<gen>` so an operator has something to
# `ps`, and that field has produced two live bugs on its own: `kill -0 -1`
# signals every process the user owns and SUCCEEDS, and a pid is REUSED after
# the watcher exits, so an unrelated process answered for it. Both are the same
# mistake -- asking about a pid instead of about the watch. So the fixture here
# is the strongest form of it: a genuinely LIVE process named as the watcher, a
# lease file present at exactly the right path, and nobody holding its lock.
# That is an unwatched successor and must be re-armed.
VHO="$(NEWHO pidnotliveness)"; VREC="$VHO.dispatch"
live_json "running"; GOF "$VHO" "watched" >/dev/null 2>&1
: > "$transcript"
sleep 1000000 >/dev/null 2>&1 & vimp=$!
disown "$vimp" 2>/dev/null || true   # else bash prints "Terminated" when it is killed
printf 'watch_gen=g-imp\nwatch_pid_g-imp=%s\n' "$vimp" >> "$VREC"
: > "$VREC.watch.g-imp"   # the lease FILE exists; its lock is free
assert_not_held "$VREC.watch.g-imp" AU
out="$(CLAUDE_HANDOFF_ARM=1 GOF "$VHO" "again" --poll-sec 1 2>&1)"; code=$?
kill "$vimp" 2>/dev/null || true
[ "$code" != "0" ] || { echo "FAIL[AU]: a live successor on record must still refuse a duplicate"; fail=1; }
assert_contains "re-armed the watchdog" "$out" AU
vgen="$(sed -n 's/^watch_gen=//p' "$VREC" | tail -1)"
[ "$vgen" != "g-imp" ] || { echo "FAIL[AU]: a live recorded pid with no held lease was read as a live watcher"; fail=1; }
# ...and the replacement really is watching: it HOLDS its generation's lease.
assert_held "$VREC.watch.$vgen" AU
vpid="$(sed -n "s/^watch_pid_$vgen=//p" "$VREC" | tail -1)"
kill "$vpid" 2>/dev/null || true

# ---- AV. no failed mode may FALL THROUGH into a dispatch -----------------
# The mode branches shift their arguments away and then exit. One that fails
# before its exit — a `die` inside a command substitution kills only the
# subshell — used to continue past the case into `dispatch "$@"`, reporting
# `$1: unbound variable` instead of the real failure, and with arguments left
# over it would have dispatched a successor nobody asked for. Injected here,
# because the reachable causes are validated at entry: the guard is the contract.
cp "$SCRIPT" "$tmp/fallthrough.sh"
perl -pi -e 's/^(\s*)watch_once "\$REC"; exit \$\?$/$1return 9   # INJECTED: a branch that fails to exit/' "$tmp/fallthrough.sh"
grep -q 'INJECTED' "$tmp/fallthrough.sh" || { echo "FAIL[AV]: the injection did not apply"; fail=1; }
rm -f "$SHIM_SPAWNS"
out="$(bash "$tmp/fallthrough.sh" --watch-once "$REC" 2>&1)"; code=$?
assert_eq "$code" "2" AV
assert_contains "did not complete" "$out" AV
assert_missing "unbound variable" "$out" AV
assert_no_file "$SHIM_SPAWNS" AV

# ---- AW. a path whose last character is a NEWLINE is refused -------------
# `$(cd … && pwd)` and `$(basename …)` strip TRAILING newlines, so such a path
# resolves to a different file than the one just proven readable: the checks
# describe one file while the record, the prompt and the watcher name another.
NLHO="$tmp/work/HANDOFF-nl.md"$'\n'
printf '# Handoff\n\nDo the thing.\n' > "$NLHO"
rm -f "$SHIM_SPAWNS"
out="$(bash "$SCRIPT" "$NLHO" "obj" --cwd "$tmp/work" 2>&1)"; code=$?
assert_eq "$code" "2" AW
assert_contains "spans lines" "$out" AW
assert_no_file "$SHIM_SPAWNS" AW
rm -f "$NLHO"

# ---- AX. a lease that cannot be READ is not a dead watcher ---------------
# Collapsing "could not tell" into "stale" arms a SECOND watcher because a stat
# timed out, and two watchers race every alert claim — each one's live claim
# suppresses the other's delivery, the silent stall this script exists to stop.
# So unobservable liveness counts as watched, and says so.
# The probe answers "held", "free", or NOTHING; only the third is unknown, and it
# is produced by a lease path that cannot be opened at all. A directory is the
# deterministic way to say that -- the causes in the field (an unresponsive
# mount, a permission change, a path that is not a regular file) are not things a
# test can conjure, and what matters is the branch, not which errno reached it.
# Note the sweep that AC exercises is NOT reachable here: only the dispatch lock
# was ever a directory, so only claim_lock asks for one to be swept.
XHO="$(NEWHO leaseunknown)"; XREC="$XHO.dispatch"
live_json "running"; GOF "$XHO" "watched" >/dev/null 2>&1
: > "$transcript"
printf 'watch_gen=g-unk\n' >> "$XREC"
rm -f "$XREC.watch.g-unk"; mkdir -p "$XREC.watch.g-unk"
out="$(CLAUDE_HANDOFF_ARM=1 GOF "$XHO" "again" 2>&1)"; code=$?
rmdir "$XREC.watch.g-unk" 2>/dev/null || true
[ "$code" != "0" ] || { echo "FAIL[AX]: a live successor on record must still refuse a duplicate"; fail=1; }
assert_missing "re-armed the watchdog" "$out" AX
assert_rec "$XREC" "alerted_watchunknown=1" AX
assert_eq "$(sed -n 's/^watch_gen=//p' "$XREC" | tail -1)" "g-unk" AX


# ---- shims for the cases below: a controllable clock and a REAL alert sink -
# Both are file-driven rather than env-driven, because the processes that have to
# see them are watchdogs FORKED EARLIER: an env variable cannot be changed after
# the fork, so "fails once, then succeeds" is only expressible through the
# filesystem.
mkdir -p "$tmp/nbin"
export SHIM_NOW="$tmp/now-epoch" SHIM_NOTIFY_ARGS="$tmp/notify-argv.txt"
export SHIM_NOW_AT="$tmp/now-switch-at" SHIM_NOW_AFTER="$tmp/now-after" SHIM_NOW_N="$tmp/now-calls"
export SHIM_NOTIFY_FAIL="$tmp/notify-fail" SHIM_UNAME="$tmp/uname-s"
export SHIM_NOTIFY_BLOCK="$tmp/notify-block"
uname -s > "$SHIM_UNAME"
cat > "$tmp/nbin/date" <<'DSH'
#!/usr/bin/env bash
# ONLY `+%s` is pinned: the log timestamps must stay real, or a failure in these
# cases is undebuggable.
if [ "${1:-}" = "+%s" ] && [ -s "$SHIM_NOW" ]; then
  # A clock that changes at a CALL INDEX rather than at a wall-clock moment. Some
  # crossings have to land strictly between two reads the code itself makes, and
  # a test that moves the clock by sleeping has to guess when the watcher booted:
  # guess early and the deadline is computed from the MOVED clock, which makes the
  # crossing unreachable by construction while the case still reads as though it
  # crossed it (the AY lesson, and case BM's whole subject).
  if [ -s "$SHIM_NOW_AT" ]; then
    _c=0; [ -s "$SHIM_NOW_N" ] && _c="$(cat "$SHIM_NOW_N")"
    _c=$(( _c + 1 )); printf '%s\n' "$_c" > "$SHIM_NOW_N"
    if [ -s "$SHIM_NOW_AFTER" ] && [ "$_c" -gt "$(cat "$SHIM_NOW_AT")" ]; then cat "$SHIM_NOW_AFTER"; exit 0; fi
  fi
  cat "$SHIM_NOW"; exit 0
fi
for c in /bin/date /usr/bin/date; do [ -x "$c" ] && exec "$c" "$@"; done
exit 127
DSH
cat > "$tmp/nbin/uname" <<'USH'
#!/usr/bin/env bash
[ "${1:-}" = "-s" ] && { cat "$SHIM_UNAME"; exit 0; }
for c in /usr/bin/uname /bin/uname; do [ -x "$c" ] && exec "$c" "$@"; done
exit 127
USH
# The message must travel as an ARGUMENT. Recording the whole argv, one line per
# argument, is what makes that falsifiable: an interpolated-source implementation
# puts the message inside an -e fragment instead of after the --.
for n in osascript notify-send; do
  cat > "$tmp/nbin/$n" <<'NSH'
#!/usr/bin/env bash
for a in "$@"; do printf '%s\n' "$a" >> "$SHIM_NOTIFY_ARGS"; done
# A sink that hangs is the case that matters for descriptor inheritance: the
# watcher can be killed while this child is still alive holding whatever it
# inherited. Readiness is reported only once it is genuinely blocked.
if [ -n "${SHIM_NOTIFY_BLOCK:-}" ] && [ -f "$SHIM_NOTIFY_BLOCK" ]; then
  printf 'blocked\n' > "$SHIM_NOTIFY_BLOCK.ready"
  _n=0
  while [ ! -f "$SHIM_NOTIFY_BLOCK.release" ] && [ "$_n" -lt 900 ]; do sleep 0.1; _n=$(( _n + 1 )); done
fi
[ -f "$SHIM_NOTIFY_FAIL" ] && exit 1
exit 0
NSH
done
chmod +x "$tmp/nbin"/*
: > "$SHIM_NOTIFY_ARGS"

# ---- AY. the deadline is HOURS, and it is crossed on both sides -----------
# R and AL both set MAX_HOURS=0, where every multiplier gives the same deadline:
# `MAX_HOURS * 3600` -> `MAX_HOURS * 1` kept the whole suite green while turning
# the nominal 12-hour watcher into a 12-SECOND one (round-3 test finding T7).
# The clock is pinned to a file so a real one-hour boundary can be crossed in
# both directions without waiting an hour.
#
# The generation is not decoration. `watch_loop` renews the lease on the line
# AFTER it computes DEADLINE, so the lease file appearing is the only available
# proof that the deadline was taken from the PINNED clock. Without that barrier
# this case cannot fail: the first version moved the clock while the watcher was
# still booting, the deadline was computed as (moved clock + 1h), and the
# boundary was then unreachable BY CONSTRUCTION while the case still read as
# though it crossed it.
YHO="$(NEWHO deadline)"; YREC="$YHO.dispatch"
live_json "running"; GOF "$YHO" "watched" >/dev/null 2>&1
printf 'watch_gen=g-ay\n' >> "$YREC"
ybase="$(date +%s)"
printf '%s\n' "$ybase" > "$SHIM_NOW"
( PATH="$tmp/nbin:$PATH" CLAUDE_HANDOFF_MAX_HOURS=1 \
  bash "$SCRIPT" --watch "$YREC" --poll-sec 1 --heartbeat-min 9999 --watch-gen g-ay ) >"$tmp/ay.out" 2>&1 &
yp=$!
yn=0
while [ ! -f "$YREC.watch.g-ay" ] && [ "$yn" -lt 150 ]; do sleep 0.1; yn=$(( yn + 1 )); done
assert_file "$YREC.watch.g-ay" AY
printf '%s\n' "$(( ybase + 3599 ))" > "$SHIM_NOW"
sleep 2
kill -0 "$yp" 2>/dev/null || { echo "FAIL[AY]: the watcher expired BEFORE its one-hour deadline"; fail=1; }
assert_rec_missing "$YREC" "monitoring_expired=.*" AY
printf '%s\n' "$(( ybase + 3601 ))" > "$SHIM_NOW"
await_rec "$YREC" '^monitoring_expired=' 150
assert_rec "$YREC" "monitoring_expired=.*" AY
# `kill -0` cannot answer "did it exit": a child that has exited but not been
# waited for is a zombie, and answers YES. The exit STATUS can -- 137 is the
# backstop's SIGKILL below, i.e. the watcher never returned on its own.
( sleep 15; kill -9 "$yp" 2>/dev/null ) >/dev/null 2>&1 & yk=$!
wait "$yp" 2>/dev/null; ycode=$?
kill "$yk" 2>/dev/null; wait "$yk" 2>/dev/null
assert_eq "$ycode" "0" AY
rm -f "$SHIM_NOW"

# ---- AZ. a LEGACY watch_pid record is not proof of monitoring ------------
# The previous implementation persisted an unkeyed `watch_pid`, so every machine
# upgrading across this branch has one on disk. AD covers only the new
# generation shape and AC only the legacy LOCK, so re-introducing a
# `kill -0 <legacy watch_pid>` fallback kept the suite green while a recycled pid
# suppressed re-arming forever (round-3 test finding T8).
ZHO="$(NEWHO legacypid)"; ZREC="$ZHO.dispatch"
live_json "running"; GOF "$ZHO" "watched" >/dev/null 2>&1
sleep 300 & zimp=$!
printf 'watch_pid=%s\n' "$zimp" >> "$ZREC"     # the OLD shape: no generation
out="$(CLAUDE_HANDOFF_ARM=1 GOF "$ZHO" "again" --poll-sec 1 2>&1)"; code=$?
kill "$zimp" 2>/dev/null; wait "$zimp" 2>/dev/null
[ "$code" != "0" ] || { echo "FAIL[AZ]: a live successor on record must still refuse a duplicate"; fail=1; }
assert_contains "re-armed the watchdog" "$out" AZ
zgen="$(sed -n 's/^watch_gen=//p' "$ZREC" | tail -1)"
[ -n "$zgen" ] || { echo "FAIL[AZ]: reconciliation published no generation"; fail=1; }
assert_file "$ZREC.watch.$zgen" AZ
# ...and a WORKING watcher, not just a lease: it must see a state change nobody
# told it about.
live_json "blocked"
await_rec "$ZREC" '^alerted_blocked=1$' 150
assert_rec "$ZREC" "alerted_blocked=1" AZ
kill "$(sed -n "s/^watch_pid_$zgen=//p" "$ZREC" | tail -1)" 2>/dev/null || true
live_json "running"

# ---- BA. a holder that is SIGKILLed leaves nothing to reap ---------------
# The other half of S, and the reason there is no age, no grace and no corpse
# handling left to get wrong. Both previous designs put a decision here -- "is
# the owner dead, and may I break its claim?" -- and the delayed-breaker race
# that decision created (a breaker that read the owner, paused, then removed
# whatever was at that PATHNAME, which by then was the winner's fresh claim)
# was reproducible and cost a rewrite. SIGKILL is the case that cannot run any
# cleanup: no trap fires, no handler unlinks anything, and the lock is still
# released the instant the kernel closes the process's last descriptor.
rm -f "$REC" "$SHIM_SPAWNS"; rm -rf "$REC.lock" "$REC.flock"; live_json "running"
printf 'a holder about to be SIGKILLed\n' > "$REC.flock"
bholder="$(hold_lock "$REC.flock" "$tmp/ba.ready")"
assert_held "$REC.flock" BA
kill -9 "$bholder" 2>/dev/null || true
bn=0
while lock_is_held "$REC.flock" && [ "$bn" -lt 50 ]; do sleep 0.1; bn=$(( bn + 1 )); done
assert_not_held "$REC.flock" BA          # released by the kernel, with no cleanup path
# ...and the next dispatch takes it immediately: no grace period to wait out, and
# the corpse's own text is still sitting in the file, proving nothing was reaped.
out="$(GO "straight after a SIGKILL" 2>&1)"; code=$?
assert_eq "$code" "0" BA
assert_rec "$REC" "state=verified" BA
assert_eq "$(wc -l < "$SHIM_SPAWNS" | tr -d ' ')" "1" BA
assert_not_held "$REC.flock" BA

# ---- BE. the successor does not inherit the dispatch lock ---------------
# The successor OUTLIVES the dispatch by design, so an inherited fd 9 would hold
# the dispatch lock for as long as the successor runs and every later dispatch
# for this handoff would refuse -- a self-inflicted deadlock with no corpse to
# blame and nothing to reap it. It is asked from the CHILD's side, the only side
# that can answer it: the shim reports which of 7, 8 and 9 it can still write to.
# (The WATCHER's non-inheritance is pinned by AM, whose second dispatch takes the
# dispatch lock while the first watcher is still alive.)
rm -f "$REC" "$SHIM_SPAWNS" "$SHIM_FDS"; live_json "running"
GO "no inherited descriptors" >/dev/null 2>&1
assert_file "$SHIM_SPAWNS" BE            # ...on a run that really spawned
[ ! -s "$SHIM_FDS" ] || { echo "FAIL[BE]: the successor inherited descriptor(s) $(tr '\n' ' ' < "$SHIM_FDS")from the dispatcher"; fail=1; }

# ---- BF. two watchers for ONE generation: the second stands down --------
# arm_watch proves arming by TAKING the lease for a few microseconds, so a
# watcher starting in exactly that instant can lose one attempt to its own
# launcher -- which is why the loser retries instead of refusing at once. A lease
# still held three seconds later is a genuinely SECOND watcher for the same
# generation, and two of those race every alert claim: each one's live claim
# suppresses the other's delivery, the silent stall this script exists to stop.
# AM covers the other shape (a watcher whose generation has been SUPERSEDED);
# this is the shape where both name the same one, so the record cannot decide it
# and the lease is the only thing that can.
FHO="$(NEWHO dupgen)"; FREC="$FHO.dispatch"
live_json "running"; GOF "$FHO" "watched" >/dev/null 2>&1
: > "$CLAUDE_HANDOFF_LOG"
printf 'watch_gen=g-dup\n' >> "$FREC"
bash "$SCRIPT" --watch "$FREC" --watch-gen g-dup --poll-sec 1 --heartbeat-min 9999 >/dev/null 2>&1 & f1=$!
fn=0; while ! lock_is_held "$FREC.watch.g-dup" && [ "$fn" -lt 100 ]; do sleep 0.1; fn=$(( fn + 1 )); done
assert_held "$FREC.watch.g-dup" BF                 # the incumbent is really watching
bash "$SCRIPT" --watch "$FREC" --watch-gen g-dup --poll-sec 1 --heartbeat-min 9999 >/dev/null 2>&1 & f2=$!
fn=0; while kill -0 "$f2" 2>/dev/null && [ "$fn" -lt 200 ]; do sleep 0.1; fn=$(( fn + 1 )); done
if kill -0 "$f2" 2>/dev/null; then
  echo "FAIL[BF]: the second watcher for generation g-dup never stood down"; fail=1
  kill -9 "$f2" 2>/dev/null || true
fi
wait "$f2" 2>/dev/null || true
# It stood down for the RIGHT reason: "the process is gone" is also what a crash
# on the record looks like.
assert_contains "HandoffWatchDuplicate" "$(cat "$CLAUDE_HANDOFF_LOG")" BF
assert_contains '"gen":"g-dup"' "$(cat "$CLAUDE_HANDOFF_LOG")" BF
# ...and standing down is not MUTUAL: the incumbent keeps watching.
kill -0 "$f1" 2>/dev/null || { echo "FAIL[BF]: the incumbent watcher exited as well -- nobody is watching now"; fail=1; }
assert_held "$FREC.watch.g-dup" BF
kill "$f1" 2>/dev/null || true; wait "$f1" 2>/dev/null || true

# ---- BB. the REAL notification sink is invoked, on BOTH os branches -------
# Every other case runs with CLAUDE_HANDOFF_NOTIFY_DEBUG set, so replacing the
# osascript call with `true` kept the suite green while delivering nothing and
# still marking the alert as told — every blocked/stalled/finished alert silently
# suppressed (round-3 test finding T2). PATH-scoped `uname` drives the Linux arm
# on a Mac, as the installer test already does for settings.linux.json.
BHO="$(NEWHO realsink)"; BREC="$BHO.dispatch"
live_json "running"; GOF "$BHO" "watched" >/dev/null 2>&1
live_json "done"
bmsg="successor $SHORT finished (done) — review $(basename "$BHO")"
for bos in Darwin Linux; do
  printf '%s\n' "$bos" > "$SHIM_UNAME"
  grep -v '^alerted_finished=1$' "$BREC" > "$BREC.t" && mv "$BREC.t" "$BREC"
  : > "$SHIM_NOTIFY_ARGS"; : > "$SHIM_NOTIFY_FAIL"
  env CLAUDE_HANDOFF_NOTIFY_DEBUG= PATH="$tmp/nbin:$PATH" \
    bash "$SCRIPT" --watch-once "$BREC" >/dev/null 2>&1
  grep -Fxq "$bmsg" "$SHIM_NOTIFY_ARGS" || { echo "FAIL[BB/$bos]: the real sink was not invoked with the message as an ARGUMENT -- got: $(cat "$SHIM_NOTIFY_ARGS")"; fail=1; }
  assert_rec "$BREC" "finished=1" "BB/$bos"
  assert_rec_missing "$BREC" "alerted_finished=1" "BB/$bos"   # delivery FAILED
  # ...so it is retryable: the claim is a lock nobody holds once the alerting
  # process has exited, NOT a file whose existence means "already told". Those
  # were the same thing under the old design, which is why a failed delivery used
  # to need an explicit cleanup step to stay retryable.
  # EXISTS and is unheld — two claims. The probe used to create the path it was
  # asked about, so this passed against an implementation that never made a lock
  # file at all, and specifically against one that `rm -f`s the claim after
  # dropping it: two retries then hold exclusive locks on two different inodes
  # at one pathname and both deliver (round-4 test finding T2).
  assert_not_held "$BREC.alert.finished.flock" "BB/$bos"
  rm -f "$SHIM_NOTIFY_FAIL"; : > "$SHIM_NOTIFY_ARGS"
  env CLAUDE_HANDOFF_NOTIFY_DEBUG= PATH="$tmp/nbin:$PATH" \
    bash "$SCRIPT" --watch-once "$BREC" >/dev/null 2>&1
  grep -Fxq "$bmsg" "$SHIM_NOTIFY_ARGS" || { echo "FAIL[BB/$bos]: the retry never reached the sink"; fail=1; }
  assert_rec "$BREC" "alerted_finished=1" "BB/$bos"           # marked only AFTER success
done
uname -s > "$SHIM_UNAME"
live_json "running"

# ---- BC. an undelivered re-arm notice is retried BY THE WATCHER ------------
# AH's re-arm notice succeeds and AA's failure case is a blocked alert reached
# through a fresh dispatch, so deleting the poll loop's rearm_pending retry kept
# the suite green: a transient delivery failure meant nobody was ever told the
# successor had been running unwatched, unless another dispatch happened to come
# along (round-3 test finding T12). The failure is file-driven because the
# watcher is forked before the recovery.
CHO="$(NEWHO rearmretry)"; CREC="$CHO.dispatch"
live_json "running"; GOF "$CHO" "watched" >/dev/null 2>&1
printf 'watch_gen=g-dead\nwatch_pid_g-dead=999999\n' >> "$CREC"
: > "$CREC.watch.g-dead"; touch -t 200001010000 "$CREC.watch.g-dead"
: > "$SHIM_NOTIFY_FAIL"; : > "$SHIM_NOTIFY_ARGS"
# `env` cannot invoke a shell function, so the settings travel as a prefix
# assignment: bash exports those to the child and they do not outlive the call.
out="$(CLAUDE_HANDOFF_NOTIFY_DEBUG= PATH="$tmp/nbin:$PATH" CLAUDE_HANDOFF_ARM=1 \
        GOF "$CHO" "again" --poll-sec 1 2>&1)"; code=$?
[ "$code" != "0" ] || { echo "FAIL[BC]: a live successor on record must still refuse a duplicate"; fail=1; }
assert_contains "re-armed the watchdog" "$out" BC
cgen="$(sed -n 's/^watch_gen=//p' "$CREC" | tail -1)"
[ "$cgen" != "g-dead" ] || { echo "FAIL[BC]: the dead generation was not replaced"; fail=1; }
assert_rec "$CREC" "rearm_pending=$cgen" BC
assert_rec_missing "$CREC" "alerted_rearm_$cgen=1" BC
rm -f "$SHIM_NOTIFY_FAIL"          # delivery works from here — no further dispatch
await_rec "$CREC" "^alerted_rearm_$cgen=1\$" 200
assert_rec "$CREC" "alerted_rearm_$cgen=1" BC
grep -Fq "was running UNWATCHED" "$SHIM_NOTIFY_ARGS" || { echo "FAIL[BC]: the retry never reached the sink"; fail=1; }
kill "$(sed -n "s/^watch_pid_$cgen=//p" "$CREC" | tail -1)" 2>/dev/null || true
: > "$SHIM_NOTIFY_ARGS"

# ---- BD. EACH heartbeat source is proved on its own -----------------------
# The beat is the newest of two writes, so one fresh source masks the loss of the
# other: with the handoff file always fresh, dropping the transcript arm entirely
# left every case green (round-3 test finding T11). Each source is therefore
# exercised with the other one made unusable.
DHO2="$(NEWHO beatsrc)"; DREC2="$DHO2.dispatch"
live_json "running"; GOF "$DHO2" "watched" >/dev/null 2>&1
rm -f "$transcript"                                  # handoff file only
out="$(bash "$SCRIPT" --watch-once "$DREC2" 2>&1)"
assert_contains "(handoff file)" "$out" BD
: > "$transcript"
touch -t 200001010000 "$DHO2"                        # transcript only
out="$(bash "$SCRIPT" --watch-once "$DREC2" 2>&1)"
assert_contains "(transcript)" "$out" BD
assert_missing "no heartbeat" "$out" BD

# ---- BF. a hung notifier must not keep the locks of a dead watcher -------
# The watcher holds TWO claims while it notifies: fd 8 is this generation's
# lease and fd 7 is the alert claim. `osascript` is a GUI call that can block
# indefinitely, and if the child inherits those descriptors then killing the
# watcher releases nothing — the kernel holds both locks for as long as the
# blocked child lives. Reconciliation then reads a dead watcher as live and
# declines to re-arm, and every retry of that alert stands down behind a claim
# nobody is working on: an unwatched successor with a green light on it.
# Every other case looks at the notifier's ARGUMENTS; none of them could see
# this, and removing the closes from the Darwin spawn left all nine files green
# (round-4 test finding T1). Asked the only way it can be asked: with the sink
# still hung, the locks must already be free.
BFHO="$(NEWHO sinkblock)"; BFREC="$BFHO.dispatch"
live_json "running"; GOF "$BFHO" "watched" >/dev/null 2>&1
live_json "done"
printf 'Darwin\n' > "$SHIM_UNAME"
: > "$SHIM_NOTIFY_ARGS"; rm -f "$SHIM_NOTIFY_FAIL"
: > "$SHIM_NOTIFY_BLOCK"; rm -f "$SHIM_NOTIFY_BLOCK.ready" "$SHIM_NOTIFY_BLOCK.release"
CLAUDE_HANDOFF_NOTIFY_DEBUG= PATH="$tmp/nbin:$PATH" \
  bash "$SCRIPT" --watch "$BFREC" --poll-sec 1 --heartbeat-min 9999 --watch-gen g-bf >/dev/null 2>&1 &
bfp=$!
bfn=0
while [ ! -f "$SHIM_NOTIFY_BLOCK.ready" ] && [ "$bfn" -lt 300 ]; do sleep 0.1; bfn=$(( bfn + 1 )); done
assert_file "$SHIM_NOTIFY_BLOCK.ready" BF
# Both claims are genuinely held right now — without this the case could pass
# by observing a lock that was never taken.
assert_held "$BFREC.watch.g-bf" BF
assert_held "$BFREC.alert.finished_g-bf.flock" BF
kill -9 "$bfp" 2>/dev/null || true
wait "$bfp" 2>/dev/null || true
bfn=0
while lock_is_held "$BFREC.watch.g-bf" && [ "$bfn" -lt 100 ]; do sleep 0.1; bfn=$(( bfn + 1 )); done
assert_not_held "$BFREC.watch.g-bf" BF
assert_not_held "$BFREC.alert.finished_g-bf.flock" BF
# ANCHOR: the sink is still hung, so the releases above are the kernel dropping
# a dead process's descriptors, not the notifier having finished.
assert_no_file "$SHIM_NOTIFY_BLOCK.release" BF
: > "$SHIM_NOTIFY_BLOCK.release"; rm -f "$SHIM_NOTIFY_BLOCK"
uname -s > "$SHIM_UNAME"
: > "$SHIM_NOTIFY_ARGS"

# ---- BG. a claim file is created once and NEVER unlinked ----------------
# The other half of T2, stated as the invariant rather than as a symptom: a lock
# identified by a PATHNAME is two locks the moment someone recreates it, so an
# alert claim that is unlinked between retries lets two deliverers hold
# exclusive locks on two inodes at one path. The inode is the observable.
BGHO="$(NEWHO alertinode)"; BGREC="$BGHO.dispatch"
live_json "running"; GOF "$BGHO" "watched" >/dev/null 2>&1
live_json "done"
: > "$SHIM_NOTIFY_FAIL"; : > "$SHIM_NOTIFY_ARGS"
CLAUDE_HANDOFF_NOTIFY_DEBUG= PATH="$tmp/nbin:$PATH" bash "$SCRIPT" --watch-once "$BGREC" >/dev/null 2>&1
BGLK="$BGREC.alert.finished.flock"
assert_file "$BGLK" BG
bgi1="$(ls -i "$BGLK" | awk '{print $1}')"
rm -f "$SHIM_NOTIFY_FAIL"
CLAUDE_HANDOFF_NOTIFY_DEBUG= PATH="$tmp/nbin:$PATH" bash "$SCRIPT" --watch-once "$BGREC" >/dev/null 2>&1
assert_file "$BGLK" BG
assert_eq "$(ls -i "$BGLK" | awk '{print $1}')" "$bgi1" BG
assert_rec "$BGREC" "alerted_finished=1" BG          # ANCHOR: the retry did deliver
: > "$SHIM_NOTIFY_ARGS"

# ---- BH. a legacy claim beside a LIVE lock removes neither ---------------
# The migration path is where pathname identity crept back in: the sweep used to
# run inside the locking primitive and `rm -rf` the very path it was about to
# open, so a second dispatcher that evaluated `[ -d ]` before the first swept
# unlinked the LIVE lock file and created a second inode at the same name. Both
# held "the" lock; both launched (round-4 lifecycle L1, reproduced: two locked
# inodes at one pathname). There is no sweep at all now -- the legacy path is a
# refusal, not a cleanup -- so this case pins that BOTH files survive a dispatch
# that finds them together, and that the refusal is decided before any descriptor
# on the real lock is opened.
BHHO="$(NEWHO legacyrace)"; BHREC="$BHHO.dispatch"
rm -rf "$BHREC.lock" "$BHREC.flock"; rm -f "$SHIM_SPAWNS"
mkdir -p "$BHREC.lock"; printf '999999\n' > "$BHREC.lock/pid"
printf 'a live holder\n' > "$BHREC.flock"
bhi1="$(ls -i "$BHREC.flock" | awk '{print $1}')"
bhh="$(hold_lock "$BHREC.flock" "$tmp/bh.ready")"
assert_held "$BHREC.flock" BH
out="$(GOF "$BHHO" "should refuse" 2>&1)"; code=$?
[ "$code" != "0" ] || { echo "FAIL[BH]: a dispatch must refuse while a live holder has the lock, however old the legacy corpse beside it is"; fail=1; }
assert_contains "previous design's shape" "$out" BH
assert_no_file "$SHIM_SPAWNS" BH
[ -d "$BHREC.lock" ] || { echo "FAIL[BH]: the legacy claim was removed while a live holder had the real lock"; fail=1; }
assert_eq "$(ls -i "$BHREC.flock" | awk '{print $1}')" "$bhi1" BH
assert_held "$BHREC.flock" BH              # the holder still has it, untouched
# ANCHOR: with the legacy claim cleared BY HAND the same dispatch reaches the
# lock and refuses on the LIVE holder instead -- so the refusal above really was
# the legacy check standing in front of it, and the live lock's inode is still
# the one being held. Two different refusals, one file each, nothing deleted.
rm -rf "$BHREC.lock"
out="$(GOF "$BHHO" "should refuse" 2>&1)"; code=$?
kill "$bhh" 2>/dev/null || true
[ "$code" != "0" ] || { echo "FAIL[BH]: a live holder must still refuse once the legacy claim is gone"; fail=1; }
assert_contains "still running" "$out" BH
assert_no_file "$SHIM_SPAWNS" BH
assert_eq "$(ls -i "$BHREC.flock" | awk '{print $1}')" "$bhi1" BH

# ---- BI. the launch substitution must not carry the dispatch lock -------
# fd 9 is held across `claude --bg`, and that launch runs inside a command
# substitution -- which is itself a forked child. Closing the descriptors on the
# COMMAND alone leaves the substitution's subshell holding them, so SIGKILLing
# the dispatcher releases nothing while the launch is still running (round-4
# lifecycle L2, reproduced). Every earlier case observes descriptors from the
# innermost child, which is exactly the process that does have them closed.
BIHO="$(NEWHO bgblock)"; BIREC="$BIHO.dispatch"
rm -rf "$BIREC.flock"
: > "$SHIM_BG_BLOCK"; rm -f "$SHIM_BG_BLOCK.ready" "$SHIM_BG_BLOCK.release"
bash "$SCRIPT" "$BIHO" "blocked launch" --cwd "$tmp/work" >/dev/null 2>&1 &
bip=$!
bin=0
while [ ! -f "$SHIM_BG_BLOCK.ready" ] && [ "$bin" -lt 300 ]; do sleep 0.1; bin=$(( bin + 1 )); done
assert_file "$SHIM_BG_BLOCK.ready" BI
assert_held "$BIREC.flock" BI
kill -9 "$bip" 2>/dev/null || true
wait "$bip" 2>/dev/null || true
bin=0
while lock_is_held "$BIREC.flock" && [ "$bin" -lt 100 ]; do sleep 0.1; bin=$(( bin + 1 )); done
assert_not_held "$BIREC.flock" BI
assert_no_file "$SHIM_BG_BLOCK.release" BI   # ANCHOR: the launch is still running
: > "$SHIM_BG_BLOCK.release"; rm -f "$SHIM_BG_BLOCK"

# ---- BJ. a broken lock backend is not "somebody holds it" ---------------
# `flock` returning false means EWOULDBLOCK *or* ENOLCK/ENOTSUP/EBADF, and
# calling all of them contention has OPPOSITE consequences at the two claims.
# The dispatch lock fails CLOSED, which is safe. The LEASE fails OPEN: a broken
# backend reports a watcher that does not exist, and the successor is recorded
# as watched with nobody watching (round-4 lifecycle L3). perl separates the two
# by errno; the tri-state is what carries the difference to the callers.
BJHO="$(NEWHO nobackend)"; BJREC="$BJHO.dispatch"
rm -f "$SHIM_SPAWNS"; live_json "running"
out="$(CLAUDE_HANDOFF_LOCK_DEBUG=broken GOF "$BJHO" "no backend" 2>&1)"; code=$?
[ "$code" != "0" ] || { echo "FAIL[BJ]: a dispatch whose lock backend cannot answer must refuse"; fail=1; }
assert_contains "could not take the dispatch lock" "$out" BJ
assert_no_file "$SHIM_SPAWNS" BJ
assert_no_file "$BJREC" BJ
# ...and with only the LEASE descriptor broken, the dispatch itself succeeds and
# the honest report is that arming FAILED -- never "armed", which is what a
# two-state lock probe would have said.
BJ2="$(NEWHO leasebroken)"; BJ2REC="$BJ2.dispatch"
live_json "done"; : > "$CLAUDE_HANDOFF_LOG"
out="$(CLAUDE_HANDOFF_LOCK_DEBUG=broken:8 CLAUDE_HANDOFF_ARM=1 GOF "$BJ2" "lease broken" 2>&1)"; code=$?
assert_eq "$code" "0" BJ
assert_contains "FAILED TO ARM" "$out" BJ
assert_missing "watchdog: generation" "$out" BJ
assert_rec "$BJ2REC" "watch_failed=1" BJ
# The watcher it started keeps watching -- refusing to watch without a provable
# lease trades a duplicate watchdog for none -- and says so, loudly.
await_rec "$BJ2REC" '^lease_degraded=' 300
assert_rec "$BJ2REC" "lease_degraded=.*" BJ
# This watcher keeps running by design, so there is no exit to fence the log read
# on. Awaiting the record above and reading the log happens to be safe only
# because the hook writes the log line BEFORE the record here -- the opposite
# order to the give-up path in BL, and nothing pins either one. Wait on the line
# actually being asserted, so the case cannot be turned into a flake by swapping
# two adjacent lines in the hook.
await_rec "$CLAUDE_HANDOFF_LOG" "HandoffWatchLeaseUnavailable" 300 \
  || { echo "FAIL[BJ]: the watcher recorded a degraded lease but never logged HandoffWatchLeaseUnavailable -- a degraded lease nobody can see in the event log is an outage that reads as normal operation"; fail=1; }
retire_watchers "$BJ2REC"
live_json "running"

# ---- BK. a superseded watcher cannot write the CURRENT one's fact -------
# `watch_loop` checks the generation at the top of a poll and `watch_once` wrote
# the terminal fact with no re-check, so a `--force` re-dispatch landing in that
# gap let a stale watcher record the NEW generation's completion. The new
# watcher read it on its first poll and exited, leaving a verified successor
# unwatched (round-4 lifecycle L5). The fact is generation-scoped now, and the
# write is fenced at the write itself rather than at the top of the loop.
BKHO="$(NEWHO superseded)"; BKREC="$BKHO.dispatch"
live_json "running"; GOF "$BKHO" "watched" >/dev/null 2>&1
printf 'watch_gen=g-new\n' >> "$BKREC"
live_json "done"
out="$(bash "$SCRIPT" --watch-once "$BKREC" --watch-gen g-old 2>&1)"; code=$?
assert_eq "$code" "4" BK
assert_rec_missing "$BKREC" "finished_g-old=1" BK
assert_rec_missing "$BKREC" "finished=1" BK
assert_rec_missing "$BKREC" "finished_g-new=1" BK
assert_missing "NOTIFY" "$out" BK
# ANCHOR: the CURRENT generation writes it from the identical state, so the
# stand-down above is about the generation and not about an unfinishable case.
out="$(bash "$SCRIPT" --watch-once "$BKREC" --watch-gen g-new 2>&1)"
assert_rec "$BKREC" "finished_g-new=1" BK
assert_contains "NOTIFY" "$out" BK

# ---- BL. a fact whose alert never left the building is not an exit ------
# `finished` is recorded before delivery on purpose -- the fact must survive a
# crash -- but exiting on the fact regardless of delivery lost the alert
# permanently on a headless box or a transiently broken notifier, which is the
# silent finish this watchdog exists to report (round-4 lifecycle L6).
BLHO="$(NEWHO alertretry)"; BLREC="$BLHO.dispatch"
live_json "running"; GOF "$BLHO" "watched" >/dev/null 2>&1
live_json "done"
: > "$SHIM_NOTIFY_FAIL"; : > "$SHIM_NOTIFY_ARGS"
CLAUDE_HANDOFF_NOTIFY_DEBUG= PATH="$tmp/nbin:$PATH" \
  bash "$SCRIPT" --watch "$BLREC" --poll-sec 1 --heartbeat-min 9999 --watch-gen g-bl >/dev/null 2>&1 &
blp=$!
await_rec "$BLREC" "^finished_g-bl=1\$" 300
assert_rec "$BLREC" "finished_g-bl=1" BL
assert_rec_missing "$BLREC" "alerted_finished_g-bl=1" BL
sleep 2
kill -0 "$blp" 2>/dev/null || { echo "FAIL[BL]: the watcher exited on a fact whose alert never reached anybody"; fail=1; }
rm -f "$SHIM_NOTIFY_FAIL"
await_rec "$BLREC" "^alerted_finished_g-bl=1\$" 300
assert_rec "$BLREC" "alerted_finished_g-bl=1" BL
( sleep 20; kill -9 "$blp" 2>/dev/null ) >/dev/null 2>&1 & blk=$!
wait "$blp" 2>/dev/null; blcode=$?
kill "$blk" 2>/dev/null; wait "$blk" 2>/dev/null
assert_eq "$blcode" "0" BL
# ...and the retries are BOUNDED: a notifier that never recovers must not leave
# a watcher polling forever, and the give-up is a durable, visible fact.
BL2="$(NEWHO alertgiveup)"; BL2REC="$BL2.dispatch"
live_json "running"; GOF "$BL2" "watched" >/dev/null 2>&1
live_json "done"
: > "$SHIM_NOTIFY_FAIL"; : > "$CLAUDE_HANDOFF_LOG"
CLAUDE_HANDOFF_NOTIFY_DEBUG= PATH="$tmp/nbin:$PATH" \
  bash "$SCRIPT" --watch "$BL2REC" --poll-sec 1 --heartbeat-min 9999 --watch-gen g-bl2 >/dev/null 2>&1 &
bl2p=$!
await_rec "$BL2REC" "^alert_undelivered_finished_g-bl2=" 400
assert_rec "$BL2REC" "alert_undelivered_finished_g-bl2=.*" BL
assert_rec_missing "$BL2REC" "alerted_finished_g-bl2=1" BL
( sleep 20; kill -9 "$bl2p" 2>/dev/null ) >/dev/null 2>&1 & bl2k=$!
wait "$bl2p" 2>/dev/null; bl2code=$?
kill "$bl2k" 2>/dev/null; wait "$bl2k" 2>/dev/null
assert_eq "$bl2code" "0" BL
# The log line is read AFTER the watcher has exited -- NOT after the record fact
# arrives. The hook writes the record and then the log (`rec_put
# alert_undelivered_$FIN_KEY` then `logline HandoffAlertUndelivered`, adjacent
# lines), so awaiting the record and immediately reading the log is awaiting
# fact X as evidence for fact Y. Under the load of a mutation run that gap
# opened once in ten, and the case failed with no mutation involved. Every
# sibling give-up case (BX, CA, CB, CD) already read the log after `wait`;
# this one alone did not.
assert_contains "HandoffAlertUndelivered" "$(cat "$CLAUDE_HANDOFF_LOG")" BL
rm -f "$SHIM_NOTIFY_FAIL"; : > "$SHIM_NOTIFY_ARGS"
live_json "running"

# ---- BM. the deadline is re-read AFTER the lease is taken ---------------
# The guard and the acquisition are not one step, and the gap is unbounded: the
# retry loop can spin for seconds against a departing incumbent. A lease
# published by a watcher that is already expired says "someone is watching"
# about a process whose very next act is to announce that nobody is (round-4
# lifecycle L8). The crossing has to land BETWEEN the two clock reads the
# watcher makes, so it is pinned to the call index rather than to a sleep: read
# 1 computes the deadline from the base clock, every later read is two hours
# past it. An incumbent holds the lease meanwhile, which is what puts real time
# in the gap the way production would.
BMHO="$(NEWHO expirewhilewaiting)"; BMREC="$BMHO.dispatch"
live_json "running"; GOF "$BMHO" "watched" >/dev/null 2>&1
bmbase="$(date +%s)"
printf '%s\n' "$bmbase" > "$SHIM_NOW"
printf '%s\n' "$(( bmbase + 7200 ))" > "$SHIM_NOW_AFTER"
printf '1\n' > "$SHIM_NOW_AT"; : > "$SHIM_NOW_N"
: > "$BMREC.watch.g-bm"
bmh="$(hold_lock "$BMREC.watch.g-bm" "$tmp/bm.ready")"
assert_held "$BMREC.watch.g-bm" BM
: > "$CLAUDE_HANDOFF_LOG"
PATH="$tmp/nbin:$PATH" CLAUDE_HANDOFF_MAX_HOURS=1 \
  bash "$SCRIPT" --watch "$BMREC" --poll-sec 1 --heartbeat-min 9999 --watch-gen g-bm >/dev/null 2>&1 &
bmp=$!
sleep 0.5                                            # it is spinning on the lease
kill "$bmh" 2>/dev/null || true                      # the incumbent leaves
bmn=0
while ! grep -q 'HandoffWatchExpiredBeforeArming' "$CLAUDE_HANDOFF_LOG" 2>/dev/null && [ "$bmn" -lt 300 ]; do sleep 0.1; bmn=$(( bmn + 1 )); done
assert_contains "HandoffWatchExpiredBeforeArming" "$(cat "$CLAUDE_HANDOFF_LOG")" BM
assert_not_held "$BMREC.watch.g-bm" BM
# ANCHOR: it did acquire and then stand down, rather than never getting in --
# a watcher that loses the lease race for all 30 attempts logs Duplicate and
# writes no expiry at all, which is a different case wearing this one's clothes.
assert_missing "HandoffWatchDuplicate" "$(cat "$CLAUDE_HANDOFF_LOG")" BM
await_rec "$BMREC" '^monitoring_expired=' 300
assert_rec "$BMREC" "monitoring_expired=.*" BM
( sleep 20; kill -9 "$bmp" 2>/dev/null ) >/dev/null 2>&1 & bmk=$!
wait "$bmp" 2>/dev/null; bmcode=$?
kill "$bmk" 2>/dev/null; wait "$bmk" 2>/dev/null
assert_eq "$bmcode" "0" BM
rm -f "$SHIM_NOW" "$SHIM_NOW_AT" "$SHIM_NOW_AFTER" "$SHIM_NOW_N"

# ---- BN. a handoff and a SYMLINK to it are one handoff -------------------
# `cd $(dirname) && pwd -P` resolves every component except the last, so a link
# and its target kept different spellings -- and the record path, the dispatch
# lock and every alert claim are derived from that string. Two names for one
# runbook meant two locks, and the lock is the only thing that makes single
# ownership true: both dispatches won and two paid successors ran the same
# handoff (round-4 correctness C3, reproduced by the reviewer). Identity is the
# FILE now, resolved once, before anything is derived from it.
BNHO="$(NEWHO aliased)"; BNLINK="$tmp/work/HANDOFF-aliased-link.md"
ln -sf "$BNHO" "$BNLINK"; rm -f "$BNLINK.dispatch" "$BNLINK.dispatch".*
live_json "running"; : > "$SHIM_SPAWNS"
out="$(GOF "$BNLINK" "through the link" 2>&1)"; code=$?
assert_eq "$code" "0" BN
assert_file "$BNHO.dispatch" BN
assert_no_file "$BNLINK.dispatch" BN
assert_file "$BNHO.dispatch.flock" BN
assert_no_file "$BNLINK.dispatch.flock" BN
# ...so a second dispatch under the TARGET's own name meets the first one's
# record and refuses, instead of paying for a second successor.
out="$(GOF "$BNHO" "through the target" 2>&1)"; code=$?
assert_eq "$code" "2" BN
assert_contains "a live successor" "$out" BN
assert_eq "$(grep -c '^spawn$' "$SHIM_SPAWNS")" "1" BN

# ---- BO. the handoff must still be THERE at the irreversible step ---------
# Every check on the handoff file happened before the claim and before the
# record write. In that window it can be removed or REPLACED, and the last fence
# looked only at the lock -- so a successor was dispatched, verified and paid
# for with its only context gone (round-4 correctness C4). The agents read is
# the seam because it is the last point that is provably still pre-launch.
BOHO="$(NEWHO vanish)"; BOREC="$BOHO.dispatch"
: > "$SHIM_SPAWNS"
live_json "running"
printf 'state=verified\nsession_id=99999999\n' > "$BOREC"   # a PREV nobody lists
printf '%s' "$BOHO" > "$SHIM_HO_REMOVE"
out="$(GOF "$BOHO" "vanishing" 2>&1)"; code=$?
assert_eq "$code" "2" BO
assert_contains "was removed, emptied or made unreadable" "$out" BO
assert_eq "$(grep -c '^spawn$' "$SHIM_SPAWNS")" "0" BO
# A REPLACEMENT passes -f/-r/-s and is still the wrong file: identity, not
# predicates, is what the successor's context depends on.
printf '# Handoff\n\nDo vanish.\n' > "$BOHO"
printf 'state=verified\nsession_id=99999999\n' > "$BOREC"
printf '%s' "$BOHO" > "$SHIM_HO_REPLACE"
out="$(GOF "$BOHO" "replaced" 2>&1)"; code=$?
assert_eq "$code" "2" BO
assert_contains "was REPLACED after it was checked" "$out" BO
assert_eq "$(grep -c '^spawn$' "$SHIM_SPAWNS")" "0" BO
# ANCHOR: the identical dispatch with nothing touching the file DOES spawn, so
# the two refusals above are about the file changing under it and not about a
# fixture that can never dispatch at all.
printf 'state=verified\nsession_id=99999999\n' > "$BOREC"
out="$(GOF "$BOHO" "untouched" 2>&1)"; code=$?
assert_eq "$code" "0" BO
assert_eq "$(grep -c '^spawn$' "$SHIM_SPAWNS")" "1" BO

# ---- BP. a record value can never become a node OPTION -------------------
# `--watch` accepts any readable record, so every value in it is untrusted
# input. The session id was appended straight after `node -e <script>`, and node
# parses options anywhere before the first non-option argument: a record
# carrying `session_id=--require=/tmp/x.js` PRELOADED and executed that module
# on every poll, twice per poll, while the watcher exited 0 (round-4 correctness
# C5, reproduced by the reviewer). `--` terminates the options, so a value can
# only ever be data.
BPHO="$(NEWHO nodeopt)"; BPREC="$BPHO.dispatch"
export SHIM_PRELOAD_MARK="$tmp/preloaded.txt"
cat > "$tmp/preload.js" <<'PJS'
require("fs").writeFileSync(process.env.SHIM_PRELOAD_MARK, "loaded\n");
PJS
rm -f "$SHIM_PRELOAD_MARK"
printf 'state=verified\nsession_id=--require=%s\n' "$tmp/preload.js" > "$BPREC"
live_json "running"
out="$(bash "$SCRIPT" --watch-once "$BPREC" 2>&1)"; code=$?
assert_eq "$code" "0" BP
assert_no_file "$SHIM_PRELOAD_MARK" BP
# ANCHOR: the value DID reach node, as data -- the list was read and answered
# "no such row", which is the only reason the argument is passed at all. Without
# this the case would pass against a watcher that never called node.
assert_rec "$BPREC" "finished=1" BP

# ---- BQ. an alert marker ends with its EPISODE, not with the record -------
# The markers were keyed by condition for the record's whole life, and `rec_has`
# matched the key ANYWHERE in the file, so every condition was announced at most
# once ever: a successor that blocked, was attended to and blocked again went
# unreported the second time (round-4 correctness C6). Last write wins now, and
# the poll that observes the condition clear ends the episode.
BQHO="$(NEWHO episodes)"; BQREC="$BQHO.dispatch"
live_json "running"; GOF "$BQHO" "episodic" >/dev/null 2>&1
printf 'watch_gen=g-bq\n' >> "$BQREC"
live_json "blocked"
out="$(bash "$SCRIPT" --watch-once "$BQREC" --watch-gen g-bq 2>&1)"
assert_contains "is blocked and needs input" "$out" BQ
assert_rec "$BQREC" "alerted_blocked=1" BQ
live_json "running"
out="$(bash "$SCRIPT" --watch-once "$BQREC" --watch-gen g-bq 2>&1)"
assert_missing "is blocked and needs input" "$out" BQ
assert_rec "$BQREC" "alerted_blocked=0" BQ
live_json "blocked"
out="$(bash "$SCRIPT" --watch-once "$BQREC" --watch-gen g-bq 2>&1)"
assert_contains "is blocked and needs input" "$out" BQ
# ...and the same for EXPIRY, which the same finding named and which needed the
# other half of the cure: an expired watchdog is replaced by a re-armed one with
# a NEW generation, so the expiry fact is generation-scoped like the terminal
# fact. Keyed to the record, "nobody is watching this successor" was announced
# once per record, ever.
BQ2="$(NEWHO episodes2)"; BQ2REC="$BQ2.dispatch"
live_json "running"; GOF "$BQ2" "expiring twice" >/dev/null 2>&1
: > "$SHIM_NOTIFY_ARGS"
PATH="$tmp/nbin:$PATH" CLAUDE_HANDOFF_MAX_HOURS=0 CLAUDE_HANDOFF_NOTIFY_DEBUG= \
  bash "$SCRIPT" --watch "$BQ2REC" --poll-sec 1 --watch-gen g-bq1 >/dev/null 2>&1
assert_eq "$(grep -c 'EXPIRED after' "$SHIM_NOTIFY_ARGS")" "1" BQ
PATH="$tmp/nbin:$PATH" CLAUDE_HANDOFF_MAX_HOURS=0 CLAUDE_HANDOFF_NOTIFY_DEBUG= \
  bash "$SCRIPT" --watch "$BQ2REC" --poll-sec 1 --watch-gen g-bq2 >/dev/null 2>&1
assert_eq "$(grep -c 'EXPIRED after' "$SHIM_NOTIFY_ARGS")" "2" BQ
: > "$SHIM_NOTIFY_ARGS"
live_json "running"

# ---- BR. a symlink that cannot be READ is a degraded read, never "not a link"
# `[ -L ]` has already said the path IS a symlink, so a readlink that fails is an
# unreadable link. The loop used to `break` on it and walk on with the LINK's own
# spelling -- which is the two-identities-for-one-handoff bug the resolution loop
# exists to close (C3): the record path, the dispatch lock and every alert claim
# would be derived from the alias while another dispatch derived them from the
# target, and both would win their claim. Driven by replacing the link with a
# regular file at the instant readlink is called, exactly as a racing process
# would.
BRT="$tmp/work/HANDOFF-brtarget.md"; BRA="$tmp/work/HANDOFF-bralias.md"
printf '# Handoff\n\nThe real one.\n' > "$BRT"
rm -f "$BRA" "$BRA.dispatch" "$BRA.dispatch".* "$BRT.dispatch" "$BRT.dispatch".*
ln -sf "$BRT" "$BRA"
mkdir -p "$tmp/rlbin"
# Matched by BASENAME. $tmp lives under /var, which the script resolves to
# /private/var BEFORE it ever calls readlink, so an equality test against the
# path the test spelled never fires and the shim silently defers to the real
# tool -- a control that cannot fail.
# Matched on the LAST argument, which is the path on every readlink dialect.
# Matching `$1` worked only while the caller passed the path first: adding the
# `-n` the byte-exact read needs made `$1` the FLAG, so the shim stopped matching,
# deferred to the real tool, and the case passed while testing nothing. A control
# whose reach depends on the caller's argument ORDER is one option away from
# being no control at all -- the same class as BR's own `env` note below.
cat > "$tmp/rlbin/readlink" <<'RLSH'
#!/bin/sh
for _a in "$@"; do _p="$_a"; done
case "$_p" in
  */"$BR_ALIAS_BASE")
    rm -f "$_p"; printf '# a plain file now\n\nnot the real handoff\n' > "$_p"
    exit 1 ;;
esac
exec /usr/bin/readlink "$@"
RLSH
chmod +x "$tmp/rlbin/readlink"
rm -f "$SHIM_SPAWNS"; live_json "running"
# `env`, not a prefix on GOF: a variable assignment preceding a FUNCTION call is
# a shell variable, and BR_ALIAS was never exported -- so the shim read it empty,
# fell through to the real readlink, and the case silently tested nothing.
out="$(env BR_ALIAS_BASE="$(basename "$BRA")" PATH="$tmp/rlbin:$PATH" bash "$SCRIPT" "$BRA" "aliased" --cwd "$tmp/work" 2>&1)"; code=$?
[ "$code" != "0" ] || { echo "FAIL[BR]: an unreadable symlink must refuse to dispatch"; fail=1; }
assert_contains "cannot read the symlink" "$out" BR
assert_no_file "$SHIM_SPAWNS" BR
# The point of the case: no SECOND identity is created for this handoff.
assert_no_file "$BRA.dispatch" BR
assert_no_file "$BRA.dispatch.flock" BR
# ...and the shim provably ran: it leaves a REGULAR FILE where the link was.
# Without this the case reports success when the seam has stopped reaching.
{ [ -f "$BRA" ] && [ ! -L "$BRA" ]; } || { echo "FAIL[BR]: the readlink shim never fired, so this case asserts nothing"; fail=1; }

# ---- BS. an unreadable IDENTITY at the dispatch boundary fails CLOSED -----
# The boundary re-check was `[ -n "$_ino0" ] && [ -n "$_ino1" ] && [ "$_ino0" !=
# "$_ino1" ]`, so a stat that did not answer read as "unchanged" and the
# successor was paid for anyway -- a degraded observation used as a value, at the
# one site whose next step is irreversible. The seam is `stat` itself, because
# nothing calls `claude` between the two identity reads: file_ident tries
# `stat -c` then `stat -f`, so calls 1-2 are the pre-record read and 3-4 the
# boundary one.
BSHO="$(NEWHO boundaryident)"
mkdir -p "$tmp/stbin"
cat > "$tmp/stbin/stat" <<'STSH'
#!/bin/sh
for a in "$@"; do          # matched by BASENAME, for the reason BR's shim gives
  case "$a" in
    */"$BS_BASE")
      n=$(( $(cat "$BS_CNT") + 1 )); printf '%s' "$n" > "$BS_CNT"
      if [ "$n" -ge 3 ]; then
        printf '# a DIFFERENT file at the same path\n\nSomething else.\n' > "$a.new"
        rm -f "$a"; mv "$a.new" "$a"
        exit 1
      fi ;;
  esac
done
exec /usr/bin/stat "$@"
STSH
chmod +x "$tmp/stbin/stat"
printf '0' > "$tmp/bs-cnt"
rm -f "$SHIM_SPAWNS"; live_json "running"
out="$(env BS_BASE="$(basename "$BSHO")" BS_CNT="$tmp/bs-cnt" PATH="$tmp/stbin:$PATH" bash "$SCRIPT" "$BSHO" "boundary" --cwd "$tmp/work" 2>&1)"; code=$?
[ "$code" != "0" ] || { echo "FAIL[BS]: an unreadable identity at the boundary must refuse"; fail=1; }
assert_contains "cannot establish the identity" "$out" BS
assert_no_file "$SHIM_SPAWNS" BS
# ...and the record says WHICH kind of refusal it was: this one died before the
# launcher, so a plain retry is safe. `launching` would refuse it forever (case
# CY drives that retry).
assert_rec_last "$BSHO.dispatch" state prelaunch_failed BS
[ "$(cat "$tmp/bs-cnt")" -ge 3 ] || { echo "FAIL[BS]: the boundary identity read was never reached, so this case asserts nothing"; fail=1; }

# ---- BT. a degraded-filesystem alert is an EPISODE with two ends ----------
# `rec_clear alerted_fsdegraded` sat ABOVE the probe that sets it, so it fired on
# every poll BEFORE the condition was observed: a filesystem that stayed hung
# re-alerted on each cycle (alert_once degraded to alert_always) and the clear
# never encoded recovery from anything. The four polls below are the whole
# contract: alert once, stay silent while it persists, clear on recovery, alert
# again on the next outage.
BTHO="$(NEWHO fsepisodes)"; BTREC="$BTHO.dispatch"
live_json "running"; GOF "$BTHO" "fs episodes" >/dev/null 2>&1
: > "$transcript"
mkdir -p "$tmp/hangbin"
cat > "$tmp/hangbin/stat" <<'HSH'
#!/bin/sh
[ -f "$BT_HANG" ] && sleep 30
exec /usr/bin/stat "$@"
HSH
chmod +x "$tmp/hangbin/stat"
BTP() { env BT_HANG="$tmp/bt-hang" PATH="$tmp/hangbin:$PATH" CLAUDE_HANDOFF_FS_TIMEOUT=1 \
          bash "$SCRIPT" --watch-once "$BTREC" 2>&1; }
: > "$tmp/bt-hang"
o1="$(BTP)"; assert_contains "cannot stat" "$o1" BT
o2="$(BTP)"; assert_missing "cannot stat" "$o2" BT   # the episode is ONE alert
rm -f "$tmp/bt-hang"
o3="$(BTP)"; assert_missing "cannot stat" "$o3" BT
assert_rec_last "$BTREC" alerted_beatdegraded 0 BT   # recovery CLEARED it
: > "$tmp/bt-hang"
o4="$(BTP)"; assert_contains "cannot stat" "$o4" BT  # a NEW outage is announced
rm -f "$tmp/bt-hang"

# ---- BU. "no session id" is an episode too --------------------------------
# `dispatch` writes session_id AFTER the launch returns, so a watcher armed in
# that window legitimately sees the field missing for a poll or two. With no
# clearing site the one alert it sent was the only one that record could ever
# send about a missing id -- including for a LATER truncation that really did
# lose it.
# Startup validation REFUSES a record that never named a session -- there is
# nothing to watch -- so the poll-time alert is reachable only when the id is
# lost mid-flight, which is what a `--force` re-dispatch's truncation window
# looks like from inside a watcher that is already running.
BUHO="$(NEWHO nosess)"; BUREC="$BUHO.dispatch"
live_json "running"; GOF "$BUHO" "no session" >/dev/null 2>&1
# `--watch-once` REFUSES a record with no session id at STARTUP -- there is
# nothing to watch, and that is deliberately a hard error -- so the poll-time
# alert is reachable only from the LOOP, where the id goes missing mid-flight.
# Driving it with a hand-built idless record would have tested the startup
# refusal instead, and passed while the alert stayed dead.
CLAUDE_HANDOFF_MAX_HOURS=1 bash "$SCRIPT" --watch "$BUREC" --watch-gen bugen --poll-sec 1 >/dev/null 2>&1 &
buw=$!
bun=0
while [ "$bun" -lt 100 ]; do lock_is_held "$BUREC.watch.bugen"; [ "$?" = 0 ] && break; sleep 0.1; bun=$(( bun + 1 )); done
assert_held "$BUREC.watch.bugen" BU
printf 'session_id=\n' >> "$BUREC"                  # the id goes missing
await_rec_last "$BUREC" alerted_no_session 1 100 BU
# The marker transition says an episode OPENED; it says nothing about what the
# operator was actually handed. So assert the DELIVERED text -- and build the
# expectation by EXTRACTING the template from the hook, not by retyping it here:
# a retyped literal is a control that cannot fail, since a message the product
# stopped printing would have to be deleted from the test by hand before the
# test noticed.
#   WHAT THIS EQUALITY DOES AND DOES NOT PROVE. It proves the message was
# delivered at all and that its variables expanded -- and NOTHING about the
# WORDS, because the expectation is extracted from the very line a mutation
# would edit: rename the recovery command to `--stats` and BU_TMPL renames with
# it, so both sides move together and this assertion still passes. That is
# reproduced, not theorised: this case passed on that exact mutant (round 6
# micro-review), while the comment here claimed it was the cure. The claim is
# earned below instead, from the one operand the product cannot move: the
# PARSER's own answer to the flag it just told the operator to run.
BU_TMPL="$(awk -F'no_session "' '/alert_once "\$REC" no_session "/{s=$2; sub(/"$/,"",s); print s; exit}' "$SCRIPT")"
[ -n "$BU_TMPL" ] || { echo "FAIL[BU]: the no_session alert template could not be extracted from $SCRIPT -- this assertion would pass against nothing"; fail=1; }
# `_rb` is the record's basename (hooks/handoff.sh: _rb="${REC##*/}"), and the
# backticks around the recovery command are escaped in the source string.
BU_MSG="$(printf '%s' "$BU_TMPL" | sed -e 's/\\`/`/g' -e "s|\\\$_rb|${BUREC##*/}|g")"
case "$BU_MSG" in *'$'*) echo "FAIL[BU]: the expected message still carries an unexpanded variable: $BU_MSG"; fail=1 ;; esac
# Read from the shared event log, not from the watcher's stdout: `watch_loop`
# runs `watch_once "$REC" >/dev/null 2>&1`, so the NOTIFY test seam is discarded
# on the LOOP path and only the `logline` copy survives -- which is the same
# `$1` the delivery backend is handed.
BU_EXPECT="{\"hook_event_name\":\"HandoffWatch\",\"message\":\"$BU_MSG\"}"
bun=0
while [ "$bun" -lt 150 ]; do grep -qF "$BU_EXPECT" "$CLAUDE_HANDOFF_LOG" && break; sleep 0.1; bun=$(( bun + 1 )); done
if ! grep -qF "$BU_EXPECT" "$CLAUDE_HANDOFF_LOG"; then
  echo "FAIL[BU]: the delivered no_session message is not the one the hook's own alert line spells."
  echo "  expected: $BU_EXPECT"
  echo "  logged  : $(grep -F 'has no session id' "$CLAUDE_HANDOFF_LOG" | tail -1)"
  fail=1
fi
# THE FLAG COMES OUT OF THE DELIVERED TEXT, not out of the source, and goes
# through the real parser, AND is then made to ANSWER THE QUESTION THE ALERT
# ASKS. The parser check alone is satisfied by any flag the parser happens to
# accept: renaming the recovery command to `--help` kept this case AND DJ green
# while handing an operator chasing a possibly-unwatched successor a usage
# header instead of that successor's state (round 6 micro-review 2, reproduced
# -- `bash hooks/handoff.sh --help` prints the header and exits 0). "The parser
# does not reject it" is not the property an operator needs; "it tells me about
# my successor" is. So the command is run and its output must NAME THE SESSION
# the alert is about -- the one operand a rename cannot carry with it, because
# it comes from the dispatch under watch and not from the message.
BU_LOGGED="$(grep -F 'has no session id' "$CLAUDE_HANDOFF_LOG" | tail -1)"
BU_FLAG="$(printf '%s' "$BU_LOGGED" | sed -n 's|.*handoff\.sh \(--[a-z][a-z-]*\).*|\1|p' | head -1)"
[ -n "$BU_FLAG" ] || { echo "FAIL[BU]: the delivered alert names no \`handoff.sh --<flag>\` for the operator to run -- got: $BU_LOGGED"; fail=1; }
if [ -n "$BU_FLAG" ]; then
  BU_PARSE="$(cd "$tmp" && bash "$SCRIPT" "$BU_FLAG" 2>&1)"
  case "$BU_PARSE" in
    *"unknown option: $BU_FLAG"*)
      echo "FAIL[BU]: the delivered alert tells the operator to run \`handoff.sh $BU_FLAG\`, and the hook's own parser answers: $BU_PARSE"; fail=1 ;;
  esac
  [ -n "$SHORT" ] || { echo "FAIL[BU]: the agents fixture carries no session id, so the answer check below would compare against an empty needle and could not fail"; fail=1; }
  case "$BU_PARSE" in
    *"$SHORT"*) ;;
    *) echo "FAIL[BU]: the delivered alert tells the operator to run \`handoff.sh $BU_FLAG\` to check on a successor that may be running unwatched, but that command never names session $SHORT -- so the recovery step does not answer the question the alert asks. got: $BU_PARSE"; fail=1 ;;
  esac
fi
printf 'session_id=%s\n' "$SHORT" >> "$BUREC"       # ...and comes back
await_rec_last "$BUREC" alerted_no_session 0 100 BU  # the episode is OVER
printf 'session_id=\n' >> "$BUREC"                  # a SECOND episode is its own
await_rec_last "$BUREC" alerted_no_session 1 100 BU
kill "$buw" 2>/dev/null; wait "$buw" 2>/dev/null || true

# ---- BV. an unpublishable lease is scoped to the WATCHER, not the record --
# The lease is taken once, at the top of a watcher's life, and never retried, so
# there is no recovery transition a clearing site could hang on. A flat
# `leasedegraded` key therefore reported the FIRST watcher that could not publish
# one and silenced every later one -- across re-dispatches, for the life of the
# record. Two watchers, two generations, two reports.
BVHO="$(NEWHO leasescope)"; BVREC="$BVHO.dispatch"
live_json "running"; GOF "$BVHO" "lease scope" >/dev/null 2>&1
# A real poll loop, because the lease is taken at the TOP of a watcher's life and
# only while there is still time on the deadline -- a zero-hour watcher skips the
# lease block entirely and proves nothing about it.
BVP() { # $1=generation
  # Backgrounded DIRECTLY, not wrapped in a subshell: killing a subshell does
  # not kill the bash it is running, and this watcher publishes no lease and no
  # watch_pid line, so $! is the only handle on it that exists.
  env CLAUDE_HANDOFF_LOCK_DEBUG=broken:8 CLAUDE_HANDOFF_MAX_HOURS=1 \
      bash "$SCRIPT" --watch "$BVREC" --poll-sec 1 --watch-gen "$1" >/dev/null 2>&1 &
  local bvp=$!
  await_rec "$BVREC" "^alerted_leasedegraded_$1=1\$" 300 \
    || { echo "FAIL[BV]: watcher $1 never reported an unpublishable lease"; fail=1; }
  kill "$bvp" 2>/dev/null || true
  wait "$bvp" 2>/dev/null || true
}
BVP g-bv1
BVP g-bv2
# BOTH of them, which is the case: a flat `leasedegraded` key reported the first
# watcher that could not publish a lease and silenced every later one.
assert_rec "$BVREC" "alerted_leasedegraded_g-bv1=1" BV
assert_rec "$BVREC" "alerted_leasedegraded_g-bv2=1" BV
assert_rec_missing "$BVREC" "alerted_leasedegraded=1" BV

# ---- BW. the reconcile alerts have ends as well ---------------------------
# `reconcile_watch` is the only site that re-arms a live-but-unwatched successor,
# and BOTH of the conditions it reports were record-scoped one-shots: the first
# unreadable liveness probe on a record made every later one silent, and a
# transient arm failure left `watch_failed=1` and `alerted_rearm_failed=1` in the
# record describing a watchdog that is, by then, running.
BWHO="$(NEWHO reconcile)"; BWREC="$BWHO.dispatch"
live_json "running" "$tmp/work" "background"
# ARM=1 on the FIRST dispatch, because `watch_is_alive` answers "no watcher"
# without probing anything when the record carries no generation -- and a case
# that never reaches the probe cannot say anything about a probe that fails.
CLAUDE_HANDOFF_ARM=1 CLAUDE_HANDOFF_MAX_HOURS=1 GOF "$BWHO" "reconcile" >/dev/null 2>&1
bwgen="$(sed -n 's/^watch_gen=//p' "$BWREC" | tail -1)"
[ -n "$bwgen" ] || { echo "FAIL[BW]: the first dispatch armed nothing, so there is no watcher to reconcile"; fail=1; }
# The incumbent has to be provably GONE: a watcher still holding its lease reads
# as ALIVE, reconcile_watch returns before the code under test, and every
# assertion below asserts nothing.
retire_watchers "$BWREC"
lock_is_held "$BWREC.watch.$bwgen"; [ "$?" = 1 ] || { echo "FAIL[BW]: the first watcher still holds its lease, so the reconcile path is unreachable"; fail=1; }
BWU() { # re-dispatch through the reconcile path; $@ = env assignments
  printf 'state=unknown\n' >> "$BWREC"      # the state that routes to reconcile_watch
  env "$@" bash "$SCRIPT" "$BWHO" "again" --cwd "$tmp/work" 2>&1
}
# (a) an unreadable watcher-liveness probe: announced, then silent while it
#     persists, then cleared when the probe answers -- and the clear must happen
#     on the poll where the watcher is DEAD too, which is the path that skips
#     the alive branch entirely.
w1="$(BWU CLAUDE_HANDOFF_LOCK_DEBUG=broken:8 CLAUDE_HANDOFF_ARM=1 CLAUDE_HANDOFF_MAX_HOURS=0)"
assert_contains "cannot tell whether" "$w1" BW
w2="$(BWU CLAUDE_HANDOFF_LOCK_DEBUG=broken:8 CLAUDE_HANDOFF_ARM=1 CLAUDE_HANDOFF_MAX_HOURS=0)"
assert_missing "cannot tell whether" "$w2" BW
# (b) the probe answers and the watcher is gone: re-arming is attempted, and a
#     zero-hour deadline makes it FAIL. That same run must end the (a) episode.
w3="$(BWU CLAUDE_HANDOFF_ARM=1 CLAUDE_HANDOFF_MAX_HOURS=0)"
assert_contains "re-arming the watchdog FAILED" "$w3" BW
assert_rec_last "$BWREC" alerted_watchunknown 0 BW
assert_rec_last "$BWREC" watch_failed 1 BW
# (c) a re-arm that works ends the failure episode -- marker AND durable flag.
w4="$(BWU CLAUDE_HANDOFF_ARM=1 CLAUDE_HANDOFF_MAX_HOURS=1)"
assert_missing "re-arming the watchdog FAILED" "$w4" BW
assert_rec_last "$BWREC" alerted_rearm_failed 0 BW
assert_rec_last "$BWREC" watch_failed 0 BW
retire_watchers "$BWREC"
live_json "running"

# ---- BX. the retry budget is spent on ATTEMPTS, not on polls --------------
# `watch_once` reaches the terminal alert only on a poll whose
# `claude agents --json` SUCCEEDED. The loop used to increment the retry budget
# on every poll that saw the terminal FACT, so a degraded agent query burned all
# ten retries without calling the notifier once, and the watcher exited having
# written `alert_undelivered` after a SINGLE real delivery attempt -- "nobody
# could be told" reported without having tried, which is the same silent finish
# the retry exists to prevent (round-4 micro L6).
rm -f "$SHIM_AGENTS_FAIL"
BXHO="$(NEWHO alertbudget)"; BXREC="$BXHO.dispatch"
live_json "running"; GOF "$BXHO" "watched" >/dev/null 2>&1
# ONE REAL POLL puts the terminal fact on disk with its alert undelivered.
# Hand-writing that record would have proved nothing about whether a watcher can
# produce the state the retry is supposed to recover from.
live_json "done"
CLAUDE_HANDOFF_NOTIFY_DEBUG=fail \
  bash "$SCRIPT" --watch-once "$BXREC" --watch-gen g-bx >/dev/null 2>&1
assert_rec "$BXREC" "finished_g-bx=1" BX
assert_rec "$BXREC" "finished_g-bx_how=done" BX
assert_rec_missing "$BXREC" "alerted_finished_g-bx=1" BX
# From here the agent query is DEAD, so every poll returns from watch_once far
# above its terminal branch: any further delivery attempt can only come from the
# loop itself.
: > "$SHIM_AGENTS_FAIL"
# Cleared, because the log ACCUMULATES across cases and BL2 already wrote this
# very line: asserting it against a shared log is an assertion that cannot fail.
: > "$CLAUDE_HANDOFF_LOG"
CLAUDE_HANDOFF_NOTIFY_DEBUG=fail \
  bash "$SCRIPT" --watch "$BXREC" --poll-sec 1 --heartbeat-min 9999 --watch-gen g-bx \
  >"$tmp/bx.out" 2>&1 &
bxp=$!
await_rec "$BXREC" "^alert_undelivered_finished_g-bx=" 600
rm -f "$SHIM_AGENTS_FAIL"
( sleep 20; kill -9 "$bxp" 2>/dev/null ) >/dev/null 2>&1 & bxk=$!
wait "$bxp" 2>/dev/null; bxcode=$?
kill "$bxk" 2>/dev/null; wait "$bxk" 2>/dev/null
assert_eq "$bxcode" "0" BX
# The number is the whole point: the budget is ten, and giving up is only honest
# after ten ATTEMPTS. Counting polls made this 1.
bxn="$(grep -c "NOTIFY: successor .* finished" "$tmp/bx.out" 2>/dev/null || true)"
# EXACTLY ten, not "at least ten": `-ge` accepted ALERT_RETRY_MAX=11, and the
# whole point of this case is that the number is the contract (round-5 tests #4).
[ "${bxn:-0}" = 10 ] || { echo "FAIL[BX]: made ${bxn:-0} delivery attempts, expected exactly 10 -- the budget is ten ATTEMPTS, spent neither on polls that never called the notifier nor on an eleventh try"; fail=1; }
assert_rec_missing "$BXREC" "alerted_finished_g-bx=1" BX
assert_contains "HandoffAlertUndelivered" "$(cat "$CLAUDE_HANDOFF_LOG")" BX
live_json "running"

# ---- BY. a stand-down is not a failed delivery ----------------------------
# `skipped` means no delivery was ATTEMPTED -- here because another claimant
# holds this alert and is delivering it right now. Charging that to the retry
# budget makes a watcher give up on somebody ELSE's in-flight delivery and
# announce `alert_undelivered` about an alert it never even tried to send
# (round-4 micro L6, the other half of "spend the budget on attempts").
rm -f "$SHIM_AGENTS_FAIL"
BYHO="$(NEWHO alertstanddown)"; BYREC="$BYHO.dispatch"
live_json "running"; GOF "$BYHO" "watched" >/dev/null 2>&1
live_json "done"
CLAUDE_HANDOFF_NOTIFY_DEBUG=fail \
  bash "$SCRIPT" --watch-once "$BYREC" --watch-gen g-by >/dev/null 2>&1
assert_rec "$BYREC" "finished_g-by=1" BY
assert_rec_missing "$BYREC" "alerted_finished_g-by=1" BY
# A third party holds THIS alert's claim for the whole case, so every attempt
# the watcher makes stands down before it reaches the notifier.
byh="$(hold_lock "$BYREC.alert.finished_g-by.flock" "$tmp/by.ready")"
assert_held "$BYREC.alert.finished_g-by.flock" BY
: > "$SHIM_AGENTS_FAIL"
CLAUDE_HANDOFF_NOTIFY_DEBUG=fail \
  bash "$SCRIPT" --watch "$BYREC" --poll-sec 1 --heartbeat-min 9999 --watch-gen g-by \
  >"$tmp/by.out" 2>&1 &
byp=$!
# Fifteen polls against a ten-retry budget: if stand-downs were counted, the
# give-up would be on disk and the watcher would have EXITED by now. Both are
# asserted, because the record alone cannot tell "not yet" from "never".
sleep 15
assert_rec_missing "$BYREC" "alert_undelivered_finished_g-by=.*" BY
kill -0 "$byp" 2>/dev/null || { echo "FAIL[BY]: the watcher exited while another claimant was still delivering the alert"; fail=1; }
kill "$byp" 2>/dev/null; wait "$byp" 2>/dev/null || true
kill "$byh" 2>/dev/null; wait "$byh" 2>/dev/null || true
rm -f "$SHIM_AGENTS_FAIL"
live_json "running"

# ---- CA. a claim that cannot be ESTABLISHED is not a stand-down -----------
# BY proved a stand-down must not spend the budget. That cure was too wide:
# `alert_once` reported `skipped` for BOTH "another claimant is delivering this
# right now" (lock_hold 1) and "the claim could not be established at all"
# (lock_hold 2 -- an unopenable path or a lock backend that cannot answer). The
# second is not somebody else's in-flight delivery; it is OUR failed
# prerequisite, and reporting it as a stand-down made the terminal retry
# unbounded: `_fd` never advanced, no `alert_undelivered_finished_<gen>` was
# ever written, and the watcher held its lease to the full deadline while the
# finish went unannounced. lock_hold's own contract says callers must never
# collapse 1 and 2; this is the caller that did (round-5 lifecycle #12).
rm -f "$SHIM_AGENTS_FAIL"
CAHO="$(NEWHO claimunavailable)"; CAREC="$CAHO.dispatch"
live_json "running"; GOF "$CAHO" "unopenable claim" >/dev/null 2>&1
live_json "done"
CLAUDE_HANDOFF_NOTIFY_DEBUG=fail \
  bash "$SCRIPT" --watch-once "$CAREC" --watch-gen g-ca >/dev/null 2>&1
assert_rec "$CAREC" "finished_g-ca=1" CA
assert_rec_missing "$CAREC" "alerted_finished_g-ca=1" CA
: > "$SHIM_AGENTS_FAIL"
: > "$CLAUDE_HANDOFF_LOG"
# MAX_HOURS=1 puts the deadline an hour away, so a give-up inside the next
# minute can only have come from the retry BUDGET -- never from expiry.
CLAUDE_HANDOFF_LOCK_DEBUG=broken:7 CLAUDE_HANDOFF_MAX_HOURS=1 \
CLAUDE_HANDOFF_NOTIFY_DEBUG=fail \
  bash "$SCRIPT" --watch "$CAREC" --poll-sec 1 --heartbeat-min 9999 --watch-gen g-ca \
  >"$tmp/ca.out" 2>&1 &
cap=$!
await_rec "$CAREC" "^alert_undelivered_finished_g-ca=" 600
( sleep 20; kill -9 "$cap" 2>/dev/null ) >/dev/null 2>&1 & cak=$!
wait "$cap" 2>/dev/null; cacode=$?
kill "$cak" 2>/dev/null; wait "$cak" 2>/dev/null
assert_eq "$cacode" "0" CA
assert_rec "$CAREC" "alert_undelivered_finished_g-ca=.*" CA
assert_rec_missing "$CAREC" "alerted_finished_g-ca=1" CA
assert_contains "HandoffAlertUndelivered" "$(cat "$CLAUDE_HANDOFF_LOG")" CA
# ZERO, not "at most ten": the claim was never established, so the notifier can
# never have run. This is what separates CA from BX -- BX gives up after ten
# real attempts, CA after ten attempts that could not even begin.
can="$(grep -c "NOTIFY: successor" "$tmp/ca.out" 2>/dev/null || true)"
assert_eq "${can:-x}" "0" CA
rm -f "$SHIM_AGENTS_FAIL"
live_json "running"

# ---- CB. the EXPIRY alert has a retry budget, and it is ten --------------
# BQ exercised expiry only with a notifier that succeeded on the first call, so
# nothing pinned what happens when it does not: initialising `_xn` one short of
# the budget, or deleting the durable `alert_undelivered_expired_<gen>` write,
# both survived the whole suite (round-5 tests #0). An expired watchdog over a
# LIVE successor is the one moment the script exists to report; a give-up here
# has to be both bounded and on disk.
CBHO="$(NEWHO expirybudget)"; CBREC="$CBHO.dispatch"
live_json "running"; GOF "$CBHO" "expiry retries" >/dev/null 2>&1
: > "$CLAUDE_HANDOFF_LOG"
# Backgrounded with a hard kill, because the failure mode under test is a budget
# that never advances -- run in the foreground, a regression would HANG this
# suite rather than fail it, and a control that hangs reports nothing.
CLAUDE_HANDOFF_MAX_HOURS=0 CLAUDE_HANDOFF_NOTIFY_DEBUG=fail \
  bash "$SCRIPT" --watch "$CBREC" --poll-sec 1 --watch-gen g-cb >"$tmp/cb.out" 2>&1 &
cbp=$!
( sleep "$WATCH_HANG_GUARD"; kill -9 "$cbp" 2>/dev/null ) >/dev/null 2>&1 & cbk=$!
wait "$cbp" 2>/dev/null; cbcode=$?
kill "$cbk" 2>/dev/null; wait "$cbk" 2>/dev/null
assert_eq "$cbcode" "0" CB
cbn="$(grep -c "EXPIRED after" "$tmp/cb.out" 2>/dev/null || true)"
assert_eq "${cbn:-x}" "10" CB
assert_rec "$CBREC" "alert_undelivered_expired_g-cb=.*" CB
assert_rec_missing "$CBREC" "alerted_expired_g-cb=1" CB
assert_contains "HandoffAlertUndelivered" "$(cat "$CLAUDE_HANDOFF_LOG")" CB

# ---- CC. a held EXPIRY claim must not spend that budget either -----------
# The same rule as BY, at the second bounded-retry site. The expiry loop counted
# POLLS: ten polls while another claimant held the expiry alert produced zero
# delivery attempts, yet wrote `alert_undelivered_expired_<gen>` and exited --
# announcing "nobody could be told" about an alert somebody else was at that
# moment telling, and abandoning a live successor to do it (round-5 correctness
# #5 / lifecycle #13).
CCHO="$(NEWHO expirystanddown)"; CCREC="$CCHO.dispatch"
live_json "running"; GOF "$CCHO" "expiry stand-down" >/dev/null 2>&1
cch="$(hold_lock "$CCREC.alert.expired_g-cc.flock" "$tmp/cc.ready")"
assert_held "$CCREC.alert.expired_g-cc.flock" CC
CLAUDE_HANDOFF_MAX_HOURS=0 CLAUDE_HANDOFF_NOTIFY_DEBUG=fail \
  bash "$SCRIPT" --watch "$CCREC" --poll-sec 1 --watch-gen g-cc >"$tmp/cc.out" 2>&1 &
ccp=$!
# Fifteen polls against a ten-retry budget, and both halves asserted: the record
# alone cannot tell "not yet" from "never".
sleep 15
assert_rec_missing "$CCREC" "alert_undelivered_expired_g-cc=.*" CC
kill -0 "$ccp" 2>/dev/null || { echo "FAIL[CC]: the expiry retry gave up while another claimant was still delivering that very alert"; fail=1; }
kill "$ccp" 2>/dev/null; wait "$ccp" 2>/dev/null || true
kill "$cch" 2>/dev/null; wait "$cch" 2>/dev/null || true

# ---- CD. ...but an unestablishable EXPIRY claim still terminates ----------
# The other side of CC, and the reason the cure is a THREE-way split rather than
# "stop counting skips": if `skipped` swallowed the unopenable claim here too,
# the expiry retry would spin forever on a broken lock backend and no durable
# record of the failure would ever be written. CA proves this for the terminal
# alert; the class is only closed when both bounded sites agree.
CDHO="$(NEWHO expiryunavailable)"; CDREC="$CDHO.dispatch"
live_json "running"; GOF "$CDHO" "expiry unopenable" >/dev/null 2>&1
: > "$CLAUDE_HANDOFF_LOG"
CLAUDE_HANDOFF_LOCK_DEBUG=broken:7 CLAUDE_HANDOFF_MAX_HOURS=0 \
CLAUDE_HANDOFF_NOTIFY_DEBUG=fail \
  bash "$SCRIPT" --watch "$CDREC" --poll-sec 1 --watch-gen g-cd >"$tmp/cd.out" 2>&1 &
cdp=$!
( sleep "$WATCH_HANG_GUARD"; kill -9 "$cdp" 2>/dev/null ) >/dev/null 2>&1 & cdk=$!
wait "$cdp" 2>/dev/null; cdcode=$?
kill "$cdk" 2>/dev/null; wait "$cdk" 2>/dev/null
assert_eq "$cdcode" "0" CD
cdn="$(grep -c "EXPIRED after" "$tmp/cd.out" 2>/dev/null || true)"
assert_eq "${cdn:-x}" "0" CD
assert_rec "$CDREC" "alert_undelivered_expired_g-cd=.*" CD
assert_contains "HandoffAlertUndelivered" "$(cat "$CLAUDE_HANDOFF_LOG")" CD
live_json "running"

# ---- CE. a symlink target with a TRAILING NEWLINE resolves to a sibling --
# `$( )` strips EVERY trailing newline, so a target spelled "sib.md\n" came back
# from `readlink` as "sib.md" -- a different file that very plausibly exists
# right beside it. The dispatch then validated one file, recorded another, and
# locked a third spelling. The read now keeps the byte (`readlink && printf x`)
# and strips exactly the ONE newline readlink itself adds, so what is left is
# the target as stored; a target that still spans lines is refused, because such
# a path can neither be recorded (the record is key=value LINES) nor resolved to
# one object.
# BOTH spellings exist, and they are different files. A dangling link would be
# refused several checks earlier, as unreadable -- which is a true statement about
# a broken link and NO statement about the newline, so the case would pass with
# the guard deleted. Here the link resolves to a real, readable, non-empty file
# whose NAME ends in a newline, and the stripped spelling beside it is a
# different real file: the two readings pick different objects, which is the
# whole finding.
CESIB="$tmp/work/HANDOFF-lfsib.md"
printf '# Handoff\n\nthe SIBLING a newline-stripped read lands on.\n' > "$CESIB"
CENL="$tmp/work/HANDOFF-lfsib.md"$'\n'
printf '# Handoff\n\nthe NEWLINE-NAMED file the link really points at.\n' > "$CENL"
CEHO="$tmp/work/HANDOFF-lflink.md"
rm -f "$CEHO" "$CESIB.dispatch" "$CESIB.dispatch".* "$SHIM_SPAWNS"
ln -s 'HANDOFF-lfsib.md'$'\n' "$CEHO" 2>/dev/null || true
# The fixture is checked WITHOUT readlink, because readlink's own dialect is the
# thing under test -- these are properties of the filesystem, not of any tool's
# output format.
[ -L "$CEHO" ] || { echo "FAIL[CE]: the fixture symlink was not created, so this case asserts nothing"; fail=1; }
[ -e "$CEHO" ] || { echo "FAIL[CE]: the fixture link is dangling, so it would be refused as unreadable and the newline guard would never be reached"; fail=1; }
[ -f "$CESIB" ] || { echo "FAIL[CE]: the sibling a stripped read lands on does not exist, so this case asserts nothing"; fail=1; }
[ "$CEHO" -ef "$CESIB" ] && { echo "FAIL[CE]: the link and the stripped spelling are the SAME file, so the two readings cannot differ"; fail=1; }
out="$(GOF "$CEHO" "trailing newline" 2>&1)"; code=$?
[ "$code" != "0" ] || { echo "FAIL[CE]: a symlink target that spans lines must refuse to dispatch"; fail=1; }
assert_contains "spans lines" "$out" CE
assert_no_file "$SHIM_SPAWNS" CE
assert_no_file "$CESIB.dispatch" CE          # the sibling was NOT dispatched in its place
# ANCHOR: the same link WITHOUT the stray byte resolves and dispatches, and the
# record lands on the TARGET's path -- identity is the object, not the spelling.
rm -f "$CEHO" "$CENL"; ln -s "HANDOFF-lfsib.md" "$CEHO"
live_json "running"
out="$(GOF "$CEHO" "well formed" 2>&1)"; code=$?
assert_eq "$code" "0" CE
assert_rec "$CESIB.dispatch" "state=verified" CE
assert_no_file "$CEHO.dispatch" CE

# ---- CF. a handoff file with TWO NAMES is refused ------------------------
# The record, the lock and every alert key are derived from the resolved path,
# and resolution ends at a hard link's own name -- there is nothing further to
# follow. So two names for one file are two lock paths and two records: both
# dispatches see a free lock, both write their own record, and both pay for a
# successor to read the identical handoff. Nothing at this layer can pick the
# canonical name, so the file is refused until the operator does.
CFHO="$(NEWHO hardlink)"
rm -f "$CFHO.second" "$SHIM_SPAWNS"
ln "$CFHO" "$CFHO.second"
out="$(GOF "$CFHO" "two names" 2>&1)"; code=$?
[ "$code" != "0" ] || { echo "FAIL[CF]: a handoff file with a second hard link must refuse to dispatch"; fail=1; }
assert_contains "has 2 names (hard links)" "$out" CF
assert_no_file "$SHIM_SPAWNS" CF
assert_no_file "$CFHO.dispatch" CF           # refused BEFORE any record or lock exists
assert_no_file "$CFHO.dispatch.flock" CF
# ANCHOR: one name, and the identical dispatch goes through -- so this is a
# refusal on the link count and not on anything else about the fixture.
rm -f "$CFHO.second"
live_json "running"
out="$(GOF "$CFHO" "one name" 2>&1)"; code=$?
assert_eq "$code" "0" CF
assert_rec "$CFHO.dispatch" "state=verified" CF

# ---- CG. the validated path BECOMING a symlink is caught at the boundary --
# The resolution loop exits on a path that is not a symlink, but `-L` and the
# identity read are separate syscalls. Plant a symlink to a HARD LINK of the
# same file in that window and every inode read follows it and agrees -- the
# identity guard sees nothing at all -- while REC, the lock and every alert key
# stay on this spelling. A dispatch aimed at the target would then take a
# different lock and launch a second paid successor (round-5 lifecycle #1). The
# `-L` question is asked again at the boundary, where the lock is already held.
CGHO="$(NEWHO retype)"; CGREC="$CGHO.dispatch"
rm -f "$SHIM_SPAWNS" "$CGHO.twin"
cgino="$(ls -i "$CGHO" | awk '{print $1}')"
live_json "running"
printf 'state=verified\nsession_id=99999999\n' > "$CGREC"   # a PREV nobody lists: the agents read runs
printf '%s' "$CGHO" > "$SHIM_HO_SYMLINK"
out="$(GOF "$CGHO" "retyped" 2>&1)"; code=$?
[ "$code" != "0" ] || { echo "FAIL[CG]: a path that became a symlink after resolution must refuse at the boundary"; fail=1; }
assert_contains "became a symlink after it was resolved" "$out" CG
assert_no_file "$SHIM_SPAWNS" CG
[ -L "$CGHO" ] || { echo "FAIL[CG]: the seam never fired, so this case asserts nothing"; fail=1; }
# ...and this is why identity alone cannot see it: BOTH reads follow the link to
# the very inode that was validated. `-i` is the link's own inode, `-iL` the
# target's -- only the second is what the identity guard compares.
assert_eq "$(ls -iL "$CGHO" | awk '{print $1}')" "$cgino" CG
assert_eq "$(ls -i "$CGHO.twin" | awk '{print $1}')" "$cgino" CG
assert_rec_last "$CGREC" state prelaunch_failed CG
rm -f "$CGHO"; mv "$CGHO.twin" "$CGHO"       # leave a plain file behind

# ---- CH. two watchers, one record, two SPELLINGS -> one lease -------------
# A watcher's lease is `<record>.watch.<gen>`, built from the path it was handed.
# Point one at the record and one at a symlink to it and the two derive DIFFERENT
# lease paths, so both take "the" lease and both watch: two watchdogs racing every
# alert claim about one successor, which is the duplicate-nudge failure the lease
# exists to prevent. The watch branch resolves its record through the same
# resolver dispatch uses, so the second one contends for the FIRST one's lease
# and stands down.
CHHO="$(NEWHO watchalias)"; CHREC="$CHHO.dispatch"
live_json "running"; GOF "$CHHO" "aliased" >/dev/null 2>&1
CHALIAS="$tmp/work/alias-ch.dispatch"
rm -f "$CHALIAS" "$CHALIAS".watch.* ; ln -s "$CHREC" "$CHALIAS"
: > "$CLAUDE_HANDOFF_LOG"
CLAUDE_HANDOFF_MAX_HOURS=1 bash "$SCRIPT" --watch "$CHREC" --watch-gen chgen --poll-sec 1 >/dev/null 2>&1 &
chw1=$!
chn=0
while [ "$chn" -lt 100 ]; do lock_is_held "$CHREC.watch.chgen"; [ "$?" = 0 ] && break; sleep 0.1; chn=$(( chn + 1 )); done
assert_held "$CHREC.watch.chgen" CH
CLAUDE_HANDOFF_MAX_HOURS=1 bash "$SCRIPT" --watch "$CHALIAS" --watch-gen chgen --poll-sec 1 >/dev/null 2>&1 &
chw2=$!
await_rec "$CLAUDE_HANDOFF_LOG" "HandoffWatchDuplicate" 200 \
  || { echo "FAIL[CH]: the watcher started on the ALIAS never contended for the real lease -- two watchdogs are armed for one successor"; fail=1; }
chn=0
while [ "$chn" -lt 100 ] && kill -0 "$chw2" 2>/dev/null; do sleep 0.1; chn=$(( chn + 1 )); done
kill -0 "$chw2" 2>/dev/null && { echo "FAIL[CH]: the duplicate watcher logged and then kept watching anyway"; fail=1; }
kill "$chw2" 2>/dev/null; wait "$chw2" 2>/dev/null || true
assert_no_file "$CHALIAS.watch.chgen" CH     # it never published a lease of its own
assert_held "$CHREC.watch.chgen" CH          # ...and the incumbent still holds the only one
kill "$chw1" 2>/dev/null; wait "$chw1" 2>/dev/null || true

# ---- CI. a launch that NAMES its session and exits nonzero is a launch ----
# `claude --bg` can background a session, print its id, and still exit nonzero
# on a client-side error afterwards. That exit used to record `failed` -- the one
# state a retry walks straight through -- so the next dispatch launched a SECOND
# paid successor for a handoff that already had one. The exit status now decides
# nothing on its own: an id was parsed, so a successor exists, and everything
# downstream treats it as one.
CIHO="$(NEWHO bgrc)"; CIREC="$CIHO.dispatch"
rm -f "$SHIM_SPAWNS"; live_json "running"
printf '7\n' > "$SHIM_BG_RC"
out="$(GOF "$CIHO" "nonzero after launch" 2>&1)"; code=$?
rm -f "$SHIM_BG_RC"
assert_eq "$code" "0" CI
assert_contains "dispatched $SHORT" "$out" CI
assert_rec "$CIREC" "state=verified" CI
assert_rec_missing "$CIREC" "state=failed" CI
assert_eq "$(grep -c '^spawn$' "$SHIM_SPAWNS")" "1" CI
# THE POINT OF THE CASE: the retry a `failed` record would have invited must not
# produce a second successor.
out="$(GOF "$CIHO" "retry" 2>&1)"; code=$?
[ "$code" != "0" ] || { echo "FAIL[CI]: a live successor on record must refuse a duplicate"; fail=1; }
assert_eq "$(grep -c '^spawn$' "$SHIM_SPAWNS")" "1" CI

# ---- CJ. no id: the REGISTRY decides between 'failed' and 'unknown' -------
# With no session id there is nothing to verify against, and the exit status is
# not evidence either way (CI). The registry is the only witness left. It cannot
# identify OUR successor -- no row carries the objective -- but it can answer the
# question that decides the state: was anything backgrounded in this directory at
# all? Read, and empty, is evidence: nothing was launched, so this is retryable.
# UNREADABLE is not evidence of absence, so that one is `unknown` and refuses.
CJHO="$(NEWHO noid)"; CJREC="$CJHO.dispatch"
rm -f "$SHIM_SPAWNS"
printf '[]\n' > "$SHIM_AGENTS"
printf 'no session id in this output\n' > "$SHIM_BG_OUT"
out="$(GOF "$CJHO" "nothing launched" 2>&1)"; code=$?
[ "$code" != "0" ] || { echo "FAIL[CJ]: a launch that named no session must fail the dispatch"; fail=1; }
assert_contains "lists no background session" "$out" CJ
assert_contains "can simply be retried" "$out" CJ
assert_rec_last "$CJREC" state failed CJ
# ...and `failed` really is retryable: the identical dispatch, UNFORCED, goes on
# to a verified successor. A state that refuses the retry would make this case
# indistinguishable from the `unknown` half below.
printf 'backgrounded \xc2\xb7 %s\n  claude agents   list sessions\n' "$SHORT" > "$SHIM_BG_OUT"
live_json "running"
out="$(GOF "$CJHO" "retry" 2>&1)"; code=$?
assert_eq "$code" "0" CJ
assert_rec_last "$CJREC" state verified CJ
# The other half: the same launch against a registry that CANNOT BE READ.
CJ2HO="$(NEWHO noidblind)"; CJ2REC="$CJ2HO.dispatch"
printf 'no session id in this output\n' > "$SHIM_BG_OUT"
: > "$SHIM_AGENTS_FAIL"
out="$(GOF "$CJ2HO" "blind" 2>&1)"; code=$?
rm -f "$SHIM_AGENTS_FAIL"
[ "$code" != "0" ] || { echo "FAIL[CJ]: a launch with no id and an unreadable registry must fail the dispatch"; fail=1; }
assert_contains "could not be read to find out" "$out" CJ
assert_rec_last "$CJ2REC" state unknown CJ
printf 'backgrounded \xc2\xb7 %s\n  claude agents   list sessions\n' "$SHORT" > "$SHIM_BG_OUT"
live_json "running"
out="$(GOF "$CJ2HO" "retry" 2>&1)"; code=$?
[ "$code" != "0" ] || { echo "FAIL[CJ]: state=unknown must block an unforced retry"; fail=1; }
assert_contains "may be running" "$out" CJ

# ---- CK. the lock recipe the DOC hands an operator actually holds ---------
# docs/handoff-successor.md tells a human how to take this lock by hand -- and
# for three rounds it named `<record>.lock`, the path the code stopped using at
# P4. An operator following it locked a file nothing reads and believed they had
# frozen dispatches. So the recipe is not prose: it is an interface, and it is
# tested by RUNNING the exact program the doc prints, against the doc's own text.
CKDOC="$(cd "$(dirname "$0")/.." && pwd)/docs/handoff-successor.md"
# The doc wraps the recipe across two lines; what an operator copies is the text,
# not its typesetting, so the comparison squeezes line breaks and indentation out.
CKSQ="$(tr '\n' ' ' < "$CKDOC" | sed 's/  */ /g')"
# The program EXECUTED below is EXTRACTED FROM THE DOC, never a literal retyped
# here. Asserting the doc contains a string this file already knows would only
# prove the two copies match -- a self-referential fixture pins nothing. Running
# the doc's own bytes makes a recipe that stops taking the lock fail by
# BEHAVIOUR: the probe it is supposed to block would sail through.
CKPROG="$(printf '%s' "$CKSQ" | sed -n "s/.*perl -e '\([^']*\)'.*/\1/p")"
[ -n "$CKPROG" ] || { echo "FAIL[CK]: no \`perl -e '...'\` recipe found in $CKDOC, so this case asserts nothing"; fail=1; }
assert_contains 'flock' "$CKPROG" CK
# The lock paragraph is found by its HEADING, not by a line range: the range this
# used to carry (`sed -n '110,140p'`) silently stops covering the paragraph the
# moment anything above it grows by a line, and then asserts about whatever text
# happens to have slid into view.
CKLOCKSEC="$(awk '/^2\. \*\*Claim the lock/{f=1} /^3\. \*\*Refuse/{f=0} f' "$CKDOC")"
[ -n "$CKLOCKSEC" ] || { echo "FAIL[CK]: no 'Claim the lock' section in $CKDOC, so this case asserts nothing about it"; fail=1; }
assert_contains '.flock' "$CKLOCKSEC" CK-lock-section
# The interface half of this document has now twice described a mechanism the
# code did not have: `<record>.lock` for three rounds after P4 moved to `.flock`
# (round-5 lifecycle #3), and then a `sweep_legacy_lock` that *deletes* the legacy
# claim, for two rounds after round 5 retired every sweep. Rereading prose does
# not catch that, so the paragraph is tied to the code twice over.
# (a) The antecedent is read from the CODE: while the launcher contains no sweep,
# the paragraph may not name the function that used to be one.
if ! grep -q 'sweep_legacy_lock' "$SCRIPT"; then
  assert_missing 'sweep_legacy_lock' "$CKLOCKSEC" CK-no-retired-sweep
fi
# (b) The command the DOC hands the operator has to be the command the LAUNCHER
# actually prints. The token comes out of the doc and is matched against a real
# refusal, so neither side is retyped here: a paragraph that starts saying the
# launcher clears the legacy claim itself fails against the launcher's own output
# and against the directory, which is still there afterwards.
CKRM="$(printf '%s' "$CKLOCKSEC" | sed -n 's/.*`\(rm -rf\)`.*/\1/p' | head -1)"
[ -n "$CKRM" ] || { echo "FAIL[CK]: the lock section no longer names the command the operator runs by hand"; fail=1; }
CKLHO="$(NEWHO doclegacy)"; CKLREC="$CKLHO.dispatch"
mkdir -p "$CKLREC.lock"; rm -f "$SHIM_SPAWNS"
out="$(GOF "$CKLHO" "a legacy claim, per the doc" 2>&1)"; code=$?
[ "$code" != "0" ] || { echo "FAIL[CK]: a claim in the previous design's shape must refuse the dispatch"; fail=1; }
assert_contains "$CKRM" "$out" CK-doc-names-the-real-command
[ -d "$CKLREC.lock" ] || { echo "FAIL[CK]: the launcher removed the legacy claim the doc says only the operator removes"; fail=1; }
assert_no_file "$SHIM_SPAWNS" CK-legacy
rm -rf "$CKLREC.lock"
CKHO="$(NEWHO docrecipe)"; CKREC="$CKHO.dispatch"
rm -f "$SHIM_SPAWNS"; live_json "running"
cat > "$tmp/ck-probe.sh" <<'CKP'
#!/usr/bin/env bash
: > "$CK_ARGS"
for _cka in "$@"; do printf '%s\n' "$_cka" >> "$CK_ARGS"; done
bash "$CK_SCRIPT" "$CK_HO" "probe under the documented lock" --cwd "$CK_CWD" > "$CK_OUT" 2>&1
printf 'code=%s\n' "$?" >> "$CK_OUT"
CKP
chmod +x "$tmp/ck-probe.sh"
export CK_SCRIPT="$SCRIPT" CK_HO="$CKHO" CK_CWD="$tmp/work" CK_OUT="$tmp/ck.out"
export CK_ARGS="$tmp/ck-args.txt"
# The PATH comes out of the doc too, not just the program. Retyping `.flock` here
# left the one thing round-5 lifecycle #3 was actually about -- the doc naming the
# path the code stopped using at P4 -- untested: a mutant that changed the
# recipe's operand back to `"$REC.lock"` passed this whole case, because the
# recipe still ran, still took a lock, and the test still pointed it at .flock.
# The doc's operand is `"$REC.<suffix>"`, so the suffix is what an operator's copy
# would append to their own record path.
CKPATH="$(printf '%s' "$CKSQ" | sed -n "s/.*perl -e '[^']*' \"\([^\"]*\)\".*/\1/p" | head -1)"
CKSUF="${CKPATH#*\$REC}"
if [ -z "$CKPATH" ] || [ "$CKSUF" = "$CKPATH" ] || [ -z "$CKSUF" ]; then
  echo "FAIL[CK]: the recipe's lock path could not be read from $CKDOC (got [$CKPATH]), so the probe below would test a path this file chose rather than the one the doc hands the operator"; fail=1
  CKSUF=".flock"
fi
# ...and the recipe is run WITH ARGUMENTS. The recipe's payload is
# `system(@ARGV[1..$#ARGV])` -- a LIST, so it passes the operator's whole command
# through without a shell. Invoked with a bare command word this case could not
# tell that from `system($ARGV[1])`, which runs the program name and silently
# DISCARDS every argument: that mutant took the same lock, ran this probe, blocked
# the same dispatch and passed the whole case (round 6 test-quality #3). An
# operator whose check-and-act command is `foo --check /path` would have run
# `foo`. The second argument carries a space, so a recipe that re-split the
# command in a shell fails here too.
perl -e "$CKPROG" "$CKREC$CKSUF" "$tmp/ck-probe.sh" ck-arg-one 'ck arg two'
assert_eq "$(sed -n 1p "$CK_ARGS" 2>/dev/null)" "ck-arg-one" CK-recipe-passes-arguments
assert_eq "$(sed -n 2p "$CK_ARGS" 2>/dev/null)" "ck arg two" CK-recipe-passes-arguments
assert_eq "$(wc -l < "$CK_ARGS" 2>/dev/null | tr -d ' ')" "2" CK-recipe-passes-arguments
assert_contains "still running" "$(cat "$CK_OUT")" CK
assert_contains "code=2" "$(cat "$CK_OUT")" CK
assert_no_file "$SHIM_SPAWNS" CK
assert_no_file "$CKREC" CK
# ANCHOR: perl has exited, so the lock is released -- and the identical probe
# now dispatches. The refusal above was this lock and nothing else about it.
"$tmp/ck-probe.sh"
assert_contains "dispatched $SHORT" "$(cat "$CK_OUT")" CK
assert_rec "$CKREC" "state=verified" CK


# ---- CL. the stat DIALECT ORDER, on a machine that answers both ----------
# file_nlink asks `stat -c '%h'` before `stat -f '%l'` because `-c` is GNU-only
# and BSD rejects it, while GNU ACCEPTS `-f` with a different meaning entirely:
# there `%l` is the filesystem's maximum filename LENGTH. That is a number, on
# every file, that sails through the shape check and means nothing -- ask it
# first on GNU and every single-name handoff reads as having 255 names and is
# refused. This machine is BSD, so its real `stat` cannot tell the two orders
# apart: BOTH orders return the right answer here, and the fix would have gone
# out pinned by nothing. The shim below supplies the missing dialect.
mkdir -p "$tmp/gnubin"
cat > "$tmp/gnubin/stat" <<'GNSH'
#!/bin/sh
# A GNU-dialect stat, standing in for the machines this script also runs on.
case "$1" in
  -c) _f="$2"; shift 2
      case "$_f" in
        '%h')    exec /usr/bin/stat -f '%l' "$@" ;;
        '%d:%i') exec /usr/bin/stat -f '%d:%i' "$@" ;;
        '%Y')    exec /usr/bin/stat -f '%m' "$@" ;;
        *) exit 1 ;;
      esac ;;
  -f) _f="$2"; shift 2
      # GNU's `-f` is FILE SYSTEM status. `%l` is the maximum filename length --
      # plausible, numeric, and about the filesystem rather than the file. The
      # rest of the format letters used here do not exist in that dialect.
      case "$_f" in
        '%l') echo 255; exit 0 ;;
        *) echo 'stat: invalid directive' >&2; exit 1 ;;
      esac ;;
esac
exec /usr/bin/stat "$@"
GNSH
chmod +x "$tmp/gnubin/stat"
# The shim is checked against the real filesystem first: it must report the true
# link count through the GNU spelling, and the filesystem number through the BSD
# one. Otherwise a broken shim, not the dialect order, is what the case measures.
CLHO="$(NEWHO gnustat)"
[ "$(PATH="$tmp/gnubin:$PATH" stat -c '%h' "$CLHO")" = 1 ] || { echo "FAIL[CL]: the GNU stat shim does not report the real link count, so this case asserts nothing"; fail=1; }
[ "$(PATH="$tmp/gnubin:$PATH" stat -f '%l' "$CLHO")" = 255 ] || { echo "FAIL[CL]: the GNU stat shim does not answer -f %l the GNU way, so the wrong dialect order would not be visible"; fail=1; }
rm -f "$SHIM_SPAWNS"
live_json "running"
# The PATH override is scoped by a SUBSHELL, not by a var-prefix on GOF: bash and
# POSIX sh disagree about whether an assignment preceding a FUNCTION call
# survives the call, and a leaked shim PATH would silently re-dialect every case
# below this one.
out="$( PATH="$tmp/gnubin:$PATH" bash "$SCRIPT" "$CLHO" "gnu dialect" --cwd "$tmp/work" 2>&1 )"; code=$?
assert_eq "$code" "0" CL
assert_rec "$CLHO.dispatch" "state=verified" CL
# The precise wrong answer, named: 255 is the max filename LENGTH, not a count of
# names, and the message it would produce is the one this asserts is absent.
assert_missing "names (hard links)" "$out" CL
assert_missing "255 names" "$out" CL

# ---- CM. the spawn-site count in the comment matches the file -------------
# The comment block above lock_tool carries a grep and a number, and the number
# is the coverage claim for the whole substitution class: every `$( … )` that
# can run under a claim opens by closing fds 9/8/7, and the count is how a
# reviewer knows a new one did not slip in without them. The PROBE is
# self-counting; the NUMBER was not checked by anything, and batch 2 moved it
# from 34 to 37 without touching the comment. A claim nothing evaluates is not a
# control. This runs the file's own grep and compares.
CM_LIVE="$(grep -c '^[^#]*( exec 9>&- 8>&- 7>&-' "$SCRIPT")"
CM_DOC="$(sed -n 's/.*SPAWN_SUBSHELLS=\([0-9][0-9]*\).*/\1/p' "$SCRIPT" | head -1)"
[ -n "$CM_DOC" ] || { echo "FAIL[CM]: no SPAWN_SUBSHELLS= tag in $SCRIPT, so the count claim cannot be checked at all"; fail=1; }
assert_eq "$CM_LIVE" "$CM_DOC" CM
# ...and the claim is only worth something if the number is not zero on both
# sides: a grep that matches nothing would agree with a tag of 0 forever.
[ "${CM_LIVE:-0}" -gt 10 ] || { echo "FAIL[CM]: the spawn-site grep matched only $CM_LIVE lines, which is not a count of this file -- the pattern has drifted from the code"; fail=1; }

# The NUMBERED list beside that count is a claim of exactly the same kind, and
# checking the number is not checking the list: batch 4 left the count honest
# (37 -> 19, both sides moved) and broke the list in BOTH directions. `lookup`
# lost its marker when the node call moved into a helper, so the list named a
# site the code no longer marked; fs_get's temp-file `rm` stopped existing, so
# the list named a site the code no longer had. Neither is visible from any one
# line, which is the whole reason the enumeration exists. Reconcile it against
# the code both ways.
CM_LIST="$(awk '/^# SPAWN-LIST-BEGIN/{f=1;next} /^# SPAWN-LIST-END/{f=0} f' "$SCRIPT")"
[ -n "$CM_LIST" ] || { echo "FAIL[CM]: no SPAWN-LIST-BEGIN/END block in $SCRIPT -- the enumeration cannot be checked at all"; fail=1; }
CM_NUMS="$(printf '%s\n' "$CM_LIST" | sed -n 's/^#  *\([0-9][0-9]*\) .*/\1/p' | sort -n)"
CM_HEAD="$(printf '%s\n' "$CM_LIST" | sed -n 's/.*CLOSES THE DESCRIPTORS (\([0-9][0-9]*\)).*/\1/p' | head -1)"
CM_N="$(printf '%s\n' "$CM_NUMS" | grep -c .)"
# the headline count is the list's own claim about its length
[ -n "$CM_HEAD" ] || { echo "FAIL[CM]: the list has no 'CLOSES THE DESCRIPTORS (n)' headline, so its length claims nothing"; fail=1; }
assert_eq "$CM_N" "${CM_HEAD:-none}" CM
# ...and a parse that found nothing would agree with a headline of 0 forever
[ "${CM_N:-0}" -gt 5 ] || { echo "FAIL[CM]: parsed only $CM_N entries out of the spawn-site list -- the parse has drifted from the comment, so everything below it is vacuous"; fail=1; }
CM_SEQ="$(awk -v n="${CM_N:-0}" 'BEGIN{for(i=1;i<=n;i++) print i}')"
[ "$CM_NUMS" = "$CM_SEQ" ] || { echo "FAIL[CM]: the list numbers are not 1..$CM_N with no gap or repeat -- got: $(echo $CM_NUMS)"; fail=1; }
# every marker in the CODE, i.e. outside the list block. `SPAWN SITES 1 and 2`
# is one line naming two sites, so the scan takes every number in the phrase.
CM_MARK="$(awk '
  /^# SPAWN-LIST-BEGIN/{f=1} /^# SPAWN-LIST-END/{f=0;next} f{next}
  {
    s=$0
    while (match(s, /SPAWN SITES?[ ]+[0-9]+([ ]+and[ ]+[0-9]+)?/)) {
      t=substr(s, RSTART, RLENGTH); s=substr(s, RSTART+RLENGTH)
      while (match(t, /[0-9]+/)) { print substr(t, RSTART, RLENGTH); t=substr(t, RSTART+RLENGTH) }
    }
  }' "$SCRIPT" | sort -n)"
CM_MARK_ALL="$CM_MARK"
CM_MARK="$(printf '%s\n' "$CM_MARK_ALL" | sort -n -u)"
for _n in $CM_NUMS; do
  case " $(echo $CM_MARK) " in
    *" $_n "*) : ;;
    *) echo "FAIL[CM]: the list names site $_n but no line in the code is marked SPAWN SITE $_n"; fail=1 ;;
  esac
  # ...and PRESENCE is not coverage where one entry stands for several places.
  # Site 7 is marked in five callers; losing one of them leaves the other four
  # answering for it, which is exactly the regression this case exists for. An
  # entry that spans call sites declares how many as `at <k> call sites`.
  _want="$(printf '%s\n' "$CM_LIST" | sed -n "s/^#  *$_n .*at \\([0-9][0-9]*\\) call sites.*/\\1/p" | head -1)"
  [ -n "$_want" ] || _want=1
  _got="$(printf '%s\n' "$CM_MARK_ALL" | grep -c "^$_n\$")"
  [ "$_got" = "$_want" ] || { echo "FAIL[CM]: the list says site $_n is marked at $_want place(s); the code marks it at $_got"; fail=1; }
done
for _n in $CM_MARK; do
  case " $(echo $CM_NUMS) " in
    *" $_n "*) : ;;
    *) echo "FAIL[CM]: the code marks SPAWN SITE $_n but the numbered list does not name it"; fail=1 ;;
  esac
done

# ---- CN. a presence probe that could not RUN is not a successor that left --
# row_present used to answer with an exit status that meant "absent" for a list
# that genuinely lacked the id AND for node failing to run at all. The caller
# read the second as the first, wrote `finished=1`, announced "finished (gone)",
# and exited -- while the row still said `running`. The shim below breaks
# EXACTLY the presence probe: `claude agents --json` still parses, `lookup` still
# answers, and only the probe that decides presence blows up.
mkdir -p "$tmp/nodebin"
CN_REAL_NODE="$(command -v node)"
[ -n "$CN_REAL_NODE" ] || { echo "FAIL[CN]: no real node on PATH to delegate to"; fail=1; }
export CN_REAL_NODE
export SHIM_NODE_FIRED="$tmp/node-presence-fired"
cat > "$tmp/nodebin/node" <<'NDSH'
#!/bin/sh
# Find the script passed to -e; the presence probe is the one that matches ids
# and writes NOTHING (lookup matches ids too, but prints a field).
_scr=""; _prev=""
for _a in "$@"; do
  [ "$_prev" = "-e" ] && _scr="$_a"
  _prev="$_a"
done
case "$_scr" in
  *"sessionId === id"*)
    case "$_scr" in
      *"stdout.write"*) ;;                       # lookup — let it through
      *) echo fired >> "$SHIM_NODE_FIRED"; exit 127 ;;   # the presence probe
    esac ;;
esac
exec "$CN_REAL_NODE" "$@"
NDSH
chmod +x "$tmp/nodebin/node"
CNHO="$(NEWHO presence)"; CNREC="$CNHO.dispatch"
live_json "running"
GOF "$CNHO" "watch presence" >/dev/null 2>&1
: > "$SHIM_NODE_FIRED"
out="$( PATH="$tmp/nodebin:$PATH" bash "$SCRIPT" --watch-once "$CNREC" 2>&1 )"; code=$?
# The seam must have FIRED. A shim keyed to the probe's own text is exactly the
# kind that stops matching when the implementation is reworded, and a case whose
# seam never fires passes for the wrong reason (round-5 batch 2, case BR).
[ -s "$SHIM_NODE_FIRED" ] || { echo "FAIL[CN]: the node shim never intercepted the presence probe, so this case asserts nothing"; fail=1; }
assert_contains "presence probe" "$out" CN
assert_rec_missing "$CNREC" "finished=1" CN
assert_missing "finished (gone)" "$out" CN
assert_rec_last "$CNREC" alerted_presencedegraded 1 CN
# The episode ends. With the probe working again the marker is cleared, so a
# SECOND presence outage is announced rather than swallowed by the first one.
out="$(bash "$SCRIPT" --watch-once "$CNREC" 2>&1)"
assert_rec_last "$CNREC" alerted_presencedegraded 0 CN
# ...and the ABSENT answer still terminates: this is what keeps the fix from
# being "never conclude anything". The list parses and does not name the id.
printf '[]\n' > "$SHIM_AGENTS"
out="$(bash "$SCRIPT" --watch-once "$CNREC" 2>&1)"
assert_rec "$CNREC" "finished=1" CN
assert_contains "gone" "$out" CN
live_json "running"

# ---- CN2. the same probe, at the DISPATCH duplicate check ------------------
# Same conflation, opposite consequence: there the unanswerable probe reads as
# "no live successor" and the dispatch starts a SECOND one.
CN2HO="$(NEWHO presence2)"; CN2REC="$CN2HO.dispatch"
live_json "running"
GOF "$CN2HO" "seed" >/dev/null 2>&1
rm -f "$SHIM_SPAWNS"; : > "$SHIM_NODE_FIRED"
out="$( PATH="$tmp/nodebin:$PATH" bash "$SCRIPT" "$CN2HO" "again" --cwd "$tmp/work" 2>&1 )"; code=$?
[ -s "$SHIM_NODE_FIRED" ] || { echo "FAIL[CN2]: the node shim never intercepted the presence probe, so this case asserts nothing"; fail=1; }
[ "$code" != "0" ] || { echo "FAIL[CN2]: an unanswerable presence probe must not clear the way for a second dispatch"; fail=1; }
assert_contains "could not be run" "$out" CN2
assert_no_file "$SHIM_SPAWNS" CN2

# ---- CO. no clock, no deadline, so NO LEASE -------------------------------
# `epoch` used to answer 0 when `date` failed, and 0 is not neutral in
# `EPOCH < DEADLINE` -- it is forever early. The watcher then never expired,
# never alerted, and held a generation lease that told every reconciling
# dispatch a live watchdog was on the job. The honest end of that is a watcher
# that does not start: no lease means arm_watch's probe reports FAILED TO ARM.
mkdir -p "$tmp/datebin"
export SHIM_DATE_FAIL="$tmp/date-fail"
cat > "$tmp/datebin/date" <<'DTSH'
#!/bin/sh
[ -f "$SHIM_DATE_FAIL" ] && exit 1
exec /bin/date "$@"
DTSH
chmod +x "$tmp/datebin/date"
# The shim is checked both ways against the real clock before it is trusted.
rm -f "$SHIM_DATE_FAIL"
[ -n "$(PATH="$tmp/datebin:$PATH" date +%s)" ] || { echo "FAIL[CO]: the date shim does not pass a working clock through, so every case below would fail for the wrong reason"; fail=1; }
: > "$SHIM_DATE_FAIL"
[ -z "$(PATH="$tmp/datebin:$PATH" date +%s 2>/dev/null)" ] || { echo "FAIL[CO]: the date shim does not break the clock when asked, so this case asserts nothing"; fail=1; }
COHO="$(NEWHO noclock)"; COREC="$COHO.dispatch"
live_json "running"
rm -f "$SHIM_DATE_FAIL"
GOF "$COHO" "watch me" >/dev/null 2>&1
: > "$SHIM_DATE_FAIL"
: > "$CLAUDE_HANDOFF_LOG"
run_bounded 20 env PATH="$tmp/datebin:$PATH" bash "$SCRIPT" --watch "$COREC" --watch-gen g-co --poll-sec 1 --heartbeat-min 9999
assert_eq "$RB_HUNG" "0" CO
assert_eq "$RB_CODE" "0" CO
assert_contains "HandoffWatchNoClock" "$(cat "$CLAUDE_HANDOFF_LOG")" CO
lock_is_held "$COREC.watch.g-co"; _co=$?
[ "$_co" = 0 ] && { echo "FAIL[CO]: a watcher that could not read the clock published a lease anyway -- reconciliation will read it as a live watchdog"; fail=1; }
# ...and it did not fabricate an expiry either: it never had a deadline to reach.
assert_rec_missing "$COREC" "monitoring_expired=.*" CO
rm -f "$SHIM_DATE_FAIL"

# ---- CP. a clock lost MID-WATCH is a stand-down, not a silent spin ---------
# The clock is broken only after the lease is provably held, so this crosses the
# exact edge the old code could not: EPOCH keeps its last value, the loop
# condition stays true, and the watcher spins forever holding the lease.
CPHO="$(NEWHO clocklost)"; CPREC="$CPHO.dispatch"
live_json "running"
GOF "$CPHO" "watch me" >/dev/null 2>&1
: > "$CLAUDE_HANDOFF_LOG"
( PATH="$tmp/datebin:$PATH" CLAUDE_HANDOFF_MAX_HOURS=1 \
  bash "$SCRIPT" --watch "$CPREC" --watch-gen g-cp --poll-sec 1 --heartbeat-min 9999 ) >"$tmp/cp.out" 2>&1 &
cp_pid=$!
_n=0
while [ "$_n" -lt 200 ]; do lock_is_held "$CPREC.watch.g-cp"; [ "$?" = 0 ] && break; sleep 0.1; _n=$(( _n + 1 )); done
lock_is_held "$CPREC.watch.g-cp"; _cp=$?
[ "$_cp" = 0 ] || { echo "FAIL[CP]: the watcher never took its lease, so breaking the clock afterwards proves nothing"; fail=1; }
: > "$SHIM_DATE_FAIL"
await_rec_last "$CPREC" watch_clock_lost 1 200 CP
# The lease goes free. That is the half that matters: a stood-down watcher which
# kept its lease would block the healthy replacement it exists to make room for.
_n=0
while [ "$_n" -lt 100 ]; do lock_is_held "$CPREC.watch.g-cp"; [ "$?" = 0 ] || break; sleep 0.1; _n=$(( _n + 1 )); done
lock_is_held "$CPREC.watch.g-cp"; _cp=$?
[ "$_cp" = 0 ] && { echo "FAIL[CP]: the watcher stood down but kept its lease, so nothing can be re-armed in its place"; fail=1; }
_n=0
while [ "$_n" -lt 100 ] && kill -0 "$cp_pid" 2>/dev/null; do sleep 0.1; _n=$(( _n + 1 )); done
kill -0 "$cp_pid" 2>/dev/null && { echo "FAIL[CP]: the watcher is still running after losing the clock -- that is the infinite spin this case exists to catch"; fail=1; kill -9 "$cp_pid" 2>/dev/null; }
wait "$cp_pid" 2>/dev/null || true
rm -f "$SHIM_DATE_FAIL"
assert_contains "HandoffWatchClockLost" "$(cat "$CLAUDE_HANDOFF_LOG")" CP
assert_contains "STOOD DOWN" "$(cat "$tmp/cp.out")" CP
# NOT an expiry. `monitoring_expired` is a claim about the deadline being
# reached, and it was not -- saying it would make the alert about the successor
# rather than about the watcher.
assert_rec_missing "$CPREC" "monitoring_expired=.*" CP
retire_watchers "$CPREC"

# ---- CQ. flock(1) is not an acceptable backend, even as a last resort -----
# `flock -n` exits 1 for contention AND for ENOLCK/ENOTSUP/EBADF, so on a
# filesystem that cannot lock it reports "someone else holds it" -- lease_probe
# reads that as a live watcher and leaves nobody watching. Preferring perl only
# demoted the untrustworthy backend; a host without perl still fell through to
# it silently. An ambiguous answer is not the safe answer, so the host REFUSES.
mkdir -p "$tmp/flockbin"
cat > "$tmp/flockbin/flock" <<'FLSH'
#!/bin/sh
# Present, executable, and never to be chosen. Exits 1 exactly as the real
# flock(1) does for contention -- which is also what it exits on a filesystem
# that cannot lock at all, and is the entire reason it is refused.
exit 1
FLSH
chmod +x "$tmp/flockbin/flock"
[ -x "$tmp/flockbin/flock" ] || { echo "FAIL[CQ]: the flock stand-in is not executable, so 'it was not chosen' asserts nothing"; fail=1; }
CQHO="$(NEWHO noperl)"
live_json "running"
rm -f "$SHIM_SPAWNS"
out="$( PATH="$tmp/flockbin:$PATH" CLAUDE_HANDOFF_LOCK_TOOL_DEBUG=noperl \
        bash "$SCRIPT" "$CQHO" "no backend" --cwd "$tmp/work" 2>&1 )"; code=$?
[ "$code" != "0" ] || { echo "FAIL[CQ]: a host with no errno-aware lock backend dispatched anyway"; fail=1; }
assert_contains "errno-aware" "$out" CQ
assert_contains "flock(1) is deliberately NOT accepted" "$out" CQ
assert_no_file "$SHIM_SPAWNS" CQ
# ...and with perl back, the very same PATH dispatches: the refusal is about the
# BACKEND, not about the fake flock being on PATH at all.
out="$( PATH="$tmp/flockbin:$PATH" bash "$SCRIPT" "$CQHO" "backend present" --cwd "$tmp/work" --force 2>&1 )"; code=$?
assert_eq "$code" "0" CQ

# ---- CR. the stand-down drops the lease BEFORE it tries to tell anyone ----
# CP proves the lease ends up free -- but a process that exits releases its
# descriptors anyway, so "free afterwards" is true whether or not the code ever
# dropped it. Deleting the drop from the clock-lost arm left CP green (round-5
# mutation B3-A3d, SURVIVED). What that site actually claims is an ORDER: the
# lease goes FIRST, so a healthy watcher can be armed in this one's place while
# it is still trying to reach a human -- and `notify` is unbounded, so "still
# trying" can last as long as the sink wants. The sink is therefore made to
# block, and the lease is read while the stand-down is provably mid-flight.
CRHO="$(NEWHO leasefirst)"; CRREC="$CRHO.dispatch"
live_json "running"
rm -f "$SHIM_DATE_FAIL" "$SHIM_NOTIFY_BLOCK" "$SHIM_NOTIFY_BLOCK.ready" "$SHIM_NOTIFY_BLOCK.release"
GOF "$CRHO" "watch me" >/dev/null 2>&1
: > "$CLAUDE_HANDOFF_LOG"
( PATH="$tmp/datebin:$tmp/nbin:$PATH" CLAUDE_HANDOFF_NOTIFY_DEBUG= CLAUDE_HANDOFF_MAX_HOURS=1 \
  bash "$SCRIPT" --watch "$CRREC" --watch-gen g-cr --poll-sec 1 --heartbeat-min 9999 ) >"$tmp/cr.out" 2>&1 &
cr_pid=$!
_n=0
while [ "$_n" -lt 200 ]; do lock_is_held "$CRREC.watch.g-cr"; [ "$?" = 0 ] && break; sleep 0.1; _n=$(( _n + 1 )); done
lock_is_held "$CRREC.watch.g-cr"; _cr=$?
[ "$_cr" = 0 ] || { echo "FAIL[CR]: the watcher never took its lease, so nothing below is about releasing one"; fail=1; }
# The sink blocks only from HERE, and the argv log is cleared with it, so the
# block observed below belongs to the stand-down's own alert rather than to
# some earlier one that happened to be in flight.
: > "$SHIM_NOTIFY_ARGS"
: > "$SHIM_NOTIFY_BLOCK"
: > "$SHIM_DATE_FAIL"
_n=0
while [ "$_n" -lt 400 ] && [ ! -f "$SHIM_NOTIFY_BLOCK.ready" ]; do sleep 0.1; _n=$(( _n + 1 )); done
[ -f "$SHIM_NOTIFY_BLOCK.ready" ] || { echo "FAIL[CR]: the stand-down never reached the notification sink, so there was no mid-flight moment to read the lease in"; fail=1; }
assert_contains "STOOD DOWN" "$(cat "$SHIM_NOTIFY_ARGS")" CR
# ...and the watcher is STILL ALIVE. Without this the read below is CP's read
# again -- an exited process has no descriptors, so its lease is free for a
# reason that has nothing to do with the line under test.
kill -0 "$cr_pid" 2>/dev/null || { echo "FAIL[CR]: the watcher had already exited, so a free lease below would prove nothing about the order"; fail=1; }
lock_is_held "$CRREC.watch.g-cr"; _cr=$?
[ "$_cr" = 0 ] && { echo "FAIL[CR]: the lease is still HELD while the stand-down is still trying to tell someone -- no replacement watcher can be armed until this one is done alerting, and nothing bounds that"; fail=1; }
: > "$SHIM_NOTIFY_BLOCK.release"
_n=0
while [ "$_n" -lt 300 ] && kill -0 "$cr_pid" 2>/dev/null; do sleep 0.1; _n=$(( _n + 1 )); done
kill -0 "$cr_pid" 2>/dev/null && { echo "FAIL[CR]: the watcher never exited once the sink returned"; fail=1; kill -9 "$cr_pid" 2>/dev/null; }
wait "$cr_pid" 2>/dev/null || true
rm -f "$SHIM_DATE_FAIL" "$SHIM_NOTIFY_BLOCK" "$SHIM_NOTIFY_BLOCK.ready" "$SHIM_NOTIFY_BLOCK.release"
retire_watchers "$CRREC"


# ---- CS. work under a held claim is ENUMERATED, and every site CLASSIFIED ---
# Three rounds found this class at three different sites: an unbounded read of
# the agent list, a hung notifier freezing the poll while the lease still read
# "healthy", and a raw `-r` inside every leased poll. Per the enumeration rule,
# a class that recurs at DIFFERENT sites is not closed by fixing instances --
# it is closed by counting the population. tests/claim-census.js derives, from
# the source, the set of functions reachable while fd 7, 8 or 9 is held; finds
# every primitive site inside it; and reports each site's `# CLAIM:` tag.
#
# The four tags are properties, not batches: a = bounded (runs inside
# timed_to_file's deadline-killed child), b = no blocking operation of its own,
# c = bounded by construction, d = unbounded AND NAMED, with the reason in the
# source next to the tag.
CENSUS="$(cd "$(dirname "$0")" && pwd)/claim-census.js"
[ -f "$CENSUS" ] || { echo "FAIL[CS]: no census at $CENSUS -- the guard this case runs does not exist"; fail=1; }
CS_JSON="$tmp/cr-census.json"
node "$CENSUS" "$SCRIPT" --json > "$CS_JSON" 2>"$tmp/cr-census.err" \
  || { echo "FAIL[CS]: the census refused to run on $SCRIPT: $(cat "$tmp/cr-census.err")"; fail=1; }
cs_q() { # $1 = total | closure | a|b|c|d|UNTAGGED
  node -e 'const j=require(process.argv[1]), k=process.argv[2];
           console.log(k === "closure" ? j.closure.join(" ")
                     : k === "total"   ? j.total
                     : (j.counts[k] || 0));' "$CS_JSON" "$1"
}

# 1. NO UNTAGGED SITE. This is the coverage claim: every primitive that can run
#    while a claim is held has been looked at and classified.
CS_UNTAGGED="$(cs_q UNTAGGED)"
[ "$CS_UNTAGGED" = 0 ] || { echo "FAIL[CS]: $CS_UNTAGGED site(s) inside the claim closure carry no # CLAIM: tag -- run: node tests/claim-census.js hooks/handoff.sh --list"; fail=1; }

# 2. THE COUNTS, BY NUMBER. A tag flipped from `a` to `d` without a note in the
#    design fails here rather than silently enlarging the unbounded residue.
#    63 -> 64 and b 13 -> 14 in round 6 micro-review 5, and the one new site was
#    read before the number was changed: `verify_lock` now asks whether fd 9 is
#    still open instead of inferring it from the lock backend's status, and the
#    census sees that question as a `write` primitive because it is spelled as a
#    redirection. It writes NO BYTES -- `( true >&9 )` duplicates a descriptor
#    this process already holds and runs a builtin that prints nothing -- so
#    there is no I/O to block on and `b` is the property it actually has. The
#    other `>&9` in this hook is the lock file's diagnostic line, which really
#    does write and is tagged `d` for exactly that reason; the two are not the
#    same site type despite sharing a spelling.
assert_eq "$(cs_q total)" "69" CS
assert_eq "$(cs_q a)" "37" CS
assert_eq "$(cs_q b)" "15" CS
assert_eq "$(cs_q c)" "4"  CS
assert_eq "$(cs_q d)" "13" CS

# 3. `a` IS CHECKED, NOT BELIEVED. `a` claims the site runs inside
#    timed_to_file's deadline-killed child, which is decidable from the call
#    graph: either the line IS the bounded invocation, or it sits in a helper
#    whose EVERY call site is one. The census exits 2 and names the site
#    otherwise, so a probe that acquires one ordinary caller stops passing.
node "$CENSUS" "$SCRIPT" >/dev/null 2>"$tmp/cs-averify.err"; cs_av=$?
[ "$cs_av" = 0 ] || { echo "FAIL[CS]: the census could not verify the 'a' tags: $(cat "$tmp/cs-averify.err")"; fail=1; }

# 4. A FLOOR, on both derived quantities. Case CM's lesson applied to the census
#    itself: a pattern that silently stopped matching would agree with a count of
#    zero forever, and so would a closure walk that stopped walking.
[ "$(cs_q total)" -gt 40 ] || { echo "FAIL[CS]: the census found only $(cs_q total) sites, which is not a census of this file -- the patterns have drifted from the code"; fail=1; }
CS_LIVE="$tmp/cr-closure-live.txt"; CS_WANT="$tmp/cr-closure-want.txt"
printf '%s\n' $(cs_q closure) | sort > "$CS_LIVE"
[ "$(wc -l < "$CS_LIVE")" -gt 30 ] || { echo "FAIL[CS]: the claim closure came out at $(wc -l < "$CS_LIVE") functions -- the call-graph walk is not walking"; fail=1; }

# 5. THE CLOSURE, BY MEMBERSHIP -- which is where a moved region marker shows up.
#    The regions are markers in the source, so the census cannot silently read a
#    smaller population; but a marker moved a few lines still changes WHICH
#    functions are reachable, and that is a decision, not an edit. (The first
#    draft asserted the code line adjacent to each marker instead. Three of the
#    five are `fi`. An anchor that matches everything is not an anchor.)
cat > "$CS_WANT" <<'CSFNS'
_agents_norm
_agents_tmp
_bg_here_raw
_date_fmt
_dir_phys
_fs_make
_fs_reusable
_lookup_raw
_mark_terminal
_notify_darwin
_notify_linux
_nu_in_range
_row_present_raw
_seat_ancestry
_short_backgrounded
_short_hexid
_state_sid
_strip_csi
alert_finished
alert_once
alert_spent
arm_watch
bg_here
die
epoch
file_dispatchable
file_exists
file_ident
file_is_symlink
file_readable
fs_file_init
fs_get
fs_novalue_set
fs_why_set
gen_is_ours
gen_may_write
lease_file_of
lease_probe
legacy_kind
legacy_lock_present
lock_drop
lock_hold
lock_take
lock_tool
logline
lookup
mtime_of
notify
now_utc
path_state
prelaunch_die
read_agents
rec_clear
rec_get_raw
rec_has
rec_num
rec_ok_value
rec_put
rec_read
rec_set
rec_stamp
reconcile_watch
retire_self
row_present
shq
timed_to_file
transcript_for
verify_lock
watch_is_alive
watch_once
CSFNS
# `fs_why_set` (round 6 micro-review 2) is in the closure because `fs_get` calls
# it while a claim descriptor may be held. It is admitted deliberately: it does
# no I/O at all -- assignments and a `case` -- so it contributes ZERO primitive
# sites, which is why the totals did not move when it joined -- they were
# 63/33/13/4/13 then, and the assertions above carry the CURRENT numbers, which
# micro-review 5 moved (see the end of this note).
#   Micro-review 4 added two more, and this guard is what reported them -- it
# failed run 9 naming both, which is the second time it has caught this round's
# own fixes. Both were reviewed rather than waved through, and neither was
# admitted by narrowing the guard:
#   `fs_novalue_set` is the sibling constructor for the "probe returned success
# and printed nothing" shape. Same argument as `fs_why_set` exactly: ONE
# assignment, no command, no fork, no I/O -- zero primitive sites.
#   `_nu_in_range` is `now_utc`'s range arm, and `now_utc` is itself a claim site
# (`CLAIM:d`), so it inherits the closure. Its body is `[ "$((10#$1))" -ge "$2" ]
# && [ … -le "$3" ]`: arithmetic expansion and `test`, both shell builtins in
# every shell this runs under, so it too forks nothing and contributes zero
# primitive sites. The totals were still 63/33/13/4/13 after those two joined,
# with the membership grown by two, and case CS asserts the totals independently
# of this list.
#   MICRO-REVIEW 5 IS THE ONE THAT MOVED THEM, to 64/33/14/4/13, and this note
# said 63 for a micro-review afterwards (round 6 micro-review 6). The new site is
# `verify_lock`'s probe of its own descriptor, `( true >&9 )` -- a redirection,
# so it is a `b`: it opens the descriptor for writing and writes no bytes, which
# is what separates it from the other `>&9` in this file, a real write classified
# `d`. The assertions above are the numbers; these sentences are the argument for
# them, and when the two disagree it is the sentences that are wrong.
#   `_strip_csi` JOINED AT 65/34/14/4/13, and it did not join because it was
# written -- it joined because the census learned to see it. `called()` skipped
# any line matching a definition, which is correct for a multi-line header and
# wrong for a ONE-LINE function, whose body shares that line: every call such a
# body made was invisible, so the callee never entered the closure. `_strip_csi`
# is called by `_short_backgrounded` and `_short_hexid`, both one-liners and both
# already in the closure, so its `awk` has been forking while fd 9 is held the
# whole time, uncounted. The only symptom was a STRAY TAG -- the census reporting
# a tag that no site read, which is the residue this guard was built to notice.
# Deleting the tag would have silenced the report and left the fork uncounted;
# the walk was fixed instead, and the `a` it contributes is the fork it always
# was. Two other one-liners call functions (`rec_has`, `rec_clear`); their
# callees already reached the closure by other paths, so membership grew by
# exactly one and the pre-fix file censuses identically under both walks.
#   RETIREMENT ADDED FOUR, 65/34/14/4/13 -> 69/37/15/4/13, and the four are the
# whole of `retire_self`'s reach under the claim: `_state_sid` (one `node`, the
# state.json session id), `_seat_ancestry` (one `ps` piped to one `awk`, the
# ancestry walk) and `_mark_terminal` (one `node`, the sentinel and the state
# rename) are its three bounded probes, each contributing exactly one `a`; the
# fifteenth `b` is the `nohup` that detaches the killer. `retire_self` itself
# contributes no site -- every filesystem question it asks goes through `fs_get`,
# which is why the three helpers are `a` and not `d`.
#   `retire_exec` is DELIBERATELY ABSENT and its absence is the point: it runs in
# a separate process reached through `"$0" --retire-exec`, so nothing it does --
# the `sleep`s, the `kill`s, the rollback `mv` -- happens while this process
# holds fd 9. If it ever appears in this list, something has started calling it
# in-process and its unbounded waits have moved inside the claim.
cs_new="$(comm -23 "$CS_LIVE" "$CS_WANT" | tr '\n' ' ')"
cs_gone="$(comm -13 "$CS_LIVE" "$CS_WANT" | tr '\n' ' ')"
[ -z "$cs_new$cs_gone" ] || { echo "FAIL[CS]: the claim closure changed -- entered: ${cs_new:-none}/ left: ${cs_gone:-none}. Every function in it runs while fd 7, 8 or 9 is held, so this is a review decision, not a rename"; fail=1; }

# 6. THE ALLOWLIST IS A CHECKED INVARIANT. The census matches forks by a list of
#    binary names, which is blind to a binary that is used and not listed --
#    exactly the shape of hole this case exists to close. `--audit` re-scans the
#    decoded source for a curated set of common commands and fails on any that
#    is used and unlisted. (It found two: `dirname` and `uname`, both used,
#    neither listed, neither in the closure today.)
cs_audit="$(node "$CENSUS" "$SCRIPT" --audit 2>&1)"; cs_ac=$?
assert_eq "$cs_ac" "0" CS
assert_contains "AUDIT-CLEAN" "$cs_audit" CS

# ---- CS's negative controls. A census that cannot report a defect is not a
# control, and this loop has now found that shape ten times. Each of these
# injects one defect into a COPY and requires the census to say so.
CS_INJECT='  cat /dev/null >/dev/null 2>&1 || true'

# The population numbers the controls below assert are DERIVED from a baseline run,
# not written down. A literal here is the same stale-constant defect this loop has
# been chasing in the hook: it drifts on the next census-touching change, and the
# only symptom is a control that has quietly stopped isolating anything. What the
# controls actually claim is a DELTA -- (a) adds one site, (d) and (g) add none --
# and a delta is what they should say.
CS_POP="$(node "$CENSUS" "$SCRIPT" 2>&1 | sed -n 's/^population: \([0-9][0-9]*\) primitive sites$/\1/p' | head -1)"
[ -n "$CS_POP" ] || { echo "FAIL[CS]: the census printed no 'population: <n> primitive sites' line for the unmodified hook, so every population control below is vacuous"; fail=1; CS_POP=0; }
CS_POP1=$(( CS_POP + 1 ))

# (a) an untagged primitive INSIDE the closure is reported, and counted.
CSA="$tmp/cr-a.sh"
awk -v ins="$CS_INJECT" '{print} /^lock_tool\(\) \{$/{print ins}' "$SCRIPT" > "$CSA"
grep -q 'cat /dev/null' "$CSA" || { echo "FAIL[CS]: the untagged-site injection did not land, so control (a) asserts nothing"; fail=1; }
csa_out="$(node "$CENSUS" "$CSA" 2>&1)"
assert_contains "UNTAGGED: 1" "$csa_out" CS
assert_contains "population: $CS_POP1 primitive sites" "$csa_out" CS

# (b) a tag FLIPPED is visible in the counts, which is what makes assertion 2
#     load-bearing rather than decorative.
CSB="$tmp/cr-b.sh"
awk '!d && sub(/# CLAIM:a/, "# CLAIM:d") { d=1 } { print }' "$SCRIPT" > "$CSB"
cmp -s "$SCRIPT" "$CSB" && { echo "FAIL[CS]: the tag-flip injection did not land, so control (b) asserts nothing"; fail=1; }
csb_out="$(node "$CENSUS" "$CSB" 2>&1)"
assert_contains "a: $(( $(cs_q a) - 1 ))" "$csb_out" CS
assert_contains "d: $(( $(cs_q d) + 1 ))" "$csb_out" CS

# (c) a region marker REMOVED is a refusal (exit 2), not a smaller population.
CSC="$tmp/cr-c.sh"
grep -v 'CLAIM-REGION-END watch' "$SCRIPT" > "$CSC"
[ "$(wc -l < "$CSC")" -lt "$(wc -l < "$SCRIPT")" ] || { echo "FAIL[CS]: the marker-removal injection did not land, so control (c) asserts nothing"; fail=1; }
node "$CENSUS" "$CSC" >/dev/null 2>&1; csc_rc=$?
assert_eq "$csc_rc" "2" CS

# (d) the closure is a CLOSURE, not "every line in the file": the same untagged
#     primitive, injected into a function nothing in a claim region reaches, is
#     correctly NOT counted. Without this the tags would be coverage of nothing.
CSD="$tmp/cr-d.sh"
awk -v ins="$CS_INJECT" '{print} /^file_nlink\(\) \{/{print ins}' "$SCRIPT" > "$CSD"
cmp -s "$SCRIPT" "$CSD" && { echo "FAIL[CS]: the outside-the-closure injection did not land, so control (d) asserts nothing"; fail=1; }
csd_out="$(node "$CENSUS" "$CSD" 2>&1)"
assert_contains "population: $CS_POP primitive sites" "$csd_out" CS
assert_missing "UNTAGGED" "$csd_out" CS

# (e) the audit itself can fail: an unlisted binary inside the file is named.
CSE="$tmp/cr-e.sh"
awk '{print} /^lock_tool\(\) \{$/{print "  ls >/dev/null 2>&1 || true"}' "$SCRIPT" > "$CSE"
cmp -s "$SCRIPT" "$CSE" && { echo "FAIL[CS]: the unlisted-binary injection did not land, so control (e) asserts nothing"; fail=1; }
cse_out="$(node "$CENSUS" "$CSE" --audit 2>&1)"; cse_rc=$?
assert_eq "$cse_rc" "3" CS
assert_contains "UNLISTED" "$cse_out" CS
assert_contains "ls" "$cse_out" CS

# (f) ...and the 'a' verification can fail: one ordinary call site to a probe
#     that is only ever supposed to run under a deadline is named, with the
#     function and the line, and the census refuses (exit 2).
CSF="$tmp/cs-f.sh"
awk '{print} /^watch_once\(\) \{$/{print "  file_readable /dev/null >/dev/null || true"}' "$SCRIPT" > "$CSF"
cmp -s "$SCRIPT" "$CSF" && { echo "FAIL[CS]: the unbounded-call injection did not land, so control (f) asserts nothing"; fail=1; }
csf_out="$(node "$CENSUS" "$CSF" 2>&1)"; csf_rc=$?
assert_eq "$csf_rc" "2" CS
assert_contains "a-UNVERIFIED: 1" "$csf_out" CS
assert_contains "file_readable" "$csf_out" CS

# (g) ...and the OTHER direction of the same question: a tag that no site reads.
#     An untagged site is loud -- it lands in UNTAGGED, which the assertion above
#     floors at zero. A tag whose site moved out from under it is silent: the
#     population just comes back one smaller, which is indistinguishable from a
#     site that was legitimately deleted. That is not hypothetical on this branch
#     -- `SPAWN SITE 7` became decorative in exactly that way when its node call
#     moved into a helper (case CM). The stray is the residue that tells the two
#     apart, and it is also how a tag comes to sit above the WRONG line.
CSG="$tmp/cs-g.sh"
awk '{print} /^watch_once\(\) \{$/{print "  # CLAIM:d"; print "  # a comment, not a site"}' "$SCRIPT" > "$CSG"
cmp -s "$SCRIPT" "$CSG" && { echo "FAIL[CS]: the orphan-tag injection did not land, so control (g) asserts nothing"; fail=1; }
csg_out="$(node "$CENSUS" "$CSG" 2>&1)"; csg_rc=$?
assert_eq "$csg_rc" "2" CS
assert_contains "stray-TAGS: 1" "$csg_out" CS
assert_contains "no primitive site reads" "$csg_out" CS
# ...and the population is otherwise untouched, so the control is isolating the
# stray rather than knocking the whole census over.
assert_contains "population: $CS_POP primitive sites" "$csg_out" CS

# (h) the filetest CLASS is enumerated, not sampled -- in BOTH directions.
#     Every control above counts the POPULATION, and the population is counted
#     per LINE. So widening the operator class was invisible to all of them: the
#     one line that motivated the widening -- `[ ! -h "$1" ] && [ -f "$1" ] &&
#     [ -O "$1" ]` -- still matches on `-f` under the old narrow class, and the
#     mutation that reverts the widening SURVIVED a full suite run. A class is a
#     claim about every operator IN it and every operator OUT of it, so state the
#     class here, independently of the census, and check it both ways.
#
#     The list below is deliberately a literal and is NOT derived from the census:
#     deriving it would shrink with the census and the control would pass again,
#     which is exactly the failure being fixed. It is a specification -- every
#     POSIX unary test that has to touch the filesystem -- and the census is the
#     implementation measured against it.
CS_FSOPS='r f d L s x e w b c g G h k O p S u N'   # stats something
CS_NONFS='z n o t v'                               # string, shell-option, fd
# The cheap half: the census's own character class must be exactly this set.
# Catches drift in either direction before a single census is run.
CS_CLASS="$(sed -n "s/^  \['filetest'.*-\[\([A-Za-z]*\)\].*/\1/p" "$CENSUS" | head -1)"
[ -n "$CS_CLASS" ] || { echo "FAIL[CS]: could not read the filetest character class out of $CENSUS -- control (h) would be vacuous"; fail=1; }
cs_sortchars() { printf '%s' "$1" | tr -d ' ' | fold -w1 | sort | tr -d '\n'; }
[ "$(cs_sortchars "$CS_CLASS")" = "$(cs_sortchars "$CS_FSOPS")" ] || {
  echo "FAIL[CS]: the census filetest class is '$CS_CLASS' but the filesystem-touching operators are '$CS_FSOPS' -- one of the two moved"; fail=1; }
# The half that drives the real path: each operator must actually ENTER the
# population on a line where it is the only primitive, and each non-filesystem
# test must stay out. A set comparison alone is a claim about a string.
csh_n=0
for _op in $CS_FSOPS; do
  csh_n=$(( csh_n + 1 ))
  CSH="$tmp/cs-h.sh"
  awk -v ins="  [ -$_op \"\$1\" ] || true" '{print} /^lock_tool\(\) \{$/{print ins}' "$SCRIPT" > "$CSH"
  cmp -s "$SCRIPT" "$CSH" && { echo "FAIL[CS]: the -$_op injection did not land, so that operator is not being tested"; fail=1; continue; }
  case "$(node "$CENSUS" "$CSH" 2>&1)" in
    *"population: $CS_POP1 primitive sites"*) ;;
    *) echo "FAIL[CS]: a line whose only primitive is [ -$_op ] did not enter the population -- the filetest class is a SAMPLE of the operators, not the class"; fail=1 ;;
  esac
done
[ "$csh_n" = 19 ] || { echo "FAIL[CS]: the filetest enumeration ran $csh_n operators, not the 19 it claims -- the denominator moved"; fail=1; }
for _op in $CS_NONFS; do
  CSH="$tmp/cs-h.sh"
  awk -v ins="  [ -$_op \"\$1\" ] || true" '{print} /^lock_tool\(\) \{$/{print ins}' "$SCRIPT" > "$CSH"
  case "$(node "$CENSUS" "$CSH" 2>&1)" in
    *"population: $CS_POP primitive sites"*) ;;
    *) echo "FAIL[CS]: [ -$_op ] touches no filesystem but entered the population -- the class is 'anything in brackets'"; fail=1 ;;
  esac
done

# ---- CT. the per-process scratch file cannot be SQUATTED with a symlink ---
# `fs_get` routes every filesystem probe through one fixed path,
# "$TMPDIR/handoff-fs.<pid>.<n>". A fixed name is a PREDICTABLE name and `>`
# follows symlinks, so on a shared /tmp anyone who creates that name first as a
# link has the file it points at truncated by a probe that only meant to read
# something. The design this replaced bought unpredictability from `mktemp`;
# this one spent it, so the property is pinned here instead of asserted in a
# comment.
#
# The pid is not knowable before launch, so a wrapper publishes its own `$$` and
# waits for a go file; `exec` keeps that pid, so the name the test squats is the
# name the hook will actually try. `$BASHPID` would be the obvious way to do
# this from a subshell -- and it is empty in bash 3.2, which is what /bin/bash
# is on this machine, so the wrapper is a real file rather than a `( )`.
CTD="$tmp/ct"; mkdir -p "$CTD/a" "$CTD/b" "$CTD/c"
CTHO="$(NEWHO squat)"; CTREC="$CTHO.dispatch"
live_json "running"; GOF "$CTHO" "squatted scratch" >/dev/null 2>&1
cat > "$CTD/wrap.sh" <<'CTWRAP'
echo $$ > "$1/pid"
while [ ! -f "$1/go" ]; do sleep 0.05; done
export TMPDIR="$1"
exec bash "$2" --watch-once "$3"
CTWRAP

ct_run() { # $1=hook script  $2=dir (also TMPDIR)  $3=symlink target, "" for none
  _cd="$2"
  bash "$CTD/wrap.sh" "$_cd" "$1" "$CTREC" >"$_cd/out" 2>&1 &
  _cp=$!
  _ci=0
  while [ ! -s "$_cd/pid" ] && [ "$_ci" -lt 200 ]; do sleep 0.05; _ci=$((_ci + 1)); done
  _cpid="$(cat "$_cd/pid" 2>/dev/null)"
  [ -n "$_cpid" ] || { echo "FAIL[CT]: the wrapper never published its pid, so nothing was squatted"; fail=1; }
  [ -z "$3" ] || ln -s "$3" "$_cd/handoff-fs.$_cpid.0"
  : > "$_cd/go"
  wait "$_cp"; CT_CODE=$?
}

# (1) the control: same record, same mode, nothing squatted.
ct_run "$SCRIPT" "$CTD/a" ""
ct_base=$CT_CODE

# (2) the same run with the scratch name pre-created as a symlink at a canary.
printf 'CANARY\n' > "$CTD/canary"
ct_run "$SCRIPT" "$CTD/b" "$CTD/canary"
assert_eq "$(cat "$CTD/canary" 2>/dev/null)" "CANARY" CT
assert_eq "$CT_CODE" "$ct_base" CT

# (3) the negative control, without which (2) shows only that the run works at
#     all: drop noclobber from the creation and the identical squat clobbers the
#     canary. If this ever stops clobbering, (2) has stopped meaning anything and
#     wants re-deriving rather than deleting.
CTMUT="$tmp/ct-mut.sh"
sed 's/{ set -C; : > /{ : > /' "$SCRIPT" > "$CTMUT"
cmp -s "$SCRIPT" "$CTMUT" && { echo "FAIL[CT]: the noclobber mutation did not land, so control (3) asserts nothing"; fail=1; }
printf 'CANARY\n' > "$CTD/canary2"
ct_run "$CTMUT" "$CTD/c" "$CTD/canary2"
case "$(cat "$CTD/canary2" 2>/dev/null)" in
  *CANARY*) echo "FAIL[CT]: with noclobber dropped the squatted symlink did NOT reach the canary -- control (2) is not testing what it claims"; fail=1 ;;
esac

# ============================== SHAPE C ====================================
# Four episodic `alerted_*` keys whose CLEAR did not match the transition the
# `alert_once` header claims for them. Every one of the four is invisible to a
# single poll: it takes a raise, a recovery the clear does not recognise, and a
# second raise that is then silent. So these are MATRICES over poll sequences,
# not instances — a one-poll test of any of them passes against the bug.
#
# All four were reproduced against the pre-fix hook before anything was edited,
# each with the same poll re-run marker-cleared as its control, because a silent
# poll is otherwise indistinguishable from a process that died (C1's first two
# reproduction attempts printed an empty notification list that was in fact a
# `die` at the startup gate). The controls live on in CU/CV/CW below.

# ---- CU. blocked and unknown are INDEPENDENT episodes ----------------------
# Both markers were only ever cleared inside the LIVE arm, which each of the two
# other arms `return`s before reaching. So the state machine could only leave
# either episode by passing THROUGH live: blocked -> unknown -> blocked nudged
# once and then went quiet, which is precisely the sequence a successor that is
# flapping between "needs you" and "we cannot tell" produces.
#
# The state used for the unknown arm is read against the hook's own tables by
# value. A literal here would silently stop testing the unknown arm the day
# someone adds it to LIVE_STATES.
CU_UNK="wedged"
_culs="$(sed -n 's/^LIVE_STATES="\(.*\)"$/\1/p' "$SCRIPT" | head -1)"
_cuds="$(sed -n 's/^DONE_STATES="\(.*\)"$/\1/p' "$SCRIPT" | head -1)"
if [ -z "$_culs" ] || [ -z "$_cuds" ]; then
  echo "FAIL[CU]: cannot read LIVE_STATES/DONE_STATES from the hook -- the unknown-arm state below would be a guess"; fail=1
fi
case " $_culs $_cuds " in
  *" $CU_UNK "*) echo "FAIL[CU]: '$CU_UNK' is a recognised state, so the unknown arm is never reached and this matrix asserts nothing"; fail=1 ;;
esac
# blocked must NOT be live, or the blocked arm is unreachable for the same reason.
case " $_culs " in *" blocked "*) echo "FAIL[CU]: 'blocked' is in LIVE_STATES; the blocked arm is unreachable"; fail=1 ;; esac

cu_state_of() { # matrix label -> the state string the agents list reports
  case "$1" in
    blocked) printf 'blocked' ;;
    unknown) printf '%s' "$CU_UNK" ;;
    live)    printf 'running' ;;
  esac
}
cu_alert_of() { # a poll's whole output -> which of the two nudges it carried
  _cub=0; _cuu=0
  case "$1" in *"successor $SHORT is blocked and needs input"*) _cub=1 ;; esac
  case "$1" in *"successor $SHORT is listed but reports"*) _cuu=1 ;; esac
  if [ "$_cub" = 1 ] && [ "$_cuu" = 1 ]; then printf 'both'
  elif [ "$_cub" = 1 ]; then printf 'blocked'
  elif [ "$_cuu" = 1 ]; then printf 'unknown'
  else printf 'none'; fi
}
cu_want() { # $1=previous state $2=this state -> the nudge this ENTRY must carry
  # One alert per ENTRY into an episode, none for staying in one, none for live.
  # `both` is never expected: the two predicates are mutually exclusive by
  # construction in the hook, which is why there is no runtime assertion there —
  # it could not fire — and why the exclusion is pinned HERE instead, where a
  # rewrite that made the arms overlap would show up as 'both'.
  [ "$2" = live ] && { printf 'none'; return; }
  [ "$1" = "$2" ] && { printf 'none'; return; }
  printf '%s' "$2"
}
cu_poll() { # $1=record $2=state label -> the nudge, on stdout
  live_json "$(cu_state_of "$2")"
  cu_alert_of "$(bash "$SCRIPT" --watch-once "$1" 2>&1)"
}
cu_n=0
for _cufrom in blocked unknown live; do
  for _cuto in blocked unknown live; do
    CUHO="$(NEWHO "cu-$_cufrom-$_cuto")"; CUREC="$CUHO.dispatch"
    live_json "running"; GOF "$CUHO" "cu" >/dev/null 2>&1; : > "$transcript"
    _cu1="$(cu_poll "$CUREC" "$_cufrom")"
    # The first poll is this cell's own control: if the ENTRY from a fresh record
    # does not nudge, the second poll's silence proves nothing about clearing.
    _cuw1="$(cu_want live "$_cufrom")"
    [ "$_cu1" = "$_cuw1" ] || { echo "FAIL[CU]: entering '$_cufrom' from a fresh record nudged '$_cu1', expected '$_cuw1' -- the $_cufrom -> $_cuto cell below asserts nothing"; fail=1; }
    _cu2="$(cu_poll "$CUREC" "$_cuto")"
    _cuw2="$(cu_want "$_cufrom" "$_cuto")"
    [ "$_cu2" = "$_cuw2" ] || { echo "FAIL[CU]: $_cufrom -> $_cuto nudged '$_cu2', expected '$_cuw2'"; fail=1; }
    cu_n=$(( cu_n + 1 ))
  done
done
assert_eq "$cu_n" "9" CU

cu_cycle() { # $1 $2 $3 -- re-entry after a detour that never touches live
  CUHO="$(NEWHO "cu3-$1-$2-$3")"; CUREC="$CUHO.dispatch"
  live_json "running"; GOF "$CUHO" "cu3" >/dev/null 2>&1; : > "$transcript"
  _cyc1="$(cu_poll "$CUREC" "$1")"
  [ "$_cyc1" = "$1" ] || { echo "FAIL[CU]: the $1 -> $2 -> $3 cycle did not nudge on its FIRST entry ('$_cyc1') -- its third poll asserts nothing"; fail=1; }
  cu_poll "$CUREC" "$2" >/dev/null
  _cyc3="$(cu_poll "$CUREC" "$3")"
  [ "$_cyc3" = "$3" ] || { echo "FAIL[CU]: $1 -> $2 -> $3 nudged '$_cyc3' on re-entry, expected '$3' -- the '$3' marker was left standing by a detour that never passed through a live state"; fail=1; }
}
# The two three-cycles that carry the finding: neither passes through live, so
# under the old ordering each marker survived the detour and the second entry
# was announced to nobody.
cu_cycle blocked unknown blocked
cu_cycle unknown blocked unknown

# ---- CV. recdegraded clears on the RECORD read, not on the agents list -----
# `alerted_recdegraded` was cleared after `read_agents` succeeded — two
# successes to clear a marker whose own predicate needs one. A record that
# recovered straight into an agents outage kept the marker, and the NEXT record
# outage was silent.
#
# The injection hangs the Nth `session_id` read WITHIN ONE PROCESS rather than
# every read, and that is not a convenience: handoff.sh validates the record at
# startup (`rec_read session_id || die`) before the mode branch, so hanging every
# read kills a `--watch-once` process at that gate and the recdegraded alert is
# never reached. The real watcher validates ONCE at arm time and then calls
# watch_once in-process, so "startup read succeeds, poll-time read times out" is
# the faithful shape of a mid-flight record outage. Injecting any other way
# asserts on a process that died before the code under test.
CVD="$tmp/cv"; mkdir -p "$CVD/bin"
cat > "$CVD/bin/sed" <<'CVSH'
#!/bin/sh
# Paths are compared CANONICALLY. macOS mktemp hands out /var/folders/... and the
# hook resolves the record to /private/var/folders/..., so an exact-string
# comparison never matches and the shim becomes a control that cannot fail —
# which is what it silently was on this harness's first run.
_n() { case "$1" in /private/*) printf '%s' "${1#/private}" ;; *) printf '%s' "$1" ;; esac; }
_want="$(_n "$CV_REC")"
_hit=0
for a in "$@"; do [ "$(_n "$a")" = "$_want" ] && _hit=1; done
case "$*" in *"s/^session_id=//p"*) ;; *) _hit=0 ;; esac
if [ "$_hit" = 1 ] && [ -f "$CV_HANG" ]; then
  _c=$(( $(cat "$CV_COUNT" 2>/dev/null || echo 0) + 1 ))
  printf '%s' "$_c" > "$CV_COUNT"
  [ "$_c" -ge 2 ] && sleep 8
fi
exec /usr/bin/sed "$@"
CVSH
chmod +x "$CVD/bin/sed"
# 2s, not 1: every UNHUNG probe in these polls has to finish inside the deadline,
# and a 1s bound makes a loaded machine's fork+exec of stat look like a timeout.
# The hang sleeps well past it either way.
CV_FS=2
cv_poll() { # $1=record  $2=record read: ok|fail  $3=agents list: ok|bad
  rm -f "$CVD/count"          # the counter is PER POLL: one process, one poll
  if [ "$3" = bad ]; then printf 'not json at all\n' > "$SHIM_AGENTS"; else live_json "running"; fi
  if [ "$2" = fail ]; then : > "$CVD/hang"; else rm -f "$CVD/hang"; fi
  CV_OUT="$(env CV_REC="$1" CV_HANG="$CVD/hang" CV_COUNT="$CVD/count" \
                PATH="$CVD/bin:$PATH" CLAUDE_HANDOFF_FS_TIMEOUT="$CV_FS" \
              bash "$SCRIPT" --watch-once "$1" 2>&1)"
  rm -f "$CVD/hang"
}
cv_marker() { sed -n 's/^alerted_recdegraded=//p' "$1" | tail -1; }
for _cvrec in ok fail; do
  for _cvag in ok bad; do
    CVHO="$(NEWHO "cv-$_cvrec-$_cvag")"; CVREC="$CVHO.dispatch"
    live_json "running"; GOF "$CVHO" "cv" >/dev/null 2>&1; : > "$transcript"
    # Raise. Also this cell's control that the shim FIRES: without the alert
    # here, every marker assertion below is about a poll that never happened.
    cv_poll "$CVREC" fail ok
    assert_contains "cannot read the dispatch record" "$CV_OUT" "CV/$_cvrec-$_cvag raise"
    assert_eq "$(cv_marker "$CVREC")" "1" "CV/$_cvrec-$_cvag raise"
    cv_poll "$CVREC" "$_cvrec" "$_cvag"
    # The marker's predicate is the RECORD read alone. The agents outcome is a
    # different observation and cannot hold this episode open.
    if [ "$_cvrec" = ok ]; then _cvwant=0; else _cvwant=1; fi
    [ "$(cv_marker "$CVREC")" = "$_cvwant" ] || {
      echo "FAIL[CV]: record=$_cvrec agents=$_cvag left alerted_recdegraded='$(cv_marker "$CVREC")', expected '$_cvwant' -- the record read is what ends this episode"; fail=1; }
    if [ "$_cvrec" = ok ]; then
      # And the consequence that is the actual bug: the next outage must be said.
      cv_poll "$CVREC" fail ok
      assert_contains "cannot read the dispatch record" "$CV_OUT" "CV/$_cvrec-$_cvag second outage"
    fi
  done
done

# ---- CW. beatdegraded: present iff BOTH heartbeat sources are unobservable --
# The raise is `FSFAIL=1 && BEAT=0`; the clear tested `FSFAIL=0`, which is
# narrower than the raise's negation. One source answering while the other timed
# out matched neither, so a standing marker survived the half-recovery and the
# next total blackout was silent.
CWD_="$tmp/cw"; mkdir -p "$CWD_/bin"
cat > "$CWD_/bin/stat" <<'CWSH'
#!/bin/sh
_n() { case "$1" in /private/*) printf '%s' "${1#/private}" ;; *) printf '%s' "$1" ;; esac; }
_wh="$(_n "$CW_HO")"; _wt="$(_n "$CW_TR")"
for a in "$@"; do
  _a="$(_n "$a")"
  [ "$_a" = "$_wh" ] && [ -f "$CW_HANG_HO" ] && sleep 8
  [ "$_a" = "$_wt" ] && [ -f "$CW_HANG_TR" ] && sleep 8
done
exec /usr/bin/stat "$@"
CWSH
chmod +x "$CWD_/bin/stat"
cw_poll() { # $1=record $2=handoff file  $3=transcript stat: ok|to  $4=handoff stat: ok|to
  if [ "$3" = to ]; then : > "$CWD_/tr"; else rm -f "$CWD_/tr"; fi
  if [ "$4" = to ]; then : > "$CWD_/ho"; else rm -f "$CWD_/ho"; fi
  CW_OUT="$(env CW_HO="$2" CW_TR="$transcript" CW_HANG_HO="$CWD_/ho" CW_HANG_TR="$CWD_/tr" \
                PATH="$CWD_/bin:$PATH" CLAUDE_HANDOFF_FS_TIMEOUT=2 \
              bash "$SCRIPT" --watch-once "$1" 2>&1)"
  rm -f "$CWD_/tr" "$CWD_/ho"
}
cw_marker() { sed -n 's/^alerted_beatdegraded=//p' "$1" | tail -1; }
for _cwtr in ok to; do
  for _cwho in ok to; do
    CWHO="$(NEWHO "cw-$_cwtr-$_cwho")"; CWREC="$CWHO.dispatch"
    live_json "running"; GOF "$CWHO" "cw" >/dev/null 2>&1; : > "$transcript"
    # Raise, and the control that both hangs land.
    cw_poll "$CWREC" "$CWHO" to to
    assert_contains "cannot stat successor" "$CW_OUT" "CW/$_cwtr-$_cwho raise"
    assert_eq "$(cw_marker "$CWREC")" "1" "CW/$_cwtr-$_cwho raise"
    cw_poll "$CWREC" "$CWHO" "$_cwtr" "$_cwho"
    # Both directions in one expectation: the episode is "no heartbeat signal is
    # observable AT ALL", so a single answering source ends it.
    if [ "$_cwtr" = to ] && [ "$_cwho" = to ]; then _cwwant=1; else _cwwant=0; fi
    [ "$(cw_marker "$CWREC")" = "$_cwwant" ] || {
      echo "FAIL[CW]: transcript=$_cwtr handoff=$_cwho left alerted_beatdegraded='$(cw_marker "$CWREC")', expected '$_cwwant'"; fail=1; }
    if [ "$_cwwant" = 0 ]; then
      cw_poll "$CWREC" "$CWHO" to to
      assert_contains "cannot stat successor" "$CW_OUT" "CW/$_cwtr-$_cwho blackout after half-recovery"
    fi
  done
done

# ---- CX. the generation fence belongs at the WRITE, not before delivery ----
# `alert_once` checked `gen_is_ours` before `notify` and wrote the marker after
# it. `notify` is bounded by FS_TIMEOUT_SEC at the BACKEND, not instant, so a
# `--force` re-dispatch that truncates the record and arms a new generation
# inside that window had the superseded watcher's FLAT `alerted_*` land in the
# NEW record — and the new watcher's first alert of that kind was then suppressed
# by a marker belonging to a watcher that no longer existed.
#
# This case cannot use CLAUDE_HANDOFF_NOTIFY_DEBUG: that seam returns 0 without
# ever reaching the backend, so there is no window to re-dispatch inside. It puts
# a SLEEPING notifier on PATH instead, with FS_TIMEOUT_SEC well above the sleep
# so delivery still SUCCEEDS — the bug needs a delivery that is slow, not one
# that fails.
CXD="$tmp/cx"; mkdir -p "$CXD/bin"
case "$(uname -s)" in Darwin) CX_BIN=osascript ;; *) CX_BIN=notify-send ;; esac
cat > "$CXD/bin/$CX_BIN" <<'CXSH'
#!/bin/sh
: > "$CX_DELIVERING"
sleep "${CX_SLEEP:-3}"
exit 0
CXSH
chmod +x "$CXD/bin/$CX_BIN"
cx_run() { # $1=script under test  $2=tag -> CX_MARK, CX_REPOLL
  _cxho="$(NEWHO "$2")"; _cxrec="$_cxho.dispatch"
  live_json "running"; GOF "$_cxho" "$2" >/dev/null 2>&1; : > "$transcript"
  live_json "blocked"
  printf 'watch_gen=g-cx-1\n' >> "$_cxrec"
  cp "$_cxrec" "$CXD/rec-orig"
  rm -f "$CXD/delivering"
  ( env -u CLAUDE_HANDOFF_NOTIFY_DEBUG CX_DELIVERING="$CXD/delivering" CX_SLEEP=3 \
        PATH="$CXD/bin:$PATH" CLAUDE_HANDOFF_FS_TIMEOUT=10 \
      bash "$1" --watch-once "$_cxrec" --watch-gen g-cx-1 >/dev/null 2>&1 ) & _cxpid=$!
  _cxw=0
  while [ ! -f "$CXD/delivering" ] && [ "$_cxw" -lt 200 ]; do sleep 0.1; _cxw=$(( _cxw + 1 )); done
  if [ ! -f "$CXD/delivering" ]; then
    echo "FAIL[CX/$2]: the notifier never ran, so nothing was re-dispatched underneath a delivery in flight -- this case asserts nothing"; fail=1
    kill -9 "$_cxpid" 2>/dev/null; wait "$_cxpid" 2>/dev/null
    CX_MARK="SHIM-NEVER-RAN"; CX_REPOLL=""; return 0
  fi
  # The re-dispatch, mid-delivery: `cp` truncates and rewrites exactly the way
  # `--force` does, and the new generation is armed on top of it.
  cp "$CXD/rec-orig" "$_cxrec"; printf 'watch_gen=g-cx-2\n' >> "$_cxrec"
  wait "$_cxpid" 2>/dev/null
  CX_MARK="$(sed -n 's/^alerted_blocked=//p' "$_cxrec" | tail -1)"
  # What the marker COSTS, stated as behaviour rather than as a record byte: the
  # new generation's first blocked nudge.
  CX_REPOLL="$(bash "$1" --watch-once "$_cxrec" --watch-gen g-cx-2 2>&1)"
}
cx_run "$SCRIPT" cx
assert_eq "$CX_MARK" "" CX
assert_contains "successor $SHORT is blocked and needs input" "$CX_REPOLL" CX

# The negative control. Re-checking the fence at the write is only worth
# something if NOT re-checking it lands the marker: without this, CX passes
# against a hook that never writes the marker at all, and against a harness whose
# re-dispatch never landed inside the window.
CXMUT="$tmp/handoff-cx-unfenced.sh"
sed 's/if gen_may_write "._r"; then rec_set/if true; then rec_set/' "$SCRIPT" > "$CXMUT"
if cmp -s "$SCRIPT" "$CXMUT"; then
  echo "FAIL[CX]: the unfenced mutant is identical to the hook -- the fence at the write moved or was rewritten, and this control cannot fail"; fail=1
else
  cx_run "$CXMUT" cx-unfenced
  [ "$CX_MARK" = 1 ] || { echo "FAIL[CX]: with the second fence removed the flat marker did NOT land ('$CX_MARK'), so the fenced assertion above proves nothing about the fence"; fail=1; }
  assert_missing "successor $SHORT is blocked and needs input" "$CX_REPOLL" "CX control"
fi
rm -f "$CXMUT"
live_json "running"

# ---- CY. a refusal BEFORE the launcher is RETRYABLE, and says which ------
# Every dispatch-boundary fence dies before `claude --bg` is invoked, so nothing
# was launched -- and every one of their messages told the operator exactly that.
# The record was left at `launching` anyway, which is the state the duplicate-
# dispatch guard refuses without --force: the message promised a retry that the
# next run then refused, and the only way out was --force, the flag that exists
# to override a possibly-live successor (round-5 correctness #4). "Nothing was
# launched" now has its own value.
CYHO="$(NEWHO prelaunch)"; CYREC="$CYHO.dispatch"
rm -f "$SHIM_SPAWNS"; live_json "running"
printf 'state=verified\nsession_id=99999999\n' > "$CYREC"   # a PREV nobody lists: the agents read runs while still pre-launch
printf '%s' "$CYHO" > "$SHIM_HO_REMOVE"
out="$(GOF "$CYHO" "vanishing" 2>&1)"; code=$?
[ "$code" != "0" ] || { echo "FAIL[CY]: a handoff file removed at the boundary must refuse"; fail=1; }
assert_contains "was removed, emptied or made unreadable" "$out" CY
assert_no_file "$SHIM_SPAWNS" CY                      # nothing was launched...
assert_rec_last "$CYREC" state prelaunch_failed CY    # ...and the record says so
assert_contains "a plain retry is safe" "$out" CY
# The behavioural half. Restoring the file is legitimate precisely because
# SHIM_SPAWNS above proves the refused run started nothing.
printf '# Handoff\n\nDo prelaunch.\n' > "$CYHO"
out="$(GOF "$CYHO" "the promised retry" 2>&1)"; code=$?
assert_eq "$code" "0" CY
assert_rec_last "$CYREC" state verified CY
[ -f "$SHIM_SPAWNS" ] || { echo "FAIL[CY]: the retry the refusal promised did not launch anything"; fail=1; }
# ...and the state it replaced still refuses. One enum value per meaning: were
# the new state spelled `launching`, everything above would pass and this fails.
printf 'state=launching\nhandoff=%s\n' "$CYHO" > "$CYREC"
rm -f "$SHIM_SPAWNS"
out="$(GOF "$CYHO" "not this one" 2>&1)"; code=$?
[ "$code" != "0" ] || { echo "FAIL[CY]: a record left at 'launching' must still refuse an unforced retry"; fail=1; }
assert_contains "recorded as 'launching'" "$out" CY
assert_no_file "$SHIM_SPAWNS" CY
# ...and the ENUMERATION is CLOSED, which is what makes the line above a control
# rather than a comment. `prelaunch_failed` is retryable because it is NAMED, not
# because it happens to fail two equality tests: with the guard written as
# `if [ x = unknown ] || [ x = launching ]`, deleting the retryable state's arm
# changed nothing observable and this case passed on the mutant. A state this
# launcher never writes is the visible half of the same property -- and the value
# here is the hazard that makes it more than bookkeeping: `launchin` is a
# half-written `launching`, i.e. a successor that may exist, and the open shape
# read it as permission to start a second one.
printf 'state=launchin\nhandoff=%s\n' "$CYHO" > "$CYREC"
rm -f "$SHIM_SPAWNS"
out="$(GOF "$CYHO" "a truncated state" 2>&1)"; code=$?
[ "$code" != "0" ] || { echo "FAIL[CY]: a state this launcher never writes must refuse -- it cannot rule out a live successor"; fail=1; }
assert_contains "does not recognise" "$out" CY
assert_no_file "$SHIM_SPAWNS" CY
# and --force is the documented way past it, from the same record: the refusal is
# this guard's, not something upstream that would refuse the forced run too.
out="$(GOF "$CYHO" "forced past it" --force 2>&1)"; code=$?
assert_eq "$code" "0" CY
[ -f "$SHIM_SPAWNS" ] || { echo "FAIL[CY]: --force must dispatch past an unrecognised state"; fail=1; }
assert_rec_last "$CYREC" state verified CY

# ---- CZ. a registry row with NO working directory is not a match ----------
# `lookup` returns "" both for a key that is absent and for one whose value could
# not be read, and this is the site that decides whether the successor is reading
# the right repository. `[ -n "$ROW_CWD" ] && [ "$ROW_CWD_P" != "$CWD_ABS" ]`
# skipped the comparison on that empty answer and recorded `verified` -- a
# degraded observation becoming a value at the last gate (round-5 correctness
# #8). The kind check one line above it already dies on an empty value.
CZHO="$(NEWHO nocwd)"; CZREC="$CZHO.dispatch"
rm -f "$SHIM_SPAWNS"
printf '[{"id":"%s","kind":"background","startedAt":1787000000000,"sessionId":"%s","state":"running"}]\n' "$SHORT" "$UUID" > "$SHIM_AGENTS"
out="$(GOF "$CZHO" "a row with no cwd" 2>&1)"; code=$?
[ "$code" != "0" ] || { echo "FAIL[CZ]: a listed row with no working directory must not verify"; fail=1; }
assert_contains "without a readable working directory" "$out" CZ
assert_rec_last "$CZREC" state unknown CZ
[ -f "$SHIM_SPAWNS" ] || { echo "FAIL[CZ]: the launcher never ran, so this case never reached the verification step it asserts about"; fail=1; }
# CONTROL 1: the same fixture WITH the key verifies, so the refusal above is
# about the missing directory and not about a fixture that can never pass.
CZHOB="$(NEWHO cwdok)"; rm -f "$SHIM_SPAWNS"; live_json "running"
out="$(GOF "$CZHOB" "a row with the right cwd" 2>&1)"; code=$?
assert_eq "$code" "0" CZ
assert_rec_last "$CZHOB.dispatch" state verified CZ
# CONTROL 2: an empty STRING is the same unanswerable question as an absent key,
# and `live_json` cannot express it (its default fills the field in), so the row
# is written by hand.
CZHOC="$(NEWHO cwdempty)"; CZRECC="$CZHOC.dispatch"
rm -f "$SHIM_SPAWNS"
printf '[{"id":"%s","cwd":"","kind":"background","startedAt":1787000000000,"sessionId":"%s","state":"running"}]\n' "$SHORT" "$UUID" > "$SHIM_AGENTS"
out="$(GOF "$CZHOC" "a row with an empty cwd" 2>&1)"; code=$?
[ "$code" != "0" ] || { echo "FAIL[CZ]: an empty working directory must refuse for the same reason an absent one does"; fail=1; }
assert_contains "without a readable working directory" "$out" CZ
assert_rec_last "$CZRECC" state unknown CZ
live_json "running"

# ---- DA. a printed command is QUOTED, and the class is enumerated ---------
# The id in `claude attach <id>` is not this script's value: `_short_backgrounded`
# takes the last whitespace-separated field of the launcher's own stdout, and the
# only validation it passes rejects a newline and a CR. So the line printed for a
# human to paste could carry `;`, a backtick or `$(` (round-5 correctness #11).
# Three parts: the quoter round-trips, a pasted line runs exactly one command,
# and the population of printed-command sites is counted rather than sampled.

# 1. THE QUOTER. Extracted from the hook and driven directly -- `eval` is what
#    the operator's shell does with the line, so it is what the test does.
eval "$(sed -n '/^shq() {/,/^}/p' "$SCRIPT")"
command -v shq >/dev/null 2>&1 || { echo "FAIL[DA]: shq could not be extracted from $SCRIPT -- this case asserts nothing"; fail=1; }
da_rt() { # $1 = a value that must survive being printed and pasted
  shq "$1"
  da_got="$(eval "printf '%s' $SHQ")" || { echo "FAIL[DA]: the quoted form of [$1] is not a valid shell word: $SHQ"; fail=1; return; }
  [ "$da_got" = "$1" ] || { echo "FAIL[DA]: [$1] quoted as $SHQ came back as [$da_got]"; fail=1; }
}
da_rt "11111111"
da_rt "x;touch /tmp/handoff-da-pwned"
da_rt "a'b"
da_rt "'"
da_rt "a'b'c"
da_rt '$(whoami)'
da_rt '`whoami`'
da_rt 'a b'
da_rt '--help'
da_rt '*'
da_rt 'back\slash'
da_rt ''
# The quoter's own negative control: an UNquoted value does not survive, so the
# round-trips above are a property of shq and not of the values chosen.
da_bad="a'b"
da_got="$(eval "printf '%s' $da_bad" 2>/dev/null)" && [ "$da_got" = "$da_bad" ] && { echo "FAIL[DA]: the round-trip passes without quoting, so it proves nothing"; fail=1; }

# 2. THE PRINTED LINE. A launcher that names a session with a shell metacharacter
#    in it -- the id is verified against the registry before it is printed, so
#    this is a real row -- must still produce a line that runs ONE command.
DAHO="$(NEWHO metachar)"
DA_ID="x;touch\$IFS$tmp/DA-PWNED"
mkdir -p "$tmp/dabin"
cat > "$tmp/dabin/claude" <<'DASH'
#!/bin/sh
printf '%s\n' "$@" > "$DA_ARGS"
DASH
chmod +x "$tmp/dabin/claude"
rm -f "$SHIM_SPAWNS" "$tmp/DA-PWNED"
printf 'backgrounded \xc2\xb7 %s\n' "$DA_ID" > "$SHIM_BG_OUT"
printf '[{"id":"%s","cwd":"%s","kind":"background","startedAt":1787000000000,"sessionId":"%s","state":"running"}]\n' \
  "$DA_ID" "$tmp/work" "$UUID" > "$SHIM_AGENTS"
out="$(GOF "$DAHO" "an id the launcher chose" 2>&1)"; code=$?
assert_eq "$code" "0" DA
DA_LINE="$(printf '%s\n' "$out" | sed -n 's/^ *attach  *: //p' | head -1)"
[ -n "$DA_LINE" ] || { echo "FAIL[DA]: no attach line was printed, so the paste below asserts nothing"; fail=1; }
( PATH="$tmp/dabin:$PATH" DA_ARGS="$tmp/da-args.txt" eval "$DA_LINE" ) >/dev/null 2>&1
assert_no_file "$tmp/DA-PWNED" DA
# ...and the operand that reached the command is the id ITSELF, not a mangled
# one: quoting that broke the value would also pass the assertion above.
assert_eq "$(sed -n 2p "$tmp/da-args.txt" 2>/dev/null)" "$DA_ID" DA
assert_eq "$(sed -n 1p "$tmp/da-args.txt" 2>/dev/null)" "attach" DA
# The seam's own control: the SAME paste against an unquoted line does fire the
# marker, so the assertion above is about the quoting and not about a shim that
# cannot write the file.
rm -f "$tmp/DA-PWNED"
( PATH="$tmp/dabin:$PATH" DA_ARGS="$tmp/da-args2.txt" eval "claude attach $DA_ID" ) >/dev/null 2>&1
[ -f "$tmp/DA-PWNED" ] || { echo "FAIL[DA]: the unquoted control did not fire, so this case cannot tell quoting from a dead fixture"; fail=1; }
rm -f "$tmp/DA-PWNED"
printf 'backgrounded \xc2\xb7 %s\n  claude agents   list sessions\n' "$SHORT" > "$SHIM_BG_OUT"
live_json "running"

# 3. THE POPULATION. tests/paste-census.awk lists every site that hands the
#    operator a command, and says whether a value is interpolated into it. The
#    counts are asserted by number: a new printed command shows up as a count
#    change rather than as a site nobody looked at.
DA_CENSUS="$(cd "$(dirname "$0")" && pwd)/paste-census.awk"
[ -f "$DA_CENSUS" ] || { echo "FAIL[DA]: no census at $DA_CENSUS -- the guard this case runs does not exist"; fail=1; }
da_count() { awk -f "$DA_CENSUS" "$1" | cut -f1,3 | grep -c "^$2	$3$"; }
# 4, not 3: the `--dry-run` launch command is the fourth member of this class and
# the census could not see it until round 6 (C5) — it is a FLAG token, with the
# operands in front of the flag rather than behind it, and at ab92448 all four of
# them (--cwd, the claude path, --model, --permission-mode) were interpolated raw
# into a line the operator is invited to paste. Run the census as it now stands
# against ab92448 and this site reports INTERP/RAW, so the assertion below is
# what would have caught it.
assert_eq "$(da_count "$SCRIPT" INTERP SHQ)" "4"  DA   # printed WITH a value, quoted
assert_eq "$(da_count "$SCRIPT" INTERP RAW)" "0"  DA   # printed WITH a value, raw
# 19, not 18, since the duplicate-dispatch guard's closed default (CY) prints the
# same constant `handoff.sh --status` its sibling arm does. Class (c): the command
# is fixed text, and the state that provoked it is interpolated into the PROSE, not
# into the command -- so there is nothing for shq to quote.
# 21, not 19, since retire_exec's act-time re-verification names `claude agents
# --json` in the two reasons it can refuse to stop the seat with ("could not be
# read", "no longer listed"). Both are class (c): the command is fixed text and
# the state sits in the prose beside it, so neither can carry an unquoted value.
assert_eq "$(da_count "$SCRIPT" CONST -)"    "21" DA   # constant text, nothing to quote
# ...and PER TOKEN, because a total is not coverage (round 6 test-quality #2).
# The surviving mutation that forced this: rename the real `handoff.sh --status`
# at one site to a flag the parser does not accept, and add `claude agents` to a
# `:` no-op somewhere else. Every count above holds -- 19 CONST, 4 INTERP/SHQ,
# 0 INTERP/RAW, 23 rows -- while the operator is handed a command that dies with
# `unknown option`. A per-token census refuses that trade; case DJ then checks
# the surviving `handoff.sh --<flag>` strings against the real parser.
da_tok() { awk -f "$DA_CENSUS" "$1" | cut -f2 | grep -c -- "^$2$"; }
assert_eq "$(da_tok "$SCRIPT" "claude agents")"          "15" DA
assert_eq "$(da_tok "$SCRIPT" "handoff.sh --status")"     "6" DA
assert_eq "$(da_tok "$SCRIPT" "claude attach")"           "2" DA
assert_eq "$(da_tok "$SCRIPT" "rm -rf")"                  "1" DA
assert_eq "$(da_tok "$SCRIPT" "--append-system-prompt")"    "1" DA
# `rmdir ` is a DEAD token: it is in the census's list and matches nothing in the
# hook today. Asserted at 0 deliberately, so that a site which starts telling an
# operator to `rmdir` something arrives as a count change rather than silently.
assert_eq "$(da_tok "$SCRIPT" "rmdir ")"                  "0" DA
# The per-token control: the same trade the mutation makes must move a number.
DATOKMUT="$tmp/handoff-da-tokentrade.sh"
sed 's/handoff[.]sh --status/handoff.sh --stats/g' "$SCRIPT" > "$DATOKMUT"
if cmp -s "$SCRIPT" "$DATOKMUT"; then
  echo "FAIL[DA]: the token-trade mutant is identical to the hook -- the printed flag moved, and this control cannot fail"; fail=1
else
  DA_TT="$(da_tok "$DATOKMUT" "handoff.sh --status")"
  [ "$DA_TT" -lt 6 ] || { echo "FAIL[DA]: renaming a printed flag left the per-token count at $DA_TT -- the census is not reading the printed commands"; fail=1; }
fi
rm -f "$DATOKMUT"
DA_TOTAL="$(awk -f "$DA_CENSUS" "$SCRIPT" | wc -l | tr -d ' ')"
[ "$DA_TOTAL" -ge 15 ] || { echo "FAIL[DA]: the census found only $DA_TOTAL printed-command sites, so its tokens have drifted from the file"; fail=1; }
# The census's own negative control, in CX's shape: strip the quoting and it must
# report RAW. Without this, DA passes against a census that stopped matching.
DAMUT="$tmp/handoff-da-unquoted.sh"
sed 's/\$SHQ/$SHORT/g' "$SCRIPT" > "$DAMUT"
if cmp -s "$SCRIPT" "$DAMUT"; then
  echo "FAIL[DA]: the unquoted mutant is identical to the hook -- the quoting moved, and this control cannot fail"; fail=1
else
  DA_RAW="$(da_count "$DAMUT" INTERP RAW)"
  [ "$DA_RAW" -ge 4 ] || { echo "FAIL[DA]: with the quoting stripped the census still reported $DA_RAW raw site(s) -- it is not reading the printed commands"; fail=1; }
fi
rm -f "$DAMUT"


# ---- DB. the arm-watch substitution must not carry the dispatch lock ------
# Same class as BI, at the other substitution: the watchdog is armed inside
# `GEN="$( exec 9>&- 8>&- 7>&-; arm_watch "$REC" )"`, and that subshell is a
# forked child. Without the `exec` close it inherits fd 9, so SIGKILLing the
# dispatcher releases the dispatch lock only once that subshell dies -- and it
# outlives the dispatcher by design, polling for the watcher's lease. Case CM
# only COUNTS closing substitutions, so deleting this one while adding any other
# `( exec 9>&- ...` keeps the census honest: that compound mutant survived the
# entire suite before this case existed. Nothing else observes this site's
# descriptors either -- every fd assertion in the suite (BE, BI) reads them from
# the successor shim, which is the launch path, not the arm path.
#
# Holding the arm loop still needs a stall INSIDE it, and the lock backend is
# the only thing it runs that a test can intercept: a `perl` shim on the
# dispatch's PATH blocks the LEASE probe (fd 8), and only once the record names
# a generation -- which arm_watch writes just before it forks the watcher, so a
# stalled fd-8 probe is proof the dispatch is already inside the substitution.
# The fd-9 dispatch claim and the fd-7 alert claims go to the real perl
# untouched, or nothing would ever take the lock this case is about.
DB_STALL="$tmp/perl-stall"
DB_REAL_PERL="$(command -v perl || true)"
[ -n "$DB_REAL_PERL" ] || { echo "FAIL[DB]: no perl on PATH for the stall shim to delegate to -- the case cannot run"; fail=1; }
mkdir -p "$tmp/perlbin"
cat > "$tmp/perlbin/perl" <<'DBSHIM'
#!/bin/sh
# lock_take invokes `perl -e "<program>" <fd>`, so the descriptor is the LAST
# argument -- the only thing about the call this shim can key on, since the
# program text names no path.
_last=""; for _a in "$@"; do _last="$_a"; done
if [ "$_last" = 8 ] && [ -f "$DB_STALL" ] && grep -q '^watch_gen=' "$DB_REC" 2>/dev/null; then
  # WHICH process is stalling decides what the case may conclude: the launcher's
  # arm loop and the watcher it just forked both probe fd 8, and only the
  # launcher's side is the one that would be holding the lock. A forked subshell
  # keeps its parent's argv, so the watcher's spells `--watch` and the arm
  # loop's spells the objective. An ancestry that cannot be read is neither --
  # the case then waits out its bound and says so, rather than killing the
  # dispatcher before it ever reached the substitution.
  _who="$(ps -o args= -p "$PPID" 2>/dev/null || true)"
  case "${_who:-NOPS}" in
    *--watch*) printf '%s\n' "$$" > "$DB_STALL.ready.watch" ;;
    NOPS)      printf '%s\n' "$$" > "$DB_STALL.ready.unknown" ;;
    *)         printf '%s\n' "$$" > "$DB_STALL.ready.arm" ;;
  esac
  _n=0
  while [ ! -f "$DB_STALL.release" ] && [ "$_n" -lt 900 ]; do sleep 0.1; _n=$(( _n + 1 )); done
  # Released, and deliberately not as "took it": a lease reported HELD unwinds
  # both sides at once -- the arm loop calls the watcher armed, and the watcher
  # stands down as a duplicate instead of polling on into the next case.
  exit 1
fi
exec "$DB_REAL_PERL" "$@"
DBSHIM
chmod +x "$tmp/perlbin/perl"
DBHO="$(NEWHO armclose)"; DB_REC="$DBHO.dispatch"
export DB_STALL DB_REAL_PERL DB_REC
rm -rf "$DB_REC.flock"; rm -f "$SHIM_SPAWNS"
rm -f "$DB_STALL".ready.* "$DB_STALL.release"; : > "$DB_STALL"
live_json "running"
# The objective is the anchor's discriminator: it is in the launcher's argv and
# in every subshell it forks, and NOT in the watcher's.
DBOBJ="armclose-substitution-outlives-its-launcher"
PATH="$tmp/perlbin:$PATH" CLAUDE_HANDOFF_ARM=1 CLAUDE_HANDOFF_FS_TIMEOUT=30 \
  bash "$SCRIPT" "$DBHO" "$DBOBJ" --cwd "$tmp/work" --poll-sec 1 >/dev/null 2>&1 &
dbp=$!
dbn=0
while [ ! -f "$DB_STALL.ready.arm" ] && [ "$dbn" -lt 300 ]; do sleep 0.1; dbn=$(( dbn + 1 )); done
assert_file "$DB_STALL.ready.arm" DB
assert_no_file "$DB_STALL.ready.unknown" DB
grep -q '^watch_gen=' "$DB_REC" 2>/dev/null || { echo "FAIL[DB]: the record names no watch generation, so the stalled probe is not arm_watch's and the kill below lands somewhere else"; fail=1; }
assert_held "$DB_REC.flock" DB               # the dispatcher really holds it here
kill -9 "$dbp" 2>/dev/null || true
wait "$dbp" 2>/dev/null || true
# ANCHOR, before the lock is asked about: the substitution's subshell survived
# the kill. Without it "the lock is free" says nothing -- a subshell that has
# already exited drops an inherited descriptor too, so the assertion below would
# pass against the very code it exists to catch.
dbleft="$(pgrep -f "$DBOBJ" 2>/dev/null | grep -v "^$dbp\$" | tr '\n' ' ')"
[ -n "$dbleft" ] || { echo "FAIL[DB]: nothing of the dispatch outlived the kill, so a released lock proves nothing about the arm substitution"; fail=1; }
dbn=0
while lock_is_held "$DB_REC.flock" && [ "$dbn" -lt 100 ]; do sleep 0.1; dbn=$(( dbn + 1 )); done
assert_not_held "$DB_REC.flock" DB
assert_no_file "$DB_STALL.release" DB        # ...and the probe was stalled throughout
: > "$DB_STALL.release"
dbn=0
while [ "$dbn" -lt 150 ] && ! grep -q '^watch_pid_' "$DB_REC" 2>/dev/null; do sleep 0.1; dbn=$(( dbn + 1 )); done
retire_watchers "$DB_REC"
rm -f "$DB_STALL"
# ---- DC. a heartbeat source we were not ALLOWED to look at is not an absent one
# CW covers "the stat timed out". This is the other way a look fails: the stat is
# REFUSED. `[ -f ]` and `[ -e ]` answer FALSE for ENOENT and for EACCES alike, so
# both fs probes reported "not there" for a file they were never permitted to
# see, the heartbeat block concluded "no beat sources, but nothing failed" and
# the standing `beatdegraded` episode was cleared on the strength of it -- while
# an operator whose ~/.claude went unreadable is told monitoring is fine
# (round 6, C4).
#
# The handoff file is the source this drives, because it is the one whose
# directory a test can take away: `transcript_for` searches the projects tree, so
# locking that tree removes the path rather than the permission to stat it.
DCD="$tmp/dc"; mkdir -p "$DCD/locked"
DCHO="$DCD/locked/HANDOFF-dc.md"
printf '# Handoff\n\nDo dc.\n' > "$DCHO"
live_json "running"; GOF "$DCHO" "dc" >/dev/null 2>&1
assert_rec "$DCHO.dispatch" "state=verified" DC
# The watch runs against a COPY of the record, kept OUTSIDE the directory that is
# about to lose its search bit. In production the record and the handoff file are
# siblings, so locking the handoff file's directory takes the record with it and
# the poll dies at startup ("record not readable") without ever reaching the
# heartbeat block -- a case that stops before the line it claims to pin. Nothing
# the heartbeat block reads changes: `handoff=` still names the real file.
DCREC="$DCD/dc.record"
cp "$DCHO.dispatch" "$DCREC"
dc_marker() { sed -n 's/^alerted_beatdegraded=//p' "$DCREC" | tail -1; }
# The transcript is the OTHER heartbeat source; with it present the handoff file
# never decides the outcome and this case would assert nothing.
mv "$transcript" "$tmp/dc-parked.jsonl"

# 1. THE FIXTURE'S OWN CONTROL. An unsearchable directory has to actually refuse
#    the look, or both arms below are the same arm. (It does not, for root; this
#    suite is not run as root, and a silent skip here would be exactly the
#    "control that cannot fail" this branch keeps producing.)
chmod 000 "$DCD/locked"
[ ! -f "$DCHO" ] || { echo "FAIL[DC]: chmod 000 on $DCD/locked did not hide $DCHO from [ -f ] -- this case cannot tell 'could not look' from 'not there' (running as root?)"; fail=1; }
[ -r "$DCREC" ] || { echo "FAIL[DC]: the record went unreadable too, so the poll below never reaches the heartbeat block"; fail=1; }
chmod 755 "$DCD/locked"

# 2. THE NEGATIVE CONTROL, FIRST, on the fixture the assertion uses. Put the old
#    `[ -e ]`-only disambiguation back and the refused look reads as absence: the
#    poll reports a successor with no heartbeat source, raises nothing, and
#    returns 0 -- monitoring silently blind.
DCMUT="$tmp/handoff-dc-testonly.sh"
sed 's/^  path_state "\$1"; _fe_st=\$?$/  _fe_st=1/' "$SCRIPT" > "$DCMUT"
if cmp -s "$SCRIPT" "$DCMUT"; then
  echo "FAIL[DC]: the test-only mutant is identical to the hook -- file_exists's disambiguation moved, and this control cannot fail"; fail=1
else
  chmod 000 "$DCD/locked"
  DC_MOUT="$(bash "$DCMUT" --watch-once "$DCREC" 2>&1)"; dcm_rc=$?
  chmod 755 "$DCD/locked"
  assert_eq "$(dc_marker)" ""  DC-control
  assert_eq "$dcm_rc" "0"      DC-control
  assert_missing "cannot stat successor" "$DC_MOUT" DC-control
fi
rm -f "$DCMUT"

# 3. THE ASSERTION: the same fixture, the real hook. A look that was REFUSED is
#    a failed observation, so the episode is raised and the poll says it is
#    degraded rather than returning 0.
chmod 000 "$DCD/locked"
DC_OUT="$(bash "$SCRIPT" --watch-once "$DCREC" 2>&1)"; dc_rc=$?
chmod 755 "$DCD/locked"
assert_eq "$(dc_marker)" "1" DC
assert_eq "$dc_rc" "3" DC
assert_contains "cannot stat successor" "$DC_OUT" DC

# 4. RECOVERY, so step 3 is about permission and not about a marker this hook can
#    never clear: give the look back and the episode ends.
DC_OUT3="$(bash "$SCRIPT" --watch-once "$DCREC" 2>&1)"
assert_eq "$(dc_marker)" "0" DC
assert_contains "heartbeat" "$DC_OUT3" DC
mv "$tmp/dc-parked.jsonl" "$transcript"

# ---- DD. an unanswered clock is never a dispatch TIME ----------------------
# Two ways the dispatch time goes missing, and neither may become a number.
#  (i)  the clock failed AT DISPATCH: `dispatched_at=` and `dispatched_epoch=0`
#       were written, and a later, perfectly healthy watcher read the zero as an
#       epoch and reported "no transcript in 29785107m" (round 6, C3).
#  (ii) the clock is fine but the RECORD READ times out: `rec_num` collapsed the
#       failed read into 0 and the poll reported the successor healthy (C2).
# Both must say "I cannot judge the deadline" and exit 3 -- the vocabulary this
# script uses everywhere else for a look that did not happen.
DDD="$tmp/dd"; mkdir -p "$DDD/bin"
cat > "$DDD/bin/date" <<'DDSH'
#!/bin/sh
[ -f "$DD_NOCLOCK" ] && exit 1
exec /bin/date "$@"
DDSH
chmod +x "$DDD/bin/date"
cat > "$DDD/bin/sed" <<'DDSH2'
#!/bin/sh
if [ -f "$DD_HANG" ]; then
  for a in "$@"; do case "$a" in *dispatched_epoch*) sleep 8 ;; esac; done
fi
exec /usr/bin/sed "$@"
DDSH2
chmod +x "$DDD/bin/sed"
mv "$transcript" "$transcript.dd-parked"

# (i) DISPATCH WITH NO CLOCK.
DDHO="$(NEWHO dd-noclock)"; DDREC="$DDHO.dispatch"
: > "$DDD/noclock"
live_json "running"
env DD_NOCLOCK="$DDD/noclock" PATH="$DDD/bin:$PATH" \
  bash "$SCRIPT" "$DDHO" "dd" --cwd "$tmp/work" >/dev/null 2>&1
rm -f "$DDD/noclock"
assert_rec "$DDREC" "state=verified" DD
assert_rec "$DDREC" "dispatch_clock_lost=1" DD
# The two keys are ABSENT, not empty and not zero: `rec_ok_value` rejects only a
# newline, so both would have sailed in.
grep -q '^dispatched_epoch=' "$DDREC" && { echo "FAIL[DD]: a dispatch whose clock failed still wrote dispatched_epoch: $(grep '^dispatched_epoch=' "$DDREC")"; fail=1; }
grep -q '^dispatched_at=' "$DDREC" && { echo "FAIL[DD]: a dispatch whose clock failed still wrote dispatched_at: $(grep '^dispatched_at=' "$DDREC")"; fail=1; }
grep -q 'HandoffDispatchClockLost' "$CLAUDE_HANDOFF_LOG" || { echo "FAIL[DD]: the clock failure at dispatch was not logged, so nothing durable records why the keys are missing"; fail=1; }

# ...and the watcher that inherits that record says so, rather than inventing an age.
DD_OUT="$(bash "$SCRIPT" --watch-once "$DDREC" 2>&1)"; dd_rc=$?
assert_eq "$dd_rc" "3" DD
assert_contains "dispatch time was never recorded" "$DD_OUT" DD
assert_missing "has written no transcript in" "$DD_OUT" DD
assert_rec_last "$DDREC" alerted_dispatchdegraded 1 DD

# (ii) THE READ TIMES OUT on a record whose dispatch time is perfectly good.
DDHO2="$(NEWHO dd-unreadable)"; DDREC2="$DDHO2.dispatch"
live_json "running"; GOF "$DDHO2" "dd2" >/dev/null 2>&1
assert_rec "$DDREC2" "dispatched_epoch=[0-9][0-9]*" DD
# The control: the same poll with every read answering reports health, so the
# difference below is the failed read and not the fixture.
DD_OK="$(bash "$SCRIPT" --watch-once "$DDREC2" 2>&1)"; dd_okrc=$?
assert_eq "$dd_okrc" "0" DD
: > "$DDD/hang"
DD_OUT2="$(env DD_HANG="$DDD/hang" PATH="$DDD/bin:$PATH" CLAUDE_HANDOFF_FS_TIMEOUT=2 \
             bash "$SCRIPT" --watch-once "$DDREC2" 2>&1)"; dd_rc2=$?
rm -f "$DDD/hang"
assert_eq "$dd_rc2" "3" DD
assert_contains "cannot establish when successor" "$DD_OUT2" DD
assert_rec_last "$DDREC2" alerted_dispatchdegraded 1 DD
# RECOVERY: the episode ends when the deadline can be judged again, so the key is
# an episode and not a one-shot.
bash "$SCRIPT" --watch-once "$DDREC2" >/dev/null 2>&1
assert_rec_last "$DDREC2" alerted_dispatchdegraded 0 DD

# The negative control for (ii), in CX's shape: put the collapse back and the
# timed-out read reports the successor healthy again.
DDMUT="$tmp/handoff-dd-collapse.sh"
sed 's/^  rec_read "\$1" "\$2" || return 2$/  rec_read "$1" "$2" || return 0/' "$SCRIPT" > "$DDMUT"
if cmp -s "$SCRIPT" "$DDMUT"; then
  echo "FAIL[DD]: the collapsing mutant is identical to the hook -- rec_num's tri-state moved, and this control cannot fail"; fail=1
else
  DDHO3="$(NEWHO dd-control)"; DDREC3="$DDHO3.dispatch"
  live_json "running"; GOF "$DDHO3" "dd3" >/dev/null 2>&1
  : > "$DDD/hang"
  DD_OUT3="$(env DD_HANG="$DDD/hang" PATH="$DDD/bin:$PATH" CLAUDE_HANDOFF_FS_TIMEOUT=2 \
               bash "$DDMUT" --watch-once "$DDREC3" 2>&1)"; dd_rc3=$?
  rm -f "$DDD/hang"
  case "$DD_OUT3" in
    *"cannot establish when successor"*) echo "FAIL[DD]: the collapsing mutant still reported the degraded read, so the assertion above is not about rec_num's status"; fail=1 ;;
  esac
  [ "$dd_rc3" != 3 ] || { echo "FAIL[DD]: the collapsing mutant still exited 3, so the exit code above proves nothing"; fail=1; }
fi
rm -f "$DDMUT"
mv "$transcript.dd-parked" "$transcript"

# ---- DE. a marker may not be written on a generation we could not READ -----
# CX moved the generation fence to the write. This is the fence's own failed
# observation: `gen_is_ours` returned TRUE when `rec_read watch_gen` FAILED, so a
# superseded watcher whose record it could no longer read wrote its flat
# `alerted_*` into the live generation anyway -- the exact outcome CX exists to
# prevent, reached by the one path CX does not travel (round 6, C1).
DED="$tmp/de"; mkdir -p "$DED/bin"
case "$(uname -s)" in Darwin) DE_BIN=osascript ;; *) DE_BIN=notify-send ;; esac
cat > "$DED/bin/$DE_BIN" <<'DESH'
#!/bin/sh
: > "$DE_DELIVERING"
sleep "${DE_SLEEP:-2}"
exit 0
DESH
chmod +x "$DED/bin/$DE_BIN"
# The record read that must fail is the ONE for watch_gen, and only once the
# delivery is in flight -- every earlier read in the same poll has to answer or
# the poll never reaches a marker write at all.
cat > "$DED/bin/sed" <<'DESH2'
#!/bin/sh
if [ -f "$DE_HANG" ]; then
  for a in "$@"; do case "$a" in *watch_gen*) sleep 8 ;; esac; done
fi
exec /usr/bin/sed "$@"
DESH2
chmod +x "$DED/bin/sed"
de_run() { # $1=script $2=tag -> DE_MARK, DE_REPOLL
  _deho="$(NEWHO "$2")"; _derec="$_deho.dispatch"
  live_json "running"; GOF "$_deho" "$2" >/dev/null 2>&1; : > "$transcript"
  live_json "blocked"
  printf 'watch_gen=g-de-1\n' >> "$_derec"
  rm -f "$DED/delivering" "$DED/hang"
  ( env -u CLAUDE_HANDOFF_NOTIFY_DEBUG DE_DELIVERING="$DED/delivering" DE_SLEEP=3 \
        DE_HANG="$DED/hang" PATH="$DED/bin:$PATH" CLAUDE_HANDOFF_FS_TIMEOUT=4 \
      bash "$1" --watch-once "$_derec" --watch-gen g-de-1 >/dev/null 2>&1 ) & _depid=$!
  _dew=0
  while [ ! -f "$DED/delivering" ] && [ "$_dew" -lt 200 ]; do sleep 0.1; _dew=$(( _dew + 1 )); done
  if [ ! -f "$DED/delivering" ]; then
    echo "FAIL[DE/$2]: the notifier never ran, so no marker write ever happened under an unreadable record -- this case asserts nothing"; fail=1
    kill -9 "$_depid" 2>/dev/null; wait "$_depid" 2>/dev/null
    DE_MARK="SHIM-NEVER-RAN"; DE_REPOLL=""; return 0
  fi
  : > "$DED/hang"          # from here the watch_gen read cannot answer
  wait "$_depid" 2>/dev/null
  rm -f "$DED/hang"
  DE_MARK="$(sed -n 's/^alerted_blocked=//p' "$_derec" | tail -1)"
  # ...and what the marker COSTS: the next generation's first blocked nudge.
  printf 'watch_gen=g-de-2\n' >> "$_derec"
  DE_REPOLL="$(bash "$1" --watch-once "$_derec" --watch-gen g-de-2 2>&1)"
}
de_run "$SCRIPT" de
assert_eq "$DE_MARK" "" DE
assert_contains "successor $SHORT is blocked and needs input" "$DE_REPOLL" DE

# The negative control: the fail-OPEN form, which is what the hook did at
# ab92448. Without it DE passes against a hook that never writes the marker and
# against a harness whose hang never landed inside the window.
DEMUT="$tmp/handoff-de-failopen.sh"
sed 's/^  rec_read "\$1" watch_gen || return 1$/  rec_read "$1" watch_gen || return 0/' "$SCRIPT" > "$DEMUT"
if cmp -s "$SCRIPT" "$DEMUT"; then
  echo "FAIL[DE]: the fail-open mutant is identical to the hook -- gen_may_write's failed-read branch moved, and this control cannot fail"; fail=1
else
  de_run "$DEMUT" de-failopen
  [ "$DE_MARK" = 1 ] || { echo "FAIL[DE]: with the failed read treated as 'ours' the marker did NOT land ('$DE_MARK'), so the assertion above proves nothing"; fail=1; }
  assert_missing "successor $SHORT is blocked and needs input" "$DE_REPOLL" "DE control"
fi
rm -f "$DEMUT"
live_json "running"

# ---- DF. losing the clock is a per-WATCHER episode, not a per-record one ---
# A watcher that cannot read the clock STANDS DOWN, so there is no recovery
# transition inside one watcher's life to clear a marker with -- the same shape
# as leasedegraded, and it needs the same generation-scoped key. Flat, the first
# watchdog to lose the clock announced it and every later one on that record was
# silenced: the log carried two HandoffWatchClockLost events and the operator was
# told once (round 6, L3 -- reproduced). "Nobody is watching now" is the last
# alert you can afford to lose.
DFD="$tmp/df"; mkdir -p "$DFD/bin"
cat > "$DFD/bin/date" <<'DFSH'
#!/bin/sh
[ -f "$DF_NOCLOCK" ] && exit 1
exec /bin/date "$@"
DFSH
chmod +x "$DFD/bin/date"
DFHO="$(NEWHO df-clocklost)"; DFREC="$DFHO.dispatch"
live_json "running"; GOF "$DFHO" "df" >/dev/null 2>&1; : > "$transcript"
df_gen() { # $1=script $2=generation -> DF_OUT
  printf 'watch_gen=%s\n' "$2" >> "$DFREC"
  rm -f "$DFD/noclock"
  # The clock has to work at entry and fail MID-LOOP: `watch_loop` refuses at its
  # very first `epoch` otherwise, and never reaches the stand-down under test.
  ( sleep 3; : > "$DFD/noclock" ) &
  _dfbg=$!
  DF_OUT="$(env DF_NOCLOCK="$DFD/noclock" PATH="$DFD/bin:$PATH" \
              bash "$1" --watch "$DFREC" --watch-gen "$2" --poll-sec 1 2>&1)"
  wait "$_dfbg" 2>/dev/null
  rm -f "$DFD/noclock"
}
df_gen "$SCRIPT" g-df-1
assert_contains "cannot read the clock" "$DF_OUT" DF
df_gen "$SCRIPT" g-df-2
assert_contains "cannot read the clock" "$DF_OUT" DF
# The key CARRIES the generation, so neither watcher can silence the other...
assert_rec_last "$DFREC" alerted_clocklost_g-df-1 1 DF
assert_rec_last "$DFREC" alerted_clocklost_g-df-2 1 DF
# ...and the flat key it used to be is gone, which is what a rename must prove.
grep -q '^alerted_clocklost=' "$DFREC" && { echo "FAIL[DF]: the flat alerted_clocklost key is still written, so the generation-scoped one is an addition and not the fix"; fail=1; }

# THE BARE MODE, which is the one an operator drives BY HAND: `--watch <record>`
# with no --watch-gen is on this script's own usage line, and scoping the key by
# $WATCH_GEN alone left it FLAT there -- the first bare watcher to lose its clock
# still silenced every later one, i.e. the original defect surviving inside its
# own fix (round 6 micro-review). A watcher has an identity even when it has no
# generation, so the key falls back to its pid.
df_bare() { # $1=script -> DF_OUT   (df_gen without the generation)
  rm -f "$DFD/noclock"
  ( sleep 3; : > "$DFD/noclock" ) &
  _dfbg=$!
  DF_OUT="$(env DF_NOCLOCK="$DFD/noclock" PATH="$DFD/bin:$PATH" \
              bash "$1" --watch "$DFREC" --poll-sec 1 2>&1)"
  wait "$_dfbg" 2>/dev/null
  rm -f "$DFD/noclock"
}
DFHO3="$(NEWHO df-bare)"; DFREC3="$DFHO3.dispatch"
live_json "running"; GOF "$DFHO3" "df-bare" >/dev/null 2>&1
# The dispatch armed its own generation-scoped watcher; supersede it so the two
# bare watchers below are the only ones writing this record.
printf 'watch_gen=%s\n' "g-df-bare-retired" >> "$DFREC3"
_dfsave2="$DFREC"; DFREC="$DFREC3"
df_bare "$SCRIPT"
assert_contains "cannot read the clock" "$DF_OUT" DF
df_bare "$SCRIPT"
assert_contains "cannot read the clock" "$DF_OUT" DF
DFREC="$_dfsave2"
# ONE KEY PER WATCHER PROCESS, so neither can silence the other...
# The scope is `pid<pid>r<n>x<n>x<n>`, not `pid<pid>` -- see DO for why the nonce
# is there, and the hook for why it is three `x`-separated draws rather than two
# concatenated ones. Extracting only the pid form would have silently matched
# nothing after that change and asserted 0 != 2, which is at least loud;
# extracting `pid.*` would have kept passing and stopped meaning anything.
# Anchor on the shape the hook actually derives -- including the separators,
# because it is the separators that make distinct draws distinct keys.
DF_BK="$(sed -n 's/^alerted_\(clocklost_pid[0-9][0-9]*r[0-9][0-9]*x[0-9][0-9]*x[0-9][0-9]*\)=1$/\1/p' "$DFREC3" | sort -u | wc -l | tr -d ' ')"
[ "$DF_BK" = 0 ] && echo "FAIL[DF]: no alerted_clocklost_pid<pid>r<n>x<n>x<n> key was written at all, so the count below compares against an empty parse and the bare-mode scope is not what this case thinks it is"
assert_eq "$DF_BK" "2" DF
# ...and the flat key is not written in this mode either.
grep -q '^alerted_clocklost=' "$DFREC3" && { echo "FAIL[DF]: the bare watcher still writes the flat alerted_clocklost key, so the pid scope is an addition and not the fix"; fail=1; }

# Its negative control: delete the pid fallback and the scope is empty again, so
# the SECOND bare watcher goes silent.
DFMUT2="$tmp/handoff-df-nopid.sh"
sed 's/^  \[ -n "\$_fk_scope" \] || _fk_scope="pid\$\$r\${RANDOM}x\${RANDOM}x\${RANDOM}"$/  :/' "$SCRIPT" > "$DFMUT2"
if cmp -s "$SCRIPT" "$DFMUT2"; then
  echo "FAIL[DF]: the no-fallback mutant is identical to the hook -- the bare-mode scope moved, and this control cannot fail"; fail=1
else
  DFHO4="$(NEWHO df-bare-flat)"; DFREC4="$DFHO4.dispatch"
  live_json "running"; GOF "$DFHO4" "df-bare-flat" >/dev/null 2>&1
  printf 'watch_gen=%s\n' "g-df-bare-flat-retired" >> "$DFREC4"
  _dfsave3="$DFREC"; DFREC="$DFREC4"
  df_bare "$DFMUT2"
  case "$DF_OUT" in *"cannot read the clock"*) ;; *) echo "FAIL[DF]: the no-fallback mutant's FIRST bare watcher was already silent, so the second one proves nothing"; fail=1 ;; esac
  df_bare "$DFMUT2"
  case "$DF_OUT" in
    *"cannot read the clock"*) echo "FAIL[DF]: the no-fallback mutant still told the operator twice, so the pid fallback is not what makes the second bare alert arrive"; fail=1 ;;
  esac
  DFREC="$_dfsave3"
  retire_watchers "$DFREC4"
fi
rm -f "$DFMUT2"
retire_watchers "$DFREC3"

# The negative control: flat again, and the SECOND generation goes silent.
DFMUT="$tmp/handoff-df-flat.sh"
sed 's/^  CLOCK_KEY="clocklost_\$_fk_scope"$/  CLOCK_KEY="clocklost"/' "$SCRIPT" > "$DFMUT"
if cmp -s "$SCRIPT" "$DFMUT"; then
  echo "FAIL[DF]: the flat-key mutant is identical to the hook -- CLOCK_KEY's generation scoping moved, and this control cannot fail"; fail=1
else
  DFHO2="$(NEWHO df-flat)"; DFREC2="$DFHO2.dispatch"
  live_json "running"; GOF "$DFHO2" "df-flat" >/dev/null 2>&1
  _dfsave="$DFREC"; DFREC="$DFREC2"
  df_gen "$DFMUT" g-df-1
  case "$DF_OUT" in *"cannot read the clock"*) ;; *) echo "FAIL[DF]: the flat mutant's FIRST generation was already silent, so the second one proves nothing"; fail=1 ;; esac
  df_gen "$DFMUT" g-df-2
  case "$DF_OUT" in
    *"cannot read the clock"*) echo "FAIL[DF]: the flat-key mutant still told the operator twice, so the generation scoping above is not what makes the second alert arrive"; fail=1 ;;
  esac
  DFREC="$_dfsave"
fi
rm -f "$DFMUT"
retire_watchers "$DFREC"

# ---- DO. a watcher's clock-lost episode is not a function of its PID alone ----
# `clocklost_<scope>` and `expired_<scope>` have NO clearing edge by design: a
# watcher that loses its clock stands down, so nothing inside its life ever
# un-sets the marker. That makes the scope a permanent name in the record, and
# `pid$$` is not a permanent name -- the kernel hands the number out again. A
# later bare watcher that happened to draw a dead predecessor's pid read the
# predecessor's `alerted_clocklost_pid<n>=1` and stood down SILENTLY, which is
# the original flat-key defect returning through the back door of pid reuse
# (round 6 micro-review 2).
#   Corrected in micro-review 4, and the original claim was overstated: this said
# "DF proves two CONCURRENT bare watchers do not silence each other -- concurrent
# pids differ". DF's two bare watchers are not concurrent. `df_bare` runs the
# watcher inside a command substitution, so it has already exited by the time the
# call returns, and the two calls are consecutive statements -- they are
# SEQUENTIAL, which is the very shape this case says has to be pinned. What DF
# actually cannot see is narrower: two consecutive short-lived processes are
# handed different pids on every platform this suite runs on, so DF's count of
# two distinct keys holds with or without the nonce. Its blindness is
# NONDETERMINISTIC -- it rests on the kernel not recycling a pid inside a
# two-second window -- rather than structural, and coverage that rests on that is
# not coverage. The only way to arrange a recycled pid deterministically is to
# write the predecessor's marker under the live watcher's own pid, which is what
# this case does.
DOD="$tmp/do"; mkdir -p "$DOD/bin"
cat > "$DOD/bin/date" <<'DOSH'
#!/bin/sh
[ -f "$DO_NOCLOCK" ] && exit 1
exec /bin/date "$@"
DOSH
chmod +x "$DOD/bin/date"
do_run() { # $1=script $2=record $3=1 to seed the dead predecessor's marker -> DO_OUT
  rm -f "$DOD/noclock"
  # Same shape as DF: the clock must work at entry (watch_loop refuses at its
  # first `epoch` otherwise) and fail mid-loop.
  ( sleep 3; : > "$DOD/noclock" ) &
  _dobg=$!
  env DO_NOCLOCK="$DOD/noclock" PATH="$DOD/bin:$PATH" \
    bash "$1" --watch "$2" --poll-sec 1 > "$DOD/out" 2>&1 &
  _dopid=$!
  # THE RECYCLED PID, ARRANGED. `bash script &` makes $! the pid that script
  # sees as $$, so this is exactly the marker a dead watcher with this pid would
  # have left behind. It is read by alert_once when the clock breaks at t+3s,
  # so writing it now is inside the window.
  [ "$3" = 1 ] && printf 'alerted_clocklost_pid%s=1\n' "$_dopid" >> "$2"
  wait "$_dopid" 2>/dev/null
  wait "$_dobg" 2>/dev/null
  DO_OUT="$(cat "$DOD/out")"
  rm -f "$DOD/noclock"
}
DOHO="$(NEWHO do-pidreuse)"; DOREC="$DOHO.dispatch"
live_json "running"; GOF "$DOHO" "do" >/dev/null 2>&1
# The dispatch armed a generation-scoped watcher of its own; supersede it so the
# bare watcher below is the only one writing this record.
printf 'watch_gen=%s\n' "g-do-retired" >> "$DOREC"
do_run "$SCRIPT" "$DOREC" 1
assert_contains "cannot read the clock" "$DO_OUT" DO
# And the marker it wrote is its own, not the seeded one: two distinct keys.
DO_BK="$(sed -n 's/^alerted_\(clocklost_pid[0-9a-z]*\)=1$/\1/p' "$DOREC" | sort -u | wc -l | tr -d ' ')"
assert_eq "$DO_BK" "2" DO
retire_watchers "$DOREC"

# The negative control: take the nonce away and the scope is the bare pid again,
# so the seeded predecessor's marker silences this watcher.
DOMUT="$tmp/handoff-do-nonce.sh"
sed 's/^  \[ -n "\$_fk_scope" \] || _fk_scope="pid\$\$r\${RANDOM}x\${RANDOM}x\${RANDOM}"$/  [ -n "$_fk_scope" ] || _fk_scope="pid$$"/' "$SCRIPT" > "$DOMUT"
if cmp -s "$SCRIPT" "$DOMUT"; then
  echo "FAIL[DO]: the pid-only mutant is identical to the hook -- the bare-mode scope moved, and this control cannot fail"; fail=1
else
  # Positive control FIRST: unseeded, the mutant must still alert. Without this,
  # the silence below could come from any breakage the mutant introduced rather
  # than from the pid collision this case is about.
  DOHO2="$(NEWHO do-nonce-a)"; DOREC2="$DOHO2.dispatch"
  live_json "running"; GOF "$DOHO2" "do-nonce-a" >/dev/null 2>&1
  printf 'watch_gen=%s\n' "g-do-retired" >> "$DOREC2"
  do_run "$DOMUT" "$DOREC2" 0
  case "$DO_OUT" in *"cannot read the clock"*) ;; *) echo "FAIL[DO]: the pid-only mutant was already silent with nothing seeded, so its silence under a seeded marker proves nothing"; fail=1 ;; esac
  retire_watchers "$DOREC2"
  DOHO3="$(NEWHO do-nonce-b)"; DOREC3="$DOHO3.dispatch"
  live_json "running"; GOF "$DOHO3" "do-nonce-b" >/dev/null 2>&1
  printf 'watch_gen=%s\n' "g-do-retired" >> "$DOREC3"
  do_run "$DOMUT" "$DOREC3" 1
  case "$DO_OUT" in
    *"cannot read the clock"*) echo "FAIL[DO]: the pid-only mutant still warned through a marker left under its own pid, so the nonce is not what defeats pid reuse"; fail=1 ;;
  esac
  retire_watchers "$DOREC3"
fi
rm -f "$DOMUT"

# ---- DG. the alert-key census in the hook is DERIVED, not remembered -------
# The hook carries a three-way classification of every alert key, written when
# four separate findings turned out to be one class. Round 6 found it reading
# "15 keys across 18 arming sites" against a file that had grown to 17 and 20 --
# and a stale census is worse than none, because it is what a reviewer trusts
# INSTEAD of grepping. So the numbers and the names are derived here from the
# source and compared with what the comment says.
#
# Every classification below comes from the CODE, not from a list retyped here:
#   watcher-scoped    = the key is interpolated with the watcher's identity,
#                       which is $WATCH_GEN or, where there is no generation,
#                       $_fk_scope (the generation, else the watcher's pid)
#   episodic          = something calls rec_clear on its alerted_ marker
#   record-scoped     = neither
DG_ARM="$tmp/dg-arming.txt"; DG_KEYS="$tmp/dg-keys.txt"
# Arming sites: every alert_once call that is not in a comment. `rearm_<gen>` is
# excluded BY THE HOOK's own rule ("a per-generation delivery retry, not a
# condition"), and the exclusion is spelled from the key, not from a line number.
grep -n 'alert_once "' "$SCRIPT" | grep -v '^[0-9]*: *#' \
  | sed 's/.*alert_once "[^"]*" //' | awk '{print $1}' | tr -d '"' \
  | grep -v '^rearm_\$' > "$DG_ARM"
[ -s "$DG_ARM" ] || { echo "FAIL[DG]: no alert_once arming sites were found in $SCRIPT -- the extraction has drifted and every count below would agree with zero"; fail=1; }
# Resolve `$FOO_KEY` to the key it holds, and strip the generation suffix.
dg_resolve() { # $1=raw token -> the bare key name
  case "$1" in
    '$'*) sed -n "s/^${1#\$}=\"\([A-Za-z_]*\)\"\$/\1/p" "$SCRIPT" | head -1 ;;
    *)    printf '%s' "${1%_\$WATCH_GEN}" ;;
  esac
}
: > "$DG_KEYS"
while read -r _dgtok; do
  _dgk="$(dg_resolve "$_dgtok")"
  [ -n "$_dgk" ] || { echo "FAIL[DG]: could not resolve the alert key token '$_dgtok' to a name"; fail=1; continue; }
  printf '%s\n' "$_dgk" >> "$DG_KEYS"
done < "$DG_ARM"
DG_NSITES="$(wc -l < "$DG_ARM" | tr -d ' ')"
DG_NKEYS="$(sort -u "$DG_KEYS" | wc -l | tr -d ' ')"
# What the comment claims.
DG_SAID="$(sed -n 's/^# patched where they were reported\. \([0-9][0-9]*\) keys across \([0-9][0-9]*\) arming sites.*/\1 \2/p' "$SCRIPT" | head -1)"
[ -n "$DG_SAID" ] || { echo "FAIL[DG]: the hook's alert-key census sentence could not be read, so nothing here compares anything"; fail=1; }
assert_eq "${DG_SAID% *}" "$DG_NKEYS"  DG
assert_eq "${DG_SAID#* }" "$DG_NSITES" DG
# ...and each class, by MEMBERSHIP as well as by count.
dg_class() { # $1=key -> watcher|episodic|record
  # -F, not a regex: BSD grep treats a `$` that is not the last character as an
  # anchor that can never match, so `"leasedegraded_$WATCH_GEN"` as a PATTERN
  # silently found nothing on this machine and every watcher-scoped key
  # classified as record-scoped.
  #   A watcher's identity is its GENERATION when it has one and its PID when it
  # does not (fin_key_set derives `$_fk_scope` for exactly that reason), so both
  # suffixes are the same class. Grepping only for `_$WATCH_GEN` classed the two
  # `_$_fk_scope` keys as record-scoped -- the very confusion the round-6
  # micro-review fixed in the hook, reappearing in the census that polices it.
  for _dgs in '$WATCH_GEN' '$_fk_scope'; do
    grep -qF "\"$1_$_dgs\"" "$SCRIPT" && { printf watcher; return; }
  done
  grep -q "rec_clear \"[^\"]*\" alerted_$1\$" "$SCRIPT" && { printf episodic; return; }
  printf record
}
for _dgc in watcher episodic record; do : > "$tmp/dg-live-$_dgc.txt"; done
for _dgk in $(sort -u "$DG_KEYS"); do printf '%s\n' "$_dgk" >> "$tmp/dg-live-$(dg_class "$_dgk").txt"; done
for _dgc in watcher episodic record; do sort -o "$tmp/dg-live-$_dgc.txt" "$tmp/dg-live-$_dgc.txt"; done
# The comment's own lists, parsed out of it. Every list and count below is a
# comparison against a PARSE of that comment, so a renamed heading would empty
# both sides of three of them; the headings are therefore asserted to exist
# first, with a message that names the rename rather than reporting `expected
# '2' got ''` (round 6: GENERATION-SCOPED became WATCHER-SCOPED and this case
# reported the drift as four unreadable numbers).
for _dgh in 'EPISODIC' 'WATCHER-SCOPED' 'RECORD-SCOPED, DELIBERATELY'; do
  grep -q "^#   $_dgh (" "$SCRIPT" \
    || { echo "FAIL[DG]: the hook has no '#   $_dgh (n)' alert-key class heading, so the lists and counts below compare against an empty parse"; fail=1; }
done
awk '/^#   EPISODIC \(/{e=1;next} /^#   WATCHER-SCOPED \(/{e=0} e && /^#     [a-z_]+ +-> /{gsub(/^#     /,"");print $1}' "$SCRIPT" | sort > "$tmp/dg-said-episodic.txt"
# `_<gen>` and `_<scope>` are the same class: see dg_class. BSD sed has no `\|`,
# so the alternation is two -e expressions rather than one pattern.
awk '/^#   WATCHER-SCOPED \(/{g=1;next} /^#   RECORD-SCOPED/{g=0} g' "$SCRIPT" \
  | tr ' ' '\n' | sed -n -e 's/^\([a-z_]*\)_<gen>$/\1/p' -e 's/^\([a-z_]*\)_<scope>$/\1/p' \
  | sort -u > "$tmp/dg-said-watcher.txt"
awk '/^#   RECORD-SCOPED/{r=1;next} r && /^#     [a-z_]+ —/{gsub(/^#     /,"");print $1}' "$SCRIPT" | sort > "$tmp/dg-said-record.txt"
for _dgc in watcher episodic record; do
  if ! diff -q "$tmp/dg-live-$_dgc.txt" "$tmp/dg-said-$_dgc.txt" >/dev/null 2>&1; then
    echo "FAIL[DG]: the hook's $_dgc alert-key list disagrees with the code."
    echo "  in the code, not in the comment: $(comm -23 "$tmp/dg-live-$_dgc.txt" "$tmp/dg-said-$_dgc.txt" | tr '\n' ' ')"
    echo "  in the comment, not in the code: $(comm -13 "$tmp/dg-live-$_dgc.txt" "$tmp/dg-said-$_dgc.txt" | tr '\n' ' ')"
    fail=1
  fi
done
# The declared per-class counts, which is where "(11)" left behind by a 13-member
# list shows up.
assert_eq "$(sed -n 's/^#   EPISODIC (\([0-9][0-9]*\)).*/\1/p' "$SCRIPT" | head -1)"          "$(wc -l < "$tmp/dg-live-episodic.txt" | tr -d ' ')" DG
assert_eq "$(sed -n 's/^#   WATCHER-SCOPED (\([0-9][0-9]*\)).*/\1/p' "$SCRIPT" | head -1)"      "$(wc -l < "$tmp/dg-live-watcher.txt" | tr -d ' ')"  DG
assert_eq "$(sed -n 's/^#   RECORD-SCOPED, DELIBERATELY (\([0-9][0-9]*\)).*/\1/p' "$SCRIPT" | head -1)" "$(wc -l < "$tmp/dg-live-record.txt" | tr -d ' ')" DG
# The extraction's own floor, in CM's shape: a pattern that stopped matching
# would agree with every count above at zero.
[ "$DG_NSITES" -ge 15 ] || { echo "FAIL[DG]: only $DG_NSITES arming sites were extracted, which is not a census of this file"; fail=1; }
# ...and its negative control: add an arming site and the numbers must move.
DGMUT="$tmp/handoff-dg-extra.sh"
awk '{print} /^  epoch \|\| return 3   # same rule as the deadline above/{print "  alert_once \"$REC\" dgprobe \"a probe\""}' "$SCRIPT" > "$DGMUT"
if cmp -s "$SCRIPT" "$DGMUT"; then
  echo "FAIL[DG]: the extra-site mutant is identical to the hook -- the anchor moved, and this control cannot fail"; fail=1
else
  DG_MUTN="$(grep -n 'alert_once "' "$DGMUT" | grep -v '^[0-9]*: *#' | sed 's/.*alert_once "[^"]*" //' | awk '{print $1}' | tr -d '"' | grep -cv '^rearm_\$')"
  [ "$DG_MUTN" = "$(( DG_NSITES + 1 ))" ] || { echo "FAIL[DG]: adding an arming site moved the extraction from $DG_NSITES to $DG_MUTN, not to $(( DG_NSITES + 1 )) -- it is not counting arming sites"; fail=1; }
fi
rm -f "$DGMUT"

# ---- DH. --help prints the WHOLE header, and no code ----------------------
# It printed `sed -n '2,120p'`, a line number retyped from a file that had grown
# to 2,300 lines: the operator got the header cut off mid-argument-list, and the
# only thing that could ever have noticed was a human reading the output (round
# 6, CA-1). The boundary is now derived from the source, so this asserts the
# derivation rather than a second retyped number.
DH_OUT="$(bash "$SCRIPT" --help 2>&1)"; dh_rc=$?
assert_eq "$dh_rc" "0" DH
DH_END="$(awk '/^set -u$/{print NR-1; exit}' "$SCRIPT")"
[ -n "$DH_END" ] || { echo "FAIL[DH]: no 'set -u' line in $SCRIPT -- the expected extent below is undefined"; fail=1; }
DH_WANT="$(sed -n "2,${DH_END}p" "$SCRIPT")"
[ "$DH_OUT" = "$DH_WANT" ] || {
  echo "FAIL[DH]: --help is not the header. printed $(printf '%s\n' "$DH_OUT" | wc -l | tr -d ' ') lines, header is $(printf '%s\n' "$DH_WANT" | wc -l | tr -d ' ')"
  echo "  first difference: $(diff <(printf '%s\n' "$DH_OUT") <(printf '%s\n' "$DH_WANT") | head -3 | tr '\n' ' ')"
  fail=1; }
# The two ends, named, so a header that grows at either end is covered by more
# than a line count: the LAST header line, and nothing of the code.
assert_contains "$(sed -n "${DH_END}p" "$SCRIPT")" "$DH_OUT" DH
assert_missing "set -u" "$DH_OUT" DH

# ---- DI. --dry-run prints a command whose word boundaries survive ----------
# The one answer --dry-run exists to give. Four operands went in raw, so a
# `--model` value or a path with a space or a `;` in it printed as something the
# real dispatch would never run -- and the operator, whose whole reason for
# running --dry-run is to check before spending money, could not see it (round 6,
# C5). DA's census covers the population; this covers the site.
DID="$tmp/di work"; mkdir -p "$DID"          # a space in the path, on purpose
DIHO="$DID/HANDOFF-di.md"; printf '# Handoff\n\nDo di.\n' > "$DIHO"
DI_MODEL="opus; touch $tmp/DI-PWNED"
DI_PMODE="plan; touch $tmp/DI-PWNED-P"
# EVERY operand of the printed line is adversarial, because the fixture is what
# decides which of them this case can see. It used to pass a space-free launcher
# path and no --permission-mode at all, so two of the five operands could be
# built WITHOUT shq and the case still passed -- reproduced twice on this branch
# (round 6 micro-review), and DA cannot cover for it because the census reads
# SHQ-vs-RAW off the variable NAME and not off how the variable was filled.
DIBINDIR="$tmp/di bin"; mkdir -p "$DIBINDIR"
DIBIN="$DIBINDIR/cl;aude"                   # a space AND a metacharacter
cp "$tmp/dabin/claude" "$DIBIN"; chmod +x "$DIBIN"
rm -f "$tmp/DI-PWNED" "$tmp/DI-PWNED-P"
# CLAUDE_BIN is pointed at the ARGV-RECORDING shim, because the printed command
# names the launcher by its absolute path -- so evaluating it runs whatever
# CLAUDE_BIN was at print time, and a PATH override below would be ignored.
DI_OUT="$(CLAUDE_BIN="$DIBIN" bash "$SCRIPT" "$DIHO" "an objective" --cwd "$DID" --model "$DI_MODEL" --permission-mode "$DI_PMODE" --dry-run 2>&1)"; di_rc=$?
assert_eq "$di_rc" "0" DI
DI_CMD="$(printf '%s\n' "$DI_OUT" | sed -n 's/ --append-system-prompt <charter> <prompt>$//p' | head -1)"
[ -n "$DI_CMD" ] || { echo "FAIL[DI]: --dry-run printed no launch command, so this case asserts nothing -- got: $DI_OUT"; fail=1; }
# The two operands that are megabytes of text are placeholders; everything else
# is a real word, and the shim records exactly which words arrived.
rm -f "$tmp/di-args.txt"
( PATH="$tmp/dabin:$PATH" DA_ARGS="$tmp/di-args.txt" eval "$DI_CMD" ) >/dev/null 2>&1
assert_no_file "$tmp/DI-PWNED" DI
assert_no_file "$tmp/DI-PWNED-P" DI
# The launcher path is the FIRST word, so an unquoted one is not a wrong
# argument -- it is a different command, and the recording file is never written
# at all. That is why the file is removed just above: a stale one from an
# earlier eval would answer for this one.
[ -f "$tmp/di-args.txt" ] || { echo "FAIL[DI]: evaluating the printed line ran no launcher, so the words of the path did not survive printing -- printed: $DI_CMD"; fail=1; }
assert_eq "$(sed -n 1p "$tmp/di-args.txt" 2>/dev/null)" "--bg" DI
assert_eq "$(sed -n 2p "$tmp/di-args.txt" 2>/dev/null)" "--model" DI
assert_eq "$(sed -n 3p "$tmp/di-args.txt" 2>/dev/null)" "$DI_MODEL" DI
assert_eq "$(sed -n 4p "$tmp/di-args.txt" 2>/dev/null)" "--permission-mode" DI
assert_eq "$(sed -n 5p "$tmp/di-args.txt" 2>/dev/null)" "$DI_PMODE" DI
assert_eq "$(sed -n 6p "$tmp/di-args.txt" 2>/dev/null)" "" DI
# The path with a space in it survives as ONE word in the prose line too. The
# expected spelling is the RESOLVED one (`resolve_path` is what the launcher
# prints), derived here rather than retyped -- on macOS $TMPDIR is itself a
# symlink, so comparing against the unresolved path would fail for a reason that
# has nothing to do with quoting.
DI_DIR_ABS="$(cd "$DID" && pwd -P)"
assert_contains "'$DI_DIR_ABS/HANDOFF-di.md'" "$DI_OUT" DI
assert_contains "'$DI_DIR_ABS'" "$DI_OUT" DI
# The seam's own control: the SAME paste, unquoted, does fire the marker -- so
# the assertion above is about the quoting and not about a shim that cannot write.
rm -f "$tmp/DI-PWNED" "$tmp/DI-PWNED-P"
( PATH="$tmp/dabin:$PATH" DA_ARGS="$tmp/di-args2.txt" eval "claude --bg --model $DI_MODEL" ) >/dev/null 2>&1
[ -f "$tmp/DI-PWNED" ] || { echo "FAIL[DI]: the unquoted control did not fire, so DI cannot tell quoting from a dead fixture"; fail=1; }
# The same control for the LAUNCHER PATH, which is the operand a wrong word
# boundary destroys most completely: unquoted, the first word is not a command.
( PATH="$tmp/dabin:$PATH" DA_ARGS="$tmp/di-args3.txt" eval "$DIBIN --bg" ) >/dev/null 2>&1
[ -f "$tmp/di-args3.txt" ] && { echo "FAIL[DI]: the unquoted launcher path still ran the launcher, so the path fixture has no metacharacter left in it"; fail=1; }
rm -f "$tmp/DI-PWNED" "$tmp/DI-PWNED-P" "$tmp/di-args3.txt"

# ---- DJ. every `handoff.sh --<flag>` we PRINT is one the parser accepts ------
# The alerts and die messages hand the operator a recovery command by name --
# `check \`handoff.sh --status\`` -- and nothing until now compared that name
# against the option parser. Round 6 test-quality #2's surviving mutation was
# exactly that trade: rename the printed flag to `--stats`, and the operator
# following an UNWATCHED-successor alert is answered with `unknown option:
# --stats` at the one moment they need the status. Both census counts, the
# marker transitions and the suite total all held.
# The population is DERIVED from the two surfaces that print it -- the hook and
# the operator doc -- so a fifth site with a fourth flag joins this case by
# existing, not by someone remembering to add it.
DJ_FLAGS="$( { grep -o 'handoff\.sh --[a-z][a-z-]*' "$SCRIPT"
               grep -o 'handoff\.sh --[a-z][a-z-]*' "$(cd "$(dirname "$0")/.." && pwd)/docs/handoff-successor.md" 2>/dev/null
             } | sed 's|^handoff\.sh ||' | sort -u )"
[ -n "$DJ_FLAGS" ] || { echo "FAIL[DJ]: no printed handoff.sh flags were found, so this case asserts nothing"; fail=1; }
DJ_N=0
for dj_f in $DJ_FLAGS; do
  DJ_N=$(( DJ_N + 1 ))
  # Driven through the REAL parser. Every one of these flags needs an operand or
  # does work, so a nonzero exit is expected and is not the assertion -- the
  # assertion is that the refusal is never the parser's catch-all. Asserting the
  # exit code here would pass on the mutant, which is defect shape 3.
  dj_out="$(cd "$tmp" && bash "$SCRIPT" "$dj_f" 2>&1)"
  case "$dj_out" in
    *"unknown option: $dj_f"*)
      echo "FAIL[DJ]: the hook prints \`handoff.sh $dj_f\` for an operator to run, but its own parser answers: $dj_out"; fail=1 ;;
  esac
done
[ "$DJ_N" -ge 3 ] || { echo "FAIL[DJ]: only $DJ_N printed flag(s) were extracted -- the extraction has drifted from the printed text"; fail=1; }
# The control: a flag nobody prints IS refused by the catch-all, so the loop
# above is reading the parser's real answer and not an output it can never see.
dj_out="$(cd "$tmp" && bash "$SCRIPT" --stats 2>&1)"
case "$dj_out" in
  *"unknown option: --stats"*) : ;;
  *) echo "FAIL[DJ]: an unprinted flag was not refused by the catch-all ($dj_out) -- this case cannot tell an accepted flag from a rejected one"; fail=1 ;;
esac

# ---- DK. a record read that could not answer is not "the successor is gone" --
# The watchdog asks the agent list under TWO spellings, because a row can be keyed
# by the short id or by the session uuid, and it reads the uuid out of the record
# to ask the second one. That read was `rec_read ... || true`, so a read that TIMED
# OUT arrived as an empty uuid: the second probe was silently skipped, "not there
# under the short id" became "not there", and the watcher recorded the successor
# FINISHED and stood down on an observation it never made (round 6 micro-review,
# HIGH). The record write is the damage -- it is what the next poll and the next
# dispatch both believe.
DKD="$tmp/dk"; mkdir -p "$DKD/bin"
cat > "$DKD/bin/sed" <<'DKSH'
#!/bin/sh
if [ -f "$DK_HANG" ]; then
  for a in "$@"; do case "$a" in *session_uuid*) sleep 8 ;; esac; done
fi
exec /usr/bin/sed "$@"
DKSH
chmod +x "$DKD/bin/sed"
# The row is keyed by the UUID and NOT by the short id, which is the only shape in
# which the second probe decides anything. A fixture where both spellings answer
# alike cannot see this bug: the code asks twice precisely for this row.
dk_json() { printf '[{"id":"dk-other-id","cwd":"%s","kind":"background","startedAt":1787000000000,"sessionId":"%s","state":"running"}]\n' "$tmp/work" "$UUID" > "$SHIM_AGENTS"; }
dk_run() { # $1=script $2=record -> DK_OUT / DK_RC
  : > "$DKD/hang"
  DK_OUT="$(env DK_HANG="$DKD/hang" PATH="$DKD/bin:$PATH" CLAUDE_HANDOFF_FS_TIMEOUT=2 \
              bash "$1" --watch-once "$2" 2>&1)"; DK_RC=$?
  rm -f "$DKD/hang"
}
DKHO="$(NEWHO dk)"; DKREC="$DKHO.dispatch"
live_json "running"; GOF "$DKHO" "dk" >/dev/null 2>&1
dk_json
dk_run "$SCRIPT" "$DKREC"
assert_eq "$DK_RC" "3" DK
assert_contains "cannot tell whether successor" "$DK_OUT" DK
assert_rec_missing "$DKREC" "finished=1" DK
# The control: without the elif, the skipped probe is silent again and the SAME
# fixture reaches the terminal write -- so the assertions above are about the
# tri-state and not about a fixture that never gets there.
DKMUT="$tmp/handoff-dk-silent.sh"
sed 's/^  elif \[ "\$PRESENT" = 0 \] \&\& \[ "\$_urs" != 0 \]; then$/  elif false; then/' "$SCRIPT" > "$DKMUT"
if cmp -s "$SCRIPT" "$DKMUT"; then
  echo "FAIL[DK]: the skipped-probe mutant is identical to the hook -- the guard moved, and this control cannot fail"; fail=1
else
  DKHO2="$(NEWHO dk-mut)"; DKREC2="$DKHO2.dispatch"
  live_json "running"; GOF "$DKHO2" "dk-mut" >/dev/null 2>&1
  dk_json
  dk_run "$DKMUT" "$DKREC2"
  assert_rec "$DKREC2" "finished=1" DK
fi
rm -f "$DKMUT"
live_json "running"

# ---- DL. an unreadable record does not clear a degraded heartbeat marker ----
# The handoff file's mtime is the second heartbeat source, and its path comes out
# of the record. `rec_read ... || true` made "the record could not be read"
# indistinguishable from "there is no handoff file": that arm reported neither a
# beat nor a failure, so with the transcript arm also silent the poll fell through
# to `rec_clear alerted_beatdegraded` and returned healthy -- clearing a STANDING
# outage marker on the strength of a read that never happened (round 6
# micro-review, HIGH). Same shape as DK, second site, and the damage is the clear.
DLD="$tmp/dl"; mkdir -p "$DLD/bin"
cat > "$DLD/bin/sed" <<'DLSH'
#!/bin/sh
if [ -f "$DL_HANG" ]; then
  for a in "$@"; do case "$a" in *'^handoff='*) sleep 8 ;; esac; done
fi
exec /usr/bin/sed "$@"
DLSH
chmod +x "$DLD/bin/sed"
# An empty projects directory, so the transcript arm has nothing to offer and the
# handoff-file arm is the only one left -- the interleaving in which a failed read
# decides the answer.
DLPROJ="$tmp/dl-projects"; rm -rf "$DLPROJ"; mkdir -p "$DLPROJ/-slug"
dl_run() { # $1=script $2=record -> DL_OUT / DL_RC
  : > "$DLD/hang"
  DL_OUT="$(env DL_HANG="$DLD/hang" PATH="$DLD/bin:$PATH" CLAUDE_HANDOFF_FS_TIMEOUT=2 \
              CLAUDE_PROJECTS_DIR="$DLPROJ" bash "$1" --watch-once "$2" 2>&1)"; DL_RC=$?
  rm -f "$DLD/hang"
}
DLHO="$(NEWHO dl)"; DLREC="$DLHO.dispatch"
live_json "running"; GOF "$DLHO" "dl" >/dev/null 2>&1
# A marker is already standing. THIS is what the poll must not clear.
printf 'alerted_beatdegraded=1\n' >> "$DLREC"
dl_run "$SCRIPT" "$DLREC"
assert_eq "$DL_RC" "3" DL
assert_rec_last "$DLREC" alerted_beatdegraded 1 DL
DLMUT="$tmp/handoff-dl-clears.sh"
sed 's/^  \[ "\$_hors" = 0 \] || FSFAIL=1$/  :/' "$SCRIPT" > "$DLMUT"
if cmp -s "$SCRIPT" "$DLMUT"; then
  echo "FAIL[DL]: the unread-arm mutant is identical to the hook -- the FSFAIL guard moved, and this control cannot fail"; fail=1
else
  DLHO2="$(NEWHO dl-mut)"; DLREC2="$DLHO2.dispatch"
  live_json "running"; GOF "$DLHO2" "dl-mut" >/dev/null 2>&1
  printf 'alerted_beatdegraded=1\n' >> "$DLREC2"
  dl_run "$DLMUT" "$DLREC2"
  assert_rec_last "$DLREC2" alerted_beatdegraded 0 DL
fi
rm -f "$DLMUT"

# ---- DM. a projects directory that cannot be listed is not "no transcript" ---
# `transcript_for` globbed and then `return 0` unconditionally, so a projects
# directory this process may not ENUMERATE -- the glob stays unexpanded, `[ -f ]`
# is false, nothing is printed -- arrived at the caller as a clean observation
# that the successor has written no transcript (round 6 micro-review, HIGH). The
# same C4 mistake one layer up: an unmatched glob answers FALSE for "absent" and
# for "I was not allowed to look".
DMPROJ="$tmp/dm-projects"; rm -rf "$DMPROJ"; mkdir -p "$DMPROJ/-slug"
DMHO="$(NEWHO dm)"; DMREC="$DMHO.dispatch"
live_json "running"; GOF "$DMHO" "dm" >/dev/null 2>&1
# The deadline has to be judgeable and long past, or "no transcript" is withheld
# for the grace window and the control below could not report it either way.
printf 'dispatched_epoch=1\n' >> "$DMREC"
chmod 000 "$DMPROJ"
# THE FIXTURE'S OWN PRECONDITION. Running as root, or on a filesystem that does
# not enforce the mode, makes this case pass for a reason that has nothing to do
# with the code -- so it checks that the directory really is unlistable before
# believing anything it observes.
if perl -e 'opendir(my $d, $ARGV[0]) or exit 1; exit 0' "$DMPROJ" 2>/dev/null; then
  chmod 755 "$DMPROJ"
  echo "FAIL[DM]: the unlistable projects directory is still listable (running as root?) -- this case cannot observe what it claims to"; fail=1
else
  DM_OUT="$(env CLAUDE_PROJECTS_DIR="$DMPROJ" bash "$SCRIPT" --watch-once "$DMREC" 2>&1)"; dm_rc=$?
  assert_eq "$dm_rc" "3" DM
  assert_contains "cannot read the filesystem to locate" "$DM_OUT" DM
  assert_missing "has written no transcript" "$DM_OUT" DM
  # AND IT NAMES WHAT ACTUALLY HAPPENED. This fixture is not slow: the directory
  # is unlistable and will stay unlistable. The message said "timed out after
  # ${FS_TIMEOUT_SEC}s" anyway -- as did ten of its siblings -- because a
  # timeout was the only cause anyone had in mind when they were written, and
  # `fs_get` collapses every failure into 2 for the caller (round 6 micro-review
  # 2). An operator told the mount is slow waits for it to come back; an operator
  # told the read was refused fixes the permission. A degraded observation may
  # not name a cause it did not observe, which is the same invariant as the blank
  # timestamp one layer down.
  assert_contains "I could not look" "$DM_OUT" DM
  assert_missing "tell those apart" "$DM_OUT" DM
  # The control: delete the errno probe and the same fixture reports an absence it
  # never observed.
  DMMUT="$tmp/handoff-dm-blind.sh"
  sed 's/^    \[ \$? = 2 \] \&\& return 2$/    :/' "$SCRIPT" > "$DMMUT"
  if cmp -s "$SCRIPT" "$DMMUT"; then
    echo "FAIL[DM]: the blind-glob mutant is identical to the hook -- transcript_for's errno probe moved, and this control cannot fail"; fail=1
  else
    chmod 755 "$DMPROJ"
    DMHO2="$(NEWHO dm-mut)"; DMREC2="$DMHO2.dispatch"
    live_json "running"; GOF "$DMHO2" "dm-mut" >/dev/null 2>&1
    printf 'dispatched_epoch=1\n' >> "$DMREC2"
    chmod 000 "$DMPROJ"
    DM_OUT2="$(env CLAUDE_PROJECTS_DIR="$DMPROJ" bash "$DMMUT" --watch-once "$DMREC2" 2>&1)"
    assert_contains "has written no transcript" "$DM_OUT2" DM
  fi
  rm -f "$DMMUT"
  # The control for the cause, separately from the control for the observation:
  # route the refusal to the killed arm instead and the same fixture prints a
  # sentence about a status it never saw -- status 143-shaped, signal-shaped --
  # for a directory that answered at once with its own 2. (The arm is spelled
  # `killed`, not `deadline`: 128+N says the child ended with a signal-shaped
  # status and nothing more, so the text may not assert WHICH -- round 6
  # micro-review 3, and micro-review 4 for why it may not assert that it was
  # signalled at all.)
  DMMUT3="$tmp/handoff-dm-alltimeout.sh"
  sed 's/^    elif \[ "\$_fgr" = 2 \]; then fs_why_set refused "\$_fgs" "\$_fgr"$/    elif [ "$_fgr" = 2 ]; then fs_why_set killed "$_fgs" "$_fgr"/' "$SCRIPT" > "$DMMUT3"
  if cmp -s "$SCRIPT" "$DMMUT3"; then
    echo "FAIL[DM]: the all-killed mutant is identical to the hook -- fs_get's status discrimination moved, and this control cannot fail"; fail=1
  else
    chmod 755 "$DMPROJ"
    DMHO3="$(NEWHO dm-why)"; DMREC3="$DMHO3.dispatch"
    live_json "running"; GOF "$DMHO3" "dm-why" >/dev/null 2>&1
    printf 'dispatched_epoch=1\n' >> "$DMREC3"
    chmod 000 "$DMPROJ"
    DM_OUT3="$(env CLAUDE_PROJECTS_DIR="$DMPROJ" bash "$DMMUT3" --watch-once "$DMREC3" 2>&1)"
    assert_contains "tell those apart" "$DM_OUT3" DM
  fi
  rm -f "$DMMUT3"
  chmod 755 "$DMPROJ"
fi

# ---- DN. a marker written while the clock is down carries a fact, not a blank -
# `now_utc` on one line and `rec_put <key> "$NOW_UTC"` on the next appended
# `monitoring_expired=` when `date` would not answer: the marker read as present
# and dated to nothing. `rec_has` still saw it and every assertion in this suite
# matched `key=.*`, which is why it survived C3 -- and the record is what a human
# reads to reconstruct what happened (round 6 micro-review). A degraded
# observation may not become a value, and a blank timestamp is one wearing the
# clothes of a value.
DND="$tmp/dn"; mkdir -p "$DND/bin"
# The clock fails for the ISO format ONLY. `epoch` reads `+%s` and has to keep
# working, or the watcher stands down on the clock-loss path and never reaches an
# expiry at all -- the window this case is about.
cat > "$DND/bin/date" <<'DNSH'
#!/bin/sh
case "$*" in *%FT%TZ*) exit 1 ;; esac
exec /bin/date "$@"
DNSH
chmod +x "$DND/bin/date"
DNHO="$(NEWHO dn)"; DNREC="$DNHO.dispatch"
live_json "running"; GOF "$DNHO" "dn" >/dev/null 2>&1
: > "$transcript"
DN_LOGN="$(wc -l < "$CLAUDE_HANDOFF_LOG" 2>/dev/null || echo 0)"
DN_OUT="$(env PATH="$DND/bin:$PATH" CLAUDE_HANDOFF_MAX_HOURS=0 bash "$SCRIPT" --watch "$DNREC" 2>&1)"
assert_contains "EXPIRED" "$DN_OUT" DN
assert_rec "$DNREC" "monitoring_expired=clock-unavailable" DN
assert_rec_missing "$DNREC" "monitoring_expired=" DN
# The loss is logged WHERE IT HAPPENED, rather than inferred later from an empty
# field -- and only the lines this run appended count, or a neighbouring case's
# log line would satisfy the assertion.
DN_LOG="$(tail -n "+$(( DN_LOGN + 1 ))" "$CLAUDE_HANDOFF_LOG")"
assert_contains "HandoffClockLostAtMarker" "$DN_LOG" DN
# The control: put the blank back and the same fixture writes the empty stamp.
DNMUT="$tmp/handoff-dn-blank.sh"
sed 's|rec_put "\$1" "\$2" "clock-unavailable"|rec_put "$1" "$2" ""|' "$SCRIPT" > "$DNMUT"
if cmp -s "$SCRIPT" "$DNMUT"; then
  echo "FAIL[DN]: the blank-stamp mutant is identical to the hook -- rec_stamp's sentinel moved, and this control cannot fail"; fail=1
else
  DNHO2="$(NEWHO dn-mut)"; DNREC2="$DNHO2.dispatch"
  live_json "running"; GOF "$DNHO2" "dn-mut" >/dev/null 2>&1
  env PATH="$DND/bin:$PATH" CLAUDE_HANDOFF_MAX_HOURS=0 bash "$DNMUT" --watch "$DNREC2" >/dev/null 2>&1
  assert_rec "$DNREC2" "monitoring_expired=" DN
  assert_rec_missing "$DNREC2" "monitoring_expired=clock-unavailable" DN
fi
rm -f "$DNMUT"

# ---- DP. every clock reading is spent through rec_stamp, or named as not -----
# DN proves the SENTINEL is right at one marker. It cannot prove the other four
# markers still go through the helper that writes it: reverting any one site to
# the two-line form it came from --
#     now_utc || true
#     rec_put "$_rr" watch_reattached "$NOW_UTC" || true
# -- reintroduces the exact blank-timestamp defect at that site and the whole
# suite stays green, because no case reads that marker under a broken clock
# (round 6 micro-review 2 -- built as a whole-file mutant and run: PASS). That is
# the shape a consolidation always has: the helper is tested, the CONSOLIDATION
# is not, and the next site to drift out of it drifts silently.
#   So census the consumers instead of the helper. A clock reading may be spent
# in exactly three ways, and every one of them is a place where a failed read
# cannot become a value:
#   stamp      -- inside rec_stamp, which substitutes the sentinel;
#   guarded    -- the dispatch pair, written only when `now_utc && epoch` both
#                 succeeded, and omitted entirely otherwise;
#   annotation -- the lock file's informational line, which defaults to the
#                 sentinel and reaches no record.
# Anything else is a fourth way, and the census names the file and line rather
# than only disagreeing about a number.
dp_census() { # $1=script -> DP_TOT/DP_ST/DP_GU/DP_AN/DP_OT/DP_OTL
  _dpnua="$(grep -n '^now_utc() {$' "$1" | cut -d: -f1 | head -1)"
  _dprsa="$(grep -n '^rec_stamp() {' "$1" | cut -d: -f1 | head -1)"
  _dpg="$(grep -n 'if now_utc && epoch; then$' "$1" | cut -d: -f1 | head -1)"
  # EVERY ANCHOR IS CHECKED BEFORE IT IS USED. An anchor that stopped matching
  # would make the classification below run against nothing and every count come
  # out 0 -- the failure mode that put DG's census to sleep for a whole round.
  for _dpa in "now_utc() {:$_dpnua" "rec_stamp() {:$_dprsa" "if now_utc && epoch; then:$_dpg"; do
    case "$_dpa" in
      *:) echo "FAIL[DP]: ${1##*/} has no \`${_dpa%:*}\` line, so this census classifies against an empty parse"; fail=1 ;;
    esac
  done
  _dpnub="$(awk -v a="$_dpnua" 'NR>a && /^}$/{print NR; exit}' "$1")"
  _dprsb="$(awk -v a="$_dprsa" 'NR>a && /^}$/{print NR; exit}' "$1")"
  awk -v nua="$_dpnua" -v nub="$_dpnub" -v rsa="$_dprsa" -v rsb="$_dprsb" -v g="$_dpg" '
    index($0,"$NOW_UTC")==0 && index($0,"${NOW_UTC")==0 { next }
    { l=$0; sub(/^[ \t]+/,"",l); if (substr(l,1,1)=="#") next }
    NR>=nua && NR<=nub { next }
    NR>=rsa && NR<=rsb { print "stamp " NR " " $0; next }
    index($0,"${NOW_UTC:-clock-unavailable}")>0 { print "annotation " NR " " $0; next }
    NR==g+1 { print "guarded " NR " " $0; next }
    { print "other " NR " " $0 }
  ' "$1" > "$tmp/dp-class.txt"
  DP_TOT="$(wc -l < "$tmp/dp-class.txt" | tr -d ' ')"
  DP_ST="$(grep -c '^stamp ' "$tmp/dp-class.txt" | tr -d ' ')"
  DP_GU="$(grep -c '^guarded ' "$tmp/dp-class.txt" | tr -d ' ')"
  DP_AN="$(grep -c '^annotation ' "$tmp/dp-class.txt" | tr -d ' ')"
  DP_OT="$(grep -c '^other ' "$tmp/dp-class.txt" | tr -d ' ')"
  DP_OTL="$(grep '^other ' "$tmp/dp-class.txt")"
}
dp_census "$SCRIPT"
# Non-zero FIRST: a census that found nothing agrees with every claim made about
# it, so the population is asserted before its shape is.
[ "$DP_TOT" = 0 ] && { echo "FAIL[DP]: no \$NOW_UTC consumer was found in $SCRIPT at all -- the classification below is over an empty set"; fail=1; }
assert_eq "$DP_ST" "1" DP
assert_eq "$DP_GU" "1" DP
assert_eq "$DP_AN" "1" DP
assert_eq "$DP_TOT" "3" DP
[ "$DP_OT" = 0 ] || { echo "FAIL[DP]: a clock reading is spent outside rec_stamp, outside the guarded dispatch pair and outside the lock annotation, so a failed \`date\` can be stored as a time there:"; printf '%s\n' "$DP_OTL"; fail=1; }
# And the five markers that need a stamp still ASK for one. A count cannot say
# WHICH site lost the helper -- that is what the `other` bucket above is for;
# this one catches the site that drops the marker altogether rather than
# reverting it, which the bucket cannot see.
DP_CALLS="$(grep -c '^ *rec_stamp "' "$SCRIPT" | tr -d ' ')"
assert_eq "$DP_CALLS" "5" DP

# The control: revert one site to the two-line form and the census names it.
DPMUT="$tmp/handoff-dp-raw.sh"
sed 's%^  rec_stamp "\$_rr" watch_reattached || true$%  now_utc || true\
  rec_put "$_rr" watch_reattached "$NOW_UTC" || true%' "$SCRIPT" > "$DPMUT"
if cmp -s "$SCRIPT" "$DPMUT"; then
  echo "FAIL[DP]: the raw-stamp mutant is identical to the hook -- the watch_reattached stamp moved, and this control cannot fail"; fail=1
else
  _dpsO="$DP_OT"
  dp_census "$DPMUT"
  assert_eq "$DP_OT" "1" DP
  case "$DP_OTL" in
    *watch_reattached*) ;;
    *) echo "FAIL[DP]: the census flagged something, but not the reverted watch_reattached stamp -- got: $DP_OTL"; fail=1 ;;
  esac
  DP_OT="$_dpsO"
fi
rm -f "$DPMUT"


# ---- DQ. a clock that answers WRONGLY is not a clock ------------------------
# `now_utc` has TWO refusal arms and until now neither was pinned. DN is the only
# ISO-clock fixture in the suite and its `date` exits 1 printing NOTHING, which
# the ORIGINAL body -- `NOW_UTC="$(date …)"; [ -n "$NOW_UTC" ]` -- also refuses,
# on the emptiness test. So DN goes green on a hook with no status check and no
# shape check at all: reverting `now_utc` to that body is a whole-file mutant
# that passes the entire suite (round 6 micro-review 3, built and run: PASS).
# What the arms exist for is a `date` that ANSWERS -- a partial write, a signal
# mid-format, a PATH shim that answers wrongly -- and no fixture ever made one.
#   The arms need SEPARATE fixtures, because each is only reachable where the
# ones before it do not already refuse. A shim printing `partial` is caught by
# the shape check whether or not the status is read, so it cannot pin the status
# arm; a shim exiting 0 is passed by the status check whether or not the shape is
# read; a shim printing `not-a-time` is caught by the shape check before the
# range check is ever reached. Hence: A answers with a WELL-FORMED time and
# fails, B answers with a malformed one and succeeds, and C answers with a time
# whose SHAPE is right and whose fields are not, and succeeds.
#   ARM C IS SEVEN FIXTURES, not one. It began as the single value
# `2026-99-99T99:99:99Z` -- wrong in every field -- which any ONE of the five
# range conjuncts refutes, so four of them were pinned by nothing: a hook keeping
# only the month check PASSED this case (round 6 micro-review 5, built and run).
# It now drives five fixtures each wrong in exactly ONE field, every one of them
# expected to be REFUSED, plus the two ACCEPTANCES the range comment's calendar
# argument turns on and nothing had ever tested -- a leap second and the calendar
# floor -- expected to be STORED, so a "tightening" that refuses either fails
# here rather than passing. A structural census of the five conjuncts follows
# them, because a sixth field could otherwise be added and validated nowhere.
# Arms A and B have one control each; arm C's control is run against all five of
# its refusal fixtures.
#   Arm C is here because the shape check WAS the whole test and micro-review 4
# reproduced `2026-99-99T99:99:99Z` reaching the record as a successful
# timestamp.
DQD="$tmp/dq"; mkdir -p "$DQD/bin"
# As in DN, only the ISO format is affected: `epoch` reads `+%s` and must keep
# working or the watcher stands down before it ever reaches an expiry.
cat > "$DQD/bin/date" <<'DQSH'
#!/bin/sh
case "$*" in
  *%FT%TZ*)
    if [ -f "$DQ_MALFORMED" ]; then echo "not-a-time"; exit 0; fi
    # The FILE CARRIES THE ANSWER, so one shim serves every range fixture. It
    # used to hardcode `2026-99-99T99:99:99Z`, which is out of range in all five
    # fields at once and therefore refused by any ONE surviving check: a hook
    # validating only the month passed the whole case (round 6 micro-review 5,
    # built and run: PASS). One field wrong per fixture is what pins five checks.
    if [ -s "$DQ_IMPOSSIBLE" ]; then cat "$DQ_IMPOSSIBLE"; exit 0; fi
    echo "1970-01-01T00:00:00Z"; exit 1 ;;
esac
exec /bin/date "$@"
DQSH
chmod +x "$DQD/bin/date"
dq_run() { # $1=script $2=record $3=A|B|C  $4=the answer C's clock gives -> DQ_OUT
  rm -f "$DQD/malformed" "$DQD/impossible"
  [ "$3" = B ] && : > "$DQD/malformed"
  [ "$3" = C ] && printf '%s\n' "${4:-}" > "$DQD/impossible"
  DQ_OUT="$(env PATH="$DQD/bin:$PATH" DQ_MALFORMED="$DQD/malformed" \
    DQ_IMPOSSIBLE="$DQD/impossible" \
    CLAUDE_HANDOFF_MAX_HOURS=0 bash "$1" --watch "$2" 2>&1)"
  rm -f "$DQD/malformed" "$DQD/impossible"
}
# THE FIXTURE'S OWN PRECONDITION, both directions. If the shim were not on PATH
# -- a `date` builtin, a PATH the hook rebuilds, an `exec` that misses -- every
# assertion below would pass on the real clock's well-formed answer, because
# `monitoring_expired` would simply carry a real timestamp and the `missing`
# assertions would hold for the wrong reason.
DQ_PROBE_A="$(env PATH="$DQD/bin:$PATH" DQ_MALFORMED="$DQD/nope" DQ_IMPOSSIBLE="$DQD/nope" sh -c 'date -u +%FT%TZ; echo "rc=$?"')"
assert_contains "rc=1" "$DQ_PROBE_A" DQ
assert_contains "1970-01-01T00:00:00Z" "$DQ_PROBE_A" DQ
: > "$DQD/malformed"
DQ_PROBE_B="$(env PATH="$DQD/bin:$PATH" DQ_MALFORMED="$DQD/malformed" DQ_IMPOSSIBLE="$DQD/nope" sh -c 'date -u +%FT%TZ; echo "rc=$?"')"
assert_contains "rc=0" "$DQ_PROBE_B" DQ
assert_contains "not-a-time" "$DQ_PROBE_B" DQ
rm -f "$DQD/malformed"
printf '2026-13-15T12:30:45Z\n' > "$DQD/impossible"
DQ_PROBE_C="$(env PATH="$DQD/bin:$PATH" DQ_MALFORMED="$DQD/nope" DQ_IMPOSSIBLE="$DQD/impossible" sh -c 'date -u +%FT%TZ; echo "rc=$?"')"
assert_contains "rc=0" "$DQ_PROBE_C" DQ
assert_contains "2026-13-15T12:30:45Z" "$DQ_PROBE_C" DQ
rm -f "$DQD/impossible"

# --- arm 1: the status. A well-formed answer from a `date` that FAILED. -------
DQHO="$(NEWHO dq-a)"; DQREC="$DQHO.dispatch"
live_json "running"; GOF "$DQHO" "dq-a" >/dev/null 2>&1
: > "$transcript"
dq_run "$SCRIPT" "$DQREC" A
assert_contains "EXPIRED" "$DQ_OUT" DQ
assert_rec "$DQREC" "monitoring_expired=clock-unavailable" DQ
assert_rec_missing "$DQREC" "monitoring_expired=1970-01-01T00:00:00Z" DQ

# Its control: stop reading `date`'s exit status and the same fixture stores the
# time of a clock that failed. The shape check is LEFT IN, so this control can
# only go red on the arm it names.
DQMUT1="$tmp/handoff-dq-nostatus.sh"
# `%` and not `|` as the delimiter: the anchor CONTAINS `||`, which closes the
# pattern early and makes sed refuse the script -- reproduced while writing this.
sed 's%)" || { NOW_UTC=""; return 1; }   # CLAIM:d%)"   # CLAIM:d%' "$SCRIPT" > "$DQMUT1"
if cmp -s "$SCRIPT" "$DQMUT1"; then
  echo "FAIL[DQ]: the no-status mutant is identical to the hook -- now_utc's status check moved, and this control cannot fail"; fail=1
else
  DQHO2="$(NEWHO dq-a-mut)"; DQREC2="$DQHO2.dispatch"
  live_json "running"; GOF "$DQHO2" "dq-a-mut" >/dev/null 2>&1
  dq_run "$DQMUT1" "$DQREC2" A
  assert_rec "$DQREC2" "monitoring_expired=1970-01-01T00:00:00Z" DQ
  assert_rec_missing "$DQREC2" "monitoring_expired=clock-unavailable" DQ
fi
rm -f "$DQMUT1"

# --- arm 2: the shape. A malformed answer from a `date` that SUCCEEDED. -------
DQHO3="$(NEWHO dq-b)"; DQREC3="$DQHO3.dispatch"
live_json "running"; GOF "$DQHO3" "dq-b" >/dev/null 2>&1
dq_run "$SCRIPT" "$DQREC3" B
assert_contains "EXPIRED" "$DQ_OUT" DQ
assert_rec "$DQREC3" "monitoring_expired=clock-unavailable" DQ
assert_rec_missing "$DQREC3" "monitoring_expired=not-a-time" DQ

# Its control: accept any shape and the same fixture stores `not-a-time` as a
# timestamp. The status check is LEFT IN, so this one too can only go red on the
# arm it names.
DQMUT2="$tmp/handoff-dq-noshape.sh"
# The DEFAULT arm is the anchor, not the well-formed one: the well-formed arm now
# falls through to the range check below it (`: ;;`), so mutating it would remove
# nothing. Returning 0 from the default arm accepts every shape AND skips the
# range check, which is what "no shape check at all" means; the range control
# below removes the range arm on its own.
sed 's|^    \*) NOW_UTC=""; return 1 ;;$|    *) return 0 ;;|' "$SCRIPT" > "$DQMUT2"
if cmp -s "$SCRIPT" "$DQMUT2"; then
  echo "FAIL[DQ]: the any-shape mutant is identical to the hook -- now_utc's shape check moved, and this control cannot fail"; fail=1
else
  DQHO4="$(NEWHO dq-b-mut)"; DQREC4="$DQHO4.dispatch"
  live_json "running"; GOF "$DQHO4" "dq-b-mut" >/dev/null 2>&1
  dq_run "$DQMUT2" "$DQREC4" B
  assert_rec "$DQREC4" "monitoring_expired=not-a-time" DQ
  assert_rec_missing "$DQREC4" "monitoring_expired=clock-unavailable" DQ
fi
rm -f "$DQMUT2"

# --- arm 3: the range. A well-shaped answer that is not a moment. ------------
# ONE FIELD WRONG PER FIXTURE. The first version of this arm asked the clock for
# `2026-99-99T99:99:99Z` -- out of range in the month, the day, the hour, the
# minute and the second simultaneously -- so any ONE of the five checks refused
# it and the other four were pinned by nothing. Built and run in round 6
# micro-review 5: a hook that validates the month and nothing else passes this
# case, and would store hour 24 and day 32 into a record the reconciler reads.
# Five fixtures, each valid everywhere except the field it names, plus BOTH
# boundary values that must be ACCEPTED -- a leap second, which is a real
# reading, and the calendar floor -- so tightening a bound goes red too.
dq_range_arm() { # $1=label  $2=the clock's answer  $3=refused|stored  $4=script (default: the hook)
  DQRHO="$(NEWHO dq-c-$1)"; DQRREC="$DQRHO.dispatch"
  live_json "running"; GOF "$DQRHO" "dq-c-$1" >/dev/null 2>&1
  dq_run "${4:-$SCRIPT}" "$DQRREC" C "$2"
  assert_contains "EXPIRED" "$DQ_OUT" DQ
  if [ "$3" = refused ]; then
    assert_rec "$DQRREC" "monitoring_expired=clock-unavailable" DQ
    assert_rec_missing "$DQRREC" "monitoring_expired=$2" DQ
  else
    assert_rec "$DQRREC" "monitoring_expired=$2" DQ
    assert_rec_missing "$DQRREC" "monitoring_expired=clock-unavailable" DQ
  fi
}
dq_range_arm month  2026-13-15T12:30:45Z refused
dq_range_arm day    2026-07-32T12:30:45Z refused
dq_range_arm hour   2026-07-15T24:30:45Z refused
dq_range_arm minute 2026-07-15T12:60:45Z refused
dq_range_arm second 2026-07-15T12:30:61Z refused
# The other side of every bound. These also make the whole arm falsifiable in
# the direction the refusals cannot: if the shim ever stopped reaching the hook,
# the record would carry the real clock's time and both of these go red, where
# every `clock-unavailable` assertion above would still pass for the wrong
# reason (round-4 test finding T2's class -- a control that cannot fail).
dq_range_arm leap  2026-06-30T23:59:60Z stored
dq_range_arm floor 2026-01-01T00:00:00Z stored

# Its control: make the range test always true and every fixture above is stored
# as a timestamp. The status and shape checks are LEFT IN, so this control can
# only go red on the arm it names -- which is why the range arm lives in its own
# one-line function. It is run against ALL FIVE refusals, because a fixture that
# was refused somewhere EARLIER in the pipeline would look exactly like coverage
# here; on this mutant each one has to come out the other end.
DQMUT3="$tmp/handoff-dq-norange.sh"
sed 's|^_nu_in_range() { # |_nu_in_range() { return 0; # |' "$SCRIPT" > "$DQMUT3"
if cmp -s "$SCRIPT" "$DQMUT3"; then
  echo "FAIL[DQ]: the any-range mutant is identical to the hook -- now_utc's range check moved, and this control cannot fail"; fail=1
else
  dq_range_arm month-mut  2026-13-15T12:30:45Z stored "$DQMUT3"
  dq_range_arm day-mut    2026-07-32T12:30:45Z stored "$DQMUT3"
  dq_range_arm hour-mut   2026-07-15T24:30:45Z stored "$DQMUT3"
  dq_range_arm minute-mut 2026-07-15T12:60:45Z stored "$DQMUT3"
  dq_range_arm second-mut 2026-07-15T12:30:61Z stored "$DQMUT3"
fi
rm -f "$DQMUT3"

# AND THE FIELD COUNT ITSELF, from the hook. The five fixtures cover one field
# each, which is only coverage while there are five fields to cover: a sixth
# conjunct added later would be pinned by nothing, and nothing else in this file
# says how many there are or what they bound. Extracted, never retyped -- the
# bounds below are the hook's own text.
DQ_CONJ="$(grep -o '_nu_in_range "..NOW_UTC:[0-9]*:2." [0-9]* [0-9]*' "$SCRIPT")"
DQ_CONJ_WANT="$(cat <<'DQC'
_nu_in_range "${NOW_UTC:5:2}" 1 12
_nu_in_range "${NOW_UTC:8:2}" 1 31
_nu_in_range "${NOW_UTC:11:2}" 0 23
_nu_in_range "${NOW_UTC:14:2}" 0 59
_nu_in_range "${NOW_UTC:17:2}" 0 60
DQC
)"
assert_eq "$DQ_CONJ" "$DQ_CONJ_WANT" DQ

# ---- DR. no message asserts a cause nobody observed -------------------------
# `fs_get` collapses every failure into 2 and publishes what it saw in
# `FS_WHY_TXT`; `fs_novalue_set` does the same for the other degraded shape, a
# probe that returns SUCCESS and prints nothing. A message that spells a cause
# itself is asserting one it did not observe. THIS CLASS HAS NOW SURVIVED THREE
# MICRO-REVIEWS, and twice the fix was the next round's defect: micro-review 2
# converted eleven messages that all said "timed out"; micro-review 3 found
# three more hardcoding "(the filesystem did not answer)" and replaced them with
# "`stat` refused" and "could not open the lease file"; micro-review 4
# REPRODUCED BOTH OF THOSE BEING FALSE (a `stat` exiting 0 with unparseable
# output, and a lock backend refusing after the open had already succeeded).
# Hunting instances is what kept producing instances, so this case censuses the
# SHAPE: the forbidden vocabulary, and -- the half that actually closes it --
# the rule that no human-facing reason is written by hand at a site at all.
DR_PAT='the filesystem did not answer\|did not answer within\|timed out after\|refused rather than\|could not open the lease file'
DR_FILTER='^[0-9][0-9]*:[[:blank:]]*#'
dr_census() { grep -n "$DR_PAT" "$1" | grep -v "$DR_FILTER" || true; }

# (a) THE PHRASE CENSUS.
DR_HITS="$(dr_census "$SCRIPT")"
[ -z "$DR_HITS" ] || { echo "FAIL[DR]: a human-facing message spells a cause instead of reporting the one that was observed -- interpolate \$FS_WHY_TXT for a failed read, or \$FS_NOVALUE_TXT for a probe that answered with nothing:"; printf '%s\n' "$DR_HITS"; fail=1; }

# (b) THE CENSUS CAN SEE PRESENCE, AND ITS COMMENT FILTER DOES NOT SWALLOW CODE.
# Both halves used to be proved by something OTHER than the census itself: the
# presence probe was a `grep -c` for a different phrase (so it proved that some
# grep could match something, never that THIS pipeline could), and the filter
# control retyped an UNNUMBERED line though the real filter only ever sees
# `grep -n` output, and never tried a TAB-indented comment -- which the old
# `[ ]*` filter would have let through as code (round 6 micro-review 4). One
# fixture now drives the real `dr_census` and covers all three.
DRPROBE="$tmp/dr-probe.txt"
{ printf '  alert_once "$r" k "x (the filesystem did not answer) y"\n'
  printf '  # the filesystem did not answer, in a space-indented comment\n'
  printf '\t# the filesystem did not answer, in a tab-indented comment\n'
  printf '  ok_line "a line with none of the vocabulary"\n'; } > "$DRPROBE"
DR_PROBE_OUT="$(dr_census "$DRPROBE")"
assert_eq "$(printf '%s' "$DR_PROBE_OUT" | grep -c . | tr -d ' ')" "1" DR
case "$DR_PROBE_OUT" in
  1:*alert_once*) ;;
  *) echo "FAIL[DR]: the census did not name the one line of CODE in its own fixture, so its clean sweep of the hook is vacuous -- got: $DR_PROBE_OUT"; fail=1 ;;
esac

# (c) THE ASSIGNMENT CENSUS -- the half that makes (a) unnecessary going forward.
# Every variable whose value reaches an operator as the REASON for a degraded
# observation may only be assigned from a constructor, from a sibling reason, or
# cleared. A sentence typed at a site is the defect itself, whatever words it
# uses, and no phrase list can anticipate the next one.
#   THE POPULATION IS A NAMING CONVENTION, NOT A LIST OF SPELLINGS. It was a list
# of five variable names, which meant a sixth reason variable was invisible to
# the census that exists to find it, and the count it checked (13, "or more")
# had already drifted from the 16 the extraction really returned -- a denominator
# that cannot go red is not a denominator (round 6 micro-review 5). Every reason
# variable in this script ends in `why`, so that is what is matched, and the SET
# OF NAMES is asserted below: a new one has to be reviewed into this list rather
# than silently join the population, and a renamed one cannot leave it quietly.
# ONE definition, used for the hook AND for the mutants below. It was written
# twice and the two copies had already drifted -- the control kept the loose
# filter after the real one was tightened, so it went green on a mutant the
# census would have caught and red on the site it was pointed at (round 6
# micro-review 4, reproduced in the run that added the second mutation).
dr_reason_lines() { grep -n '^[^#]*[A-Za-z0-9_]*[Ww][Hh][Yy]=' "$1" || true; }
dr_reason_vals()  { grep -v '^[[:blank:]]*#' "$1" | grep -o '[A-Za-z0-9_]*[Ww][Hh][Yy]="[^"]*"' || true; }
# The three MECHANICAL forms, exempt because none of them can carry a sentence:
# cleared, or taken whole from one of the two constructors. Everything else is
# text a human wrote, and goes to the reviewed inventory below.
dr_reason_written() { dr_reason_vals "$1" | grep -v '=""$' | grep -v '="\$FS_WHY_TXT"$' | grep -v '="\$FS_NOVALUE_TXT"$' || true; }

DR_REASON_N="$(dr_reason_lines "$SCRIPT" | grep -c . | tr -d ' ')"
# A DENOMINATOR, and an EXACT one. `-ge 13` accepted the population growing,
# shrinking to 13, or being replaced wholesale; the point of a denominator is
# that a census which stops finding its sites reads as broken rather than clean.
# 21, not 19: retire_self's failure path reads FS_WHY_TXT into `_rt_why` and
# falls back to a sentence of its own, which is two more lines matching the
# convention. Reading it into a local is deliberate -- an inline
# `${FS_WHY_TXT:-...}` would have been counted a WRITE by the constructor census
# below (which cannot tell `:-` from `:=`), and that exemption row would then
# swallow a real default-assignment added to the same function later.
assert_eq "$DR_REASON_N" "21" DR
# LC_ALL=C, because the ORDER is part of the assertion and `sort` takes its
# collation from the environment: on this machine the ambient locale files the
# underscore names before the capitals and the C locale files them after, so
# without it the case is red or green depending on who runs it (caught in the
# first run of this rewrite).
DR_REASON_NAMES="$(dr_reason_vals "$SCRIPT" | sed 's/=.*//' | LC_ALL=C sort -u)"
DR_REASON_NAMES_WANT="$(cat <<'DRN'
FS_WHY
WATCH_UNKNOWN_WHY
_ino0why
_ino1why
_inowhy
_nlwhy
_rt_why
DRN
)"
assert_eq "$DR_REASON_NAMES" "$DR_REASON_NAMES_WANT" DR

# THE REVIEWED INVENTORY. Eight strings, and every one of them was read against
# the site that sets it and the observation that reaches it. This is deliberately
# a list of VALUES and not a filter: the filter form ("a reason may contain
# $FS_WHY_TXT") exempted `WATCH_UNKNOWN_WHY="the lock backend crashed:
# $FS_NOVALUE_TXT"`, which names a cause nobody watched and interpolates the
# constructor beside it -- reproduced against this census, which returned zero
# hits (round 6 micro-review 5). A frame that says WHAT WAS ATTEMPTED is fine and
# is what these are; a frame that says WHY IT FAILED is the defect, and no
# pattern can tell those apart, so they are enumerated and read by a human.
#   `FS_WHY="$1"` is in the list because the convention sweeps it in, and it is
# not prose at all: it is the constructor's own machine tag (killed|refused|
# error), the input `fs_why_set` turns INTO the sentence.
#   `_rt_why="the write did not report success"` is the eighth, added with the
# retirement work. It is reached only when the terminal-state write came back
# with something other than `ok` AND the constructor published no sentence, and
# it says exactly that and nothing else -- no mechanism, no guess at which of the
# write's steps was the one that did not happen.
DR_WRITTEN="$(dr_reason_written "$SCRIPT" | LC_ALL=C sort)"
DR_WRITTEN_WANT="$(cat <<'DRW' | LC_ALL=C sort
FS_WHY="$1"
WATCH_UNKNOWN_WHY="the record could not be read: $FS_WHY_TXT"
WATCH_UNKNOWN_WHY="the watchdog's lease could not be probed: $FS_WHY_TXT"
WATCH_UNKNOWN_WHY="the lease probe reported neither held nor free: $FS_NOVALUE_TXT"
_inowhy="neither identity read succeeded — the first: $_ino0why; the second: $_ino1why"
_inowhy="the identity read taken when the file was validated did not produce one: $_ino0why"
_inowhy="the identity read taken here at the dispatch boundary did not produce one: $_ino1why"
_rt_why="the write did not report success"
DRW
)"
if [ "$DR_WRITTEN" != "$DR_WRITTEN_WANT" ]; then
  echo "FAIL[DR]: the hand-written half of the degraded-reason vocabulary changed. Every line below is text an operator reads as the REASON a value is missing, so it is a review decision, not an edit: check that it names only what was OBSERVED (what was attempted), never why it failed, then update this inventory."
  diff <(printf '%s\n' "$DR_WRITTEN_WANT") <(printf '%s\n' "$DR_WRITTEN") || true
  fail=1
fi

# (d) The control for the phrase census: put the phrase back at the watchunknown
# site and the census names it. This is the site micro-review 3 reproduced --
# `watch_is_alive` sets WATCH_UNKNOWN on three paths and on one of them the probe
# answered instantly and successfully.
DRMUT="$tmp/handoff-dr-hardcoded.sh"
sed 's|alive ($WATCH_UNKNOWN_WHY)|alive (the filesystem did not answer)|' "$SCRIPT" > "$DRMUT"
if cmp -s "$SCRIPT" "$DRMUT"; then
  echo "FAIL[DR]: the hardcoded-cause mutant is identical to the hook -- the watchunknown alert's reason moved, and this control cannot fail"; fail=1
else
  case "$(dr_census "$DRMUT")" in
    *watchunknown*) ;;
    *) echo "FAIL[DR]: the census did not name the reverted watchunknown alert, so it is not what makes the sweep above mean anything"; fail=1 ;;
  esac
fi
rm -f "$DRMUT"

# (e) The control for the assignment census, which has to fail on a sentence the
# phrase list has never seen -- that is the whole point of having it.
DRMUT2="$tmp/handoff-dr-handwritten.sh"
# THREE sites, and each is a shape the previous version of this census let
# through. The second is one of the identity reasons -- the names the old filter
# exempted as sources, so writes TO them were exempt too. The third is the one
# micro-review 5 reproduced: a cause nobody observed, typed in FRONT of a
# constructor it interpolates, which every "does the line mention FS_WHY_TXT"
# filter accepts by construction.
sed -e 's|else fs_novalue_set "link-count probe on $FILE_ABS"; _nlwhy="$FS_NOVALUE_TXT"; fi|else _nlwhy="the disk was busy elsewhere"; fi|' \
    -e 's|_ino0why="$FS_WHY_TXT"|_ino0why="the mount went away"|' \
    -e 's|the lease probe reported neither held nor free: $FS_NOVALUE_TXT|the lock backend crashed: $FS_NOVALUE_TXT|' "$SCRIPT" > "$DRMUT2"
if cmp -s "$SCRIPT" "$DRMUT2"; then
  echo "FAIL[DR]: the hand-written-reason mutant is identical to the hook -- the hard-link guard's reason moved, and this control cannot fail"; fail=1
else
  DR_MUT2_BAD="$(dr_reason_written "$DRMUT2")"
  case "$DR_MUT2_BAD" in
    *"the disk was busy elsewhere"*) ;;
    *) echo "FAIL[DR]: the assignment census did not name a reason typed at its site, so it cannot catch the next sentence either -- got: $DR_MUT2_BAD"; fail=1 ;;
  esac
  case "$DR_MUT2_BAD" in
    *"the mount went away"*) ;;
    *) echo "FAIL[DR]: the assignment census did not name a reason typed at an IDENTITY site, so its exemption for those names is swallowing writes to them -- got: $DR_MUT2_BAD"; fail=1 ;;
  esac
  case "$DR_MUT2_BAD" in
    *"the lock backend crashed"*) ;;
    *) echo "FAIL[DR]: the assignment census did not name a cause typed IN FRONT of a constructor it interpolates, which is the shape a contains-the-constructor filter can never see -- got: $DR_MUT2_BAD"; fail=1 ;;
  esac
  # AND the phrase census does NOT catch it, which is why (c) exists.
  case "$(dr_census "$DRMUT2")" in
    "") ;;
    *) echo "FAIL[DR]: the phrase census caught the hand-written mutant, so this control does not show what the assignment census adds"; fail=1 ;;
  esac
fi
rm -f "$DRMUT2"

# (f) The control for the POPULATION, which the census's own definition decides:
# a reason variable that follows the convention but is not in the reviewed name
# set must stop the suite, because that is the only moment a human looks at what
# the new site says. A list of five spellings had no such moment.
DRMUT3="$tmp/handoff-dr-newname.sh"
sed 's|_nlwhy="$FS_WHY_TXT"|_nlwhy="$FS_WHY_TXT"; _lockwhy="the backend gave up"|' "$SCRIPT" > "$DRMUT3"
if cmp -s "$SCRIPT" "$DRMUT3"; then
  echo "FAIL[DR]: the new-reason-variable mutant is identical to the hook -- the hard-link guard's reason moved, and this control cannot fail"; fail=1
else
  case "$(dr_reason_vals "$DRMUT3" | sed 's/=.*//' | LC_ALL=C sort -u)" in
    *_lockwhy*) ;;
    *) echo "FAIL[DR]: a new reason variable did not enter the population, so the census covers only the names someone remembered to list"; fail=1 ;;
  esac
  case "$(dr_reason_written "$DRMUT3")" in
    *"the backend gave up"*) ;;
    *) echo "FAIL[DR]: a sentence at a new reason variable was not reported as hand-written, so a sixth name would carry any text at all"; fail=1 ;;
  esac
fi
rm -f "$DRMUT3"

# (g) THE COUNT IN THE DOC IS THE COUNT IN THE HOOK. `docs/handoff-successor.md`
# tells the reader how many sites interpolate `$FS_WHY_TXT`, as evidence that
# the constructor is the whole vocabulary and not one message's helper. It said
# "Ten" while the hook had sixteen (round 6 micro-review 5) -- the second count
# in that document to go stale while reading as evidence, so this one is
# derived, and the number is read OUT OF THE DOC rather than supplied here.
DR_DOCFILE="$(cd "$(dirname "$0")/.." && pwd)/docs/handoff-successor.md"
dr_doc_n() { sed -n 's/^  \([0-9][0-9]*\) sites interpolate it,.*/\1/p' "$1"; }
if [ ! -r "$DR_DOCFILE" ]; then
  echo "FAIL[DR]: $DR_DOCFILE is not readable, so the doc-count assertion below would pass by not running"; fail=1
else
  DR_DOC_N="$(dr_doc_n "$DR_DOCFILE")"
  DR_HOOK_N="$(grep -v '^[[:blank:]]*#' "$SCRIPT" | grep -c '\$FS_WHY_TXT' | tr -d ' ')"
  [ -n "$DR_DOC_N" ] || { echo "FAIL[DR]: the sentence this case reads the count out of is gone from $DR_DOCFILE, so the comparison below has nothing to compare"; fail=1; }
  assert_eq "$DR_DOC_N" "$DR_HOOK_N" DR
  # ITS CONTROL, which this case did not have when it was written: an assertion
  # that two numbers agree proves nothing until a run where they DISAGREE has
  # been shown to fail. The scorecard claimed this control existed one micro-
  # review before it did (round 6 micro-review 6), which is the same overstated-
  # evidence class the rest of this round has been correcting.
  DR_DOCMUT="$tmp/handoff-doccount.md"
  sed "s/^  $DR_DOC_N sites interpolate it,/  $(( DR_DOC_N + 83 )) sites interpolate it,/" "$DR_DOCFILE" > "$DR_DOCMUT"
  if cmp -s "$DR_DOCFILE" "$DR_DOCMUT"; then
    echo "FAIL[DR]: the doctored-count control is identical to the doc -- the sentence moved, and this control cannot fail"; fail=1
  elif [ "$(dr_doc_n "$DR_DOCMUT")" = "$DR_HOOK_N" ]; then
    echo "FAIL[DR]: a doc claiming $(( DR_DOC_N + 83 )) sites still compared equal to the hook's $DR_HOOK_N, so the comparison above is not reading the doc"; fail=1
  fi
  rm -f "$DR_DOCMUT"
fi

# (h) THE CONSTRUCTOR OUTPUTS ARE REASON VARIABLES TOO. The assignment census
# above matches names ending in `why`; `FS_WHY_TXT` and `FS_NOVALUE_TXT` do not,
# so a hand-written cause written STRAIGHT INTO one of them reaches the operator
# through every `_xwhy="$FS_WHY_TXT"` copy the census exempts, while every one of
# its operands stays identical -- 19 reason lines, the same names, the same
# inventory (round 6 micro-review 6, reproduced by inserting
# `FS_WHY_TXT="the mount went away"` before the identity guard: DR passed).
#   The invariant is one line: ONLY THE TWO CONSTRUCTORS MAY PUT TEXT IN THEM,
# and anywhere else may only clear them. It is asserted as a census of sites by
# enclosing function rather than as an inventory of sentences, so rewording a
# message is an edit while moving where a message is BUILT is a review decision.
#   THE POPULATION IS EVERY MENTION, NOT EVERY `NAME=`. The first version of this
# census matched `/FS_(WHY|NOVALUE)_TXT=/`, which is one WRITE SYNTAX out of
# several: `printf -v FS_WHY_TXT %s "the mount went away"` is a valid write with
# no `=` after the name, and it reached the operator on a `die` arm while this
# census, the assignment census above, DU, DW and the interpolation count all
# stayed byte-for-byte identical (round 6 micro-review 7, reproduced with exactly
# that mutant at watch_once). Enumerating write syntaxes is unbounded; enumerating
# MENTIONS is not. But a census of LINES is not a census of writes: micro-review 8
# put a SECOND write on a line the inventory had already approved
# (`...apart"; printf -v FS_WHY_TXT %s "the mount went away" ;;`) and the line
# count did not move, so the invented cause rode in under an approved row. The
# census therefore counts WRITES, not lines: every mention of either name minus
# the mentions that are pure `$NAME` / `${NAME}` reads. That subtraction is also
# what makes `${FS_WHY_TXT:=a cause nobody observed}` visible -- the old stripper
# had an OPTIONAL closing brace, so it ate `${FS_WHY_TXT` and read a default-value
# ASSIGNMENT as a read.
dr_out_sites() { # $1=script -> "<writes> <enclosing function>|clear|text|other"
  awk '
    /^[A-Za-z_][A-Za-z0-9_]*\(\)[[:blank:]]*\{/ { fn=$0; sub(/\(\).*/,"",fn); next }
    /^\}/ { fn=""; next }
    /^[[:blank:]]*#/ { next }
    /FS_WHY_TXT|FS_NOVALUE_TXT/ {
      t=$0; nall  = gsub(/FS_WHY_TXT|FS_NOVALUE_TXT/, "X", t)
      u=$0; nread = gsub(/\$(FS_WHY_TXT|FS_NOVALUE_TXT)|\$\{(FS_WHY_TXT|FS_NOVALUE_TXT)\}/, "X", u)
      nw = nall - nread
      if (nw <= 0) next                                     # every mention was a read
      kind = ($0 ~ /FS_(WHY|NOVALUE)_TXT=""/) ? "clear" \
           : ($0 ~ /FS_(WHY|NOVALUE)_TXT=/)   ? "text" : "other"
      for (i = 0; i < nw; i++) print (fn=="" ? "<toplevel>" : fn) "|" kind
    }
  ' "$1" | LC_ALL=C sort | uniq -c | awk '{printf "%s %s\n",$1,$2}'
}
DR_OUT_WANT="$tmp/dr-out-want.txt"
cat > "$DR_OUT_WANT" <<'DROUT'
2 <toplevel>|clear
1 fs_get|clear
1 fs_novalue_set|text
3 fs_why_set|text
DROUT
DR_OUT_GOT="$tmp/dr-out-got.txt"
dr_out_sites "$SCRIPT" > "$DR_OUT_GOT"
if ! cmp -s "$DR_OUT_WANT" "$DR_OUT_GOT"; then
  echo "FAIL[DR]: the sites that write the degraded-reason constructors changed -- only fs_why_set and fs_novalue_set may write TEXT into them, everywhere else may only clear them. It is a review decision, not an edit:"
  diff "$DR_OUT_WANT" "$DR_OUT_GOT" | sed 's/^/    /'
  fail=1
fi
# Its control: the reproduction itself, as a whole-file mutant.
DRMUT4="$tmp/handoff-dr-outvar.sh"
awk '/_ino0why="\$FS_WHY_TXT"/ && !done { print "  FS_WHY_TXT=\"the mount went away\""; done=1 } {print}' "$SCRIPT" > "$DRMUT4"
if cmp -s "$SCRIPT" "$DRMUT4"; then
  echo "FAIL[DR]: the constructor-output mutant is identical to the hook -- the identity guard's reason read moved, and this control cannot fail"; fail=1
elif ! bash -n "$DRMUT4" 2>/dev/null; then
  echo "FAIL[DR]: the constructor-output mutant does not parse, so it proves nothing about the census above"; fail=1
else
  case "$(dr_out_sites "$DRMUT4")" in
    *"dispatch|text"*) ;;
    *) echo "FAIL[DR]: a sentence written straight into FS_WHY_TXT outside the constructors was not reported, so the census above cannot see the shape it exists for -- got: $(dr_out_sites "$DRMUT4" | tr '\n' ' ')"; fail=1 ;;
  esac
fi
# Its SECOND control, and the one that falsified the census's first shape: a
# write with no `=` after the name. It must be reported, and reported as `other`
# rather than swallowed by the read branch.
DRMUT5="$tmp/handoff-dr-printfv.sh"
sed 's|^  fs_get "\$FS_TIMEOUT_SEC" file_readable "\$REC" \|\| die |  fs_get "$FS_TIMEOUT_SEC" file_readable "$REC" \|\| { printf -v FS_WHY_TXT %s "the mount went away"; die |' "$SCRIPT" \
  | sed 's|refusing to watch on an observation that was never made"$|refusing to watch on an observation that was never made"; }|' > "$DRMUT5"
if cmp -s "$SCRIPT" "$DRMUT5"; then
  echo "FAIL[DR]: the printf -v mutant is identical to the hook -- watch_once's readability guard moved, and this control cannot fail"; fail=1
elif ! bash -n "$DRMUT5" 2>/dev/null; then
  echo "FAIL[DR]: the printf -v mutant does not parse, so it proves nothing about the census above"; fail=1
else
  case "$(dr_out_sites "$DRMUT5")" in
    *"watch_once|other"*) ;;
    *) echo "FAIL[DR]: a write with no '=' after the name was not reported, so the census above still enumerates one write SYNTAX rather than every mention -- got: $(dr_out_sites "$DRMUT5" | tr '\n' ' ')"; fail=1 ;;
  esac
fi
rm -f "$DRMUT5"
# Its THIRD control, and the one that falsified the census's second shape: a
# SECOND write on a line the inventory has already approved. A per-LINE census
# reports the same row and the same count, so the invented cause rides in under
# an approved row; a per-WRITE census reports one more write in fs_why_set.
DRMUT6="$tmp/handoff-dr-secondwrite.sh"
sed 's|and nothing here can tell those apart" ;;|and nothing here can tell those apart"; printf -v FS_WHY_TXT %s "the mount went away" ;;|' "$SCRIPT" > "$DRMUT6"
if cmp -s "$SCRIPT" "$DRMUT6"; then
  echo "FAIL[DR]: the second-write mutant is identical to the hook -- the killed constructor's text moved, and this control cannot fail"; fail=1
elif ! bash -n "$DRMUT6" 2>/dev/null; then
  echo "FAIL[DR]: the second-write mutant does not parse, so it proves nothing about the census above"; fail=1
else
  case "$(dr_out_sites "$DRMUT6")" in
    *"4 fs_why_set|text"*) ;;
    *) echo "FAIL[DR]: a SECOND write added to an already-inventoried line did not move the count, so this census counts lines rather than writes -- got: $(dr_out_sites "$DRMUT6" | tr '\n' ' ')"; fail=1 ;;
  esac
fi
rm -f "$DRMUT6"
# Its FOURTH control: a write spelled as a default-value expansion. `${NAME:=x}`
# ASSIGNS, and the old stripper's optional closing brace ate `${FS_WHY_TXT` and
# classified the line as a read.
DRMUT7="$tmp/handoff-dr-defaultassign.sh"
{ cat "$SCRIPT"; printf 'fs_sneak() {\n  : "${FS_WHY_TXT:=a cause nobody observed}"\n  printf 1\n}\n'; } > "$DRMUT7"
if ! bash -n "$DRMUT7" 2>/dev/null; then
  echo "FAIL[DR]: the default-assignment mutant does not parse, so it proves nothing about the census above"; fail=1
else
  case "$(dr_out_sites "$DRMUT7")" in
    *"fs_sneak|other"*) ;;
    *) echo "FAIL[DR]: a write spelled '\${NAME:=...}' was read as a READ, so the stripper still swallows an assignment -- got: $(dr_out_sites "$DRMUT7" | tr '\n' ' ')"; fail=1 ;;
  esac
fi
rm -f "$DRMUT7"
rm -f "$DRMUT4" "$DR_OUT_WANT" "$DR_OUT_GOT"

# ---- DS. a record that cannot be READ never becomes a record that says nothing
# `rec_get_raw` was `sed ... | tail -1`, and a pipeline's status is its LAST
# command's: `tail` succeeds whatever happened at the other end of the pipe, so
# the function returned 0 for a record this process may not read. `rec_read`
# documents a tri-state -- "0 = observed (may be empty), 2 = not" -- and its 2
# was therefore UNREACHABLE at the only place that can produce it (round 6
# micro-review 4). Three guards branch on that return and every one of them
# names this exact harm in its own comment before suffering it: `watch_is_alive`
# ("an unreadable record is not 'no watcher': concluding that arms a second
# one"), `watch_once` ("collapsing them made a hung mount announce 'no session
# id'"), and the dispatch's own pre-flight ("a record that cannot be read cannot
# rule out a live successor").
#
# The fixture is the dispatch pre-flight, because that is where the cost is
# money: a record naming a LIVE successor, mode 222 -- writable, unreadable --
# which is the shape that lets the run continue all the way to the launch
# instead of failing later on the write. Reproduced on the unfixed hook: it
# launched a second successor AND overwrote the live one's row.
DSHO="$(NEWHO ds)"; DSREC="$DSHO.dispatch"
printf 'session_id=live-successor\nstate=launched\n' > "$DSREC"
chmod 222 "$DSREC"
# THE FIXTURE'S OWN PRECONDITION: running as root, or on a filesystem that does
# not enforce the mode, makes the record readable and this case would then pass
# for a reason that has nothing to do with the code.
if [ -r "$DSREC" ]; then
  chmod 700 "$DSREC"
  echo "FAIL[DS]: the mode-222 dispatch record is still readable (running as root?) -- this case cannot observe what it claims to"; fail=1
else
  # The shim CREATES this file on its first spawn, so a run in which no case
  # before DS has launched anything (a solo run of this case) would otherwise
  # read a missing file and compare against an empty string. The baseline is
  # taken here rather than inherited, so nothing about this case depends on the
  # order the cases run in -- and it is taken BEFORE the fixed hook runs, which
  # is the half that was wrong: taken after, a regression that spawned on the
  # refusal path was absorbed into the baseline and the control still passed on
  # the mutant's own spawn (round 6 micro-review 5).
  [ -f "$SHIM_SPAWNS" ] || : > "$SHIM_SPAWNS"
  DS_SP0="$(wc -l < "$SHIM_SPAWNS" | tr -d ' ')"
  DS_OUT="$(GOF "$DSHO" "ds" 2>&1)"; ds_rc=$?
  chmod 700 "$DSREC"
  # 2 is `die`'s status (`hooks/handoff.sh` line 89), i.e. "refused"; 0 is
  # "dispatched". This assertion was first written as 1 from memory and the solo
  # run caught it -- an exit code is the weakest thing this case checks, which is
  # why the message and the record's own contents are checked below it.
  assert_eq "$ds_rc" "2" DS
  assert_contains "cannot read the existing dispatch record" "$DS_OUT" DS
  # The refusal quotes what fs_get observed, not a cause it invented.
  assert_contains "I could not look" "$DS_OUT" DS
  # AND THE LIVE SUCCESSOR'S ROW IS STILL THERE. Asserting only the message
  # would leave "it refused, then wrote anyway" green.
  assert_rec "$DSREC" "session_id=live-successor" DS
  assert_rec_missing "$DSREC" "session_id=$SHORT" DS
  # NOTHING WAS LAUNCHED. The refusal is only worth having if it happens before
  # the money is spent, and every other assertion in this case is satisfied by a
  # hook that spawns a successor and then refuses: same status, same message,
  # same untouched record. Control (2) below is that hook.
  DS_SPFIX="$(wc -l < "$SHIM_SPAWNS" | tr -d ' ')"
  assert_eq "$DS_SPFIX" "$DS_SP0" DS
  # Control (1): restore the masking pipeline and the same fixture pays for a
  # second successor. This is the hook as it stood at the head of this round.
  DSMUT="$tmp/handoff-ds-masked.sh"
  awk '
    /^rec_get_raw\(\) \{$/ { print "rec_get_raw() { sed -n \"s/^$2=//p\" \"$1\" 2>/dev/null | tail -1; }   # CLAIM:a"; skip=1; next }
    skip && /^\}$/ { skip=0; next }
    skip { next }
    { print }
  ' "$SCRIPT" > "$DSMUT"
  if cmp -s "$SCRIPT" "$DSMUT"; then
    echo "FAIL[DS]: the masked-status mutant is identical to the hook -- rec_get_raw moved, and this control cannot fail"; fail=1
  elif ! bash -n "$DSMUT" 2>/dev/null; then
    echo "FAIL[DS]: the masked-status mutant does not parse, so it proves nothing about the fixed hook"; fail=1
  else
    DSHO2="$(NEWHO ds-mut)"; DSREC2="$DSHO2.dispatch"
    printf 'session_id=live-successor\nstate=launched\n' > "$DSREC2"
    chmod 222 "$DSREC2"
    DS_OUT2="$(bash "$DSMUT" "$DSHO2" "ds-mut" --cwd "$tmp/work" 2>&1)"
    chmod 700 "$DSREC2"
    assert_missing "cannot read the existing dispatch record" "$DS_OUT2" DS
    # It launched: the record now names the shim's session instead of the live one.
    assert_rec "$DSREC2" "session_id=$SHORT" DS
    assert_rec_missing "$DSREC2" "session_id=live-successor" DS
    DS_SP1="$(wc -l < "$SHIM_SPAWNS" | tr -d ' ')"
    [ "$DS_SP1" -gt "$DS_SPFIX" ] || { echo "FAIL[DS]: the masked-status mutant did not spawn, so this control does not show the cost the fix prevents ($DS_SPFIX -> $DS_SP1)"; fail=1; }
  fi
  rm -f "$DSMUT"

  # Control (2), for the no-spawn assertion itself: a hook that launches BEFORE
  # it reads the record it is checking. This is the reordering a later edit
  # produces by accident, and it is invisible to everything else here -- it
  # refuses with the same words, exits 2, and leaves the live successor's row
  # alone, because the launch happens on the way to the same `die`.
  DSMUT2="$tmp/handoff-ds-spawn-first.sh"
  awk '{print} index($0,"_recread_a=\"cannot read the existing dispatch record")>0 {print "    \"$CLAUDE_BIN\" --bg spawned-before-the-read >/dev/null 2>&1 || true   # INJECTED: the successor is paid for before the record is read"}' \
    "$SCRIPT" > "$DSMUT2"
  assert_eq "$(grep -c 'INJECTED' "$DSMUT2" | tr -d ' ')" "1" DS   # ANCHOR: exactly one site
  if ! bash -n "$DSMUT2" 2>/dev/null; then
    echo "FAIL[DS]: the spawn-first mutant does not parse, so it proves nothing about the fixed hook"; fail=1
  else
    DSHO3="$(NEWHO ds-spawn)"; DSREC3="$DSHO3.dispatch"
    printf 'session_id=live-successor\nstate=launched\n' > "$DSREC3"
    chmod 222 "$DSREC3"
    DS_SP2="$(wc -l < "$SHIM_SPAWNS" | tr -d ' ')"
    DS_OUT3="$(bash "$DSMUT2" "$DSHO3" "ds-spawn" --cwd "$tmp/work" 2>&1)"; ds_rc3=$?
    chmod 700 "$DSREC3"
    DS_SP3="$(wc -l < "$SHIM_SPAWNS" | tr -d ' ')"
    # Everything the case checked before this round is UNCHANGED on the mutant...
    assert_eq "$ds_rc3" "2" DS
    assert_contains "cannot read the existing dispatch record" "$DS_OUT3" DS
    assert_rec "$DSREC3" "session_id=live-successor" DS
    assert_rec_missing "$DSREC3" "session_id=$SHORT" DS
    # ...and a successor was still paid for, which is what the assertion above
    # is the only thing to see.
    [ "$DS_SP3" -gt "$DS_SP2" ] || { echo "FAIL[DS]: the spawn-first mutant did not spawn, so the no-spawn assertion on the fixed hook is a control that cannot fail ($DS_SP2 -> $DS_SP3)"; fail=1; }
  fi
  rm -f "$DSMUT2"
fi

# ---- DT. the fence refuses without naming a cause it did not observe --------
# `verify_lock` re-takes the dispatch lock, and until round 6 micro-review 5 it
# reported EVERY non-zero from `lock_take` as "the dispatch lock's descriptor is
# no longer open". `lock_take` answers 1 for EWOULDBLOCK and 3 for every other
# way the question could not be answered -- only ONE of which is a closed
# descriptor: a mount that cannot lock at all, an fd the backend does not
# handle, a backend that refuses, perl failing to start. Reproduced with the
# debug seam against an fd 9 that was demonstrably still open: the refusal was
# right and its reason was invented. That is this branch's class -- a degraded
# observation may not name a cause it did not observe -- at a site NO census
# covers, because it lives in a `die` string and not in a reason variable.
#   AG owns the other direction, a descriptor that really is gone. This case is
# its opposite: fd 9 stays open and the BACKEND is what cannot answer. The seam
# cannot be set from outside, because `claim_lock` would then refuse before the
# fence is ever reached -- a different refusal at a different line, which is
# round-6's "a window the case never enters" -- so it is injected at the anchor
# AG uses, one line after the lock has been acquired.
DTCOPY="$tmp/deadbackend.sh"
awk '{print} index($0,"DISPATCH_LOCK=\"$1\"")>0 {print "  CLAUDE_HANDOFF_LOCK_DEBUG=broken:9; export CLAUDE_HANDOFF_LOCK_DEBUG   # INJECTED: the backend stops answering AFTER the lock is held"}' \
  "$SCRIPT" > "$DTCOPY"
chmod +x "$DTCOPY"
assert_eq "$(grep -c 'INJECTED' "$DTCOPY" | tr -d ' ')" "1" DT   # ANCHOR: exactly one site
DTHO="$(NEWHO dt)"
rm -f "$SHIM_SPAWNS"; live_json "running"
DT_OUT="$(bash "$DTCOPY" "$DTHO" "dt" --cwd "$tmp/work" 2>&1)"; dt_rc=$?
assert_eq "$dt_rc" "2" DT
# It still refuses: the fence fails CLOSED whichever reading is true, and no
# successor is paid for ...
assert_contains "could not be re-checked" "$DT_OUT" DT
assert_no_file "$SHIM_SPAWNS" DT
# ... and it refuses with what it WATCHED. fd 9 is open, and the message says so
# rather than announcing a descriptor this process never looked at.
assert_contains "descriptor for it is still open" "$DT_OUT" DT
assert_missing "descriptor for it is gone" "$DT_OUT" DT
# Its control: go back to inferring the cause from the status, as the hook did
# at the head of this round, and the same fixture calls an open descriptor gone.
# The exit code, the refusal and the absence of a spawn are IDENTICAL on the
# mutant -- which is exactly why nothing this case checks besides the message
# could have caught the defect.
DTMUT="$tmp/deadbackend-inferred.sh"
sed 's|^  if ( true >&9 ) 2>/dev/null; then.*|  if false; then|' "$DTCOPY" > "$DTMUT"
if cmp -s "$DTCOPY" "$DTMUT"; then
  echo "FAIL[DT]: the inferred-cause mutant is identical to the hook -- verify_lock's descriptor probe moved, and this control cannot fail"; fail=1
elif ! bash -n "$DTMUT" 2>/dev/null; then
  echo "FAIL[DT]: the inferred-cause mutant does not parse, so it proves nothing about the fixed hook"; fail=1
else
  DTHO2="$(NEWHO dt-mut)"
  rm -f "$SHIM_SPAWNS"; live_json "running"
  DT_OUT2="$(bash "$DTMUT" "$DTHO2" "dt-mut" --cwd "$tmp/work" 2>&1)"; dt_rc2=$?
  assert_eq "$dt_rc2" "2" DT
  assert_no_file "$SHIM_SPAWNS" DT
  assert_contains "descriptor for it is gone" "$DT_OUT2" DT
  assert_missing "descriptor for it is still open" "$DT_OUT2" DT
fi
rm -f "$DTMUT" "$DTCOPY"

# ---- DV. the EWOULDBLOCK arm says the backend answered, because it did ------
# DT covers status 3 -- the backend could not answer -- and until micro-review 6
# NOTHING covered status 1. That mattered, because the fix DT pins had put an
# interpretation inside the observation: `_vlfd` read "the descriptor is still
# open, so it is the lock backend that could not answer", and the status-1 `die`
# appended it to "reports as held by someone else". The operator got one
# sentence saying the backend both answered and could not answer. Reproduced end
# to end before it was fixed, with a `lock_take` returning 1 while fd 9 was open.
#   The seam cannot be an env var: `lock_take` has none for EWOULDBLOCK, and a
# real conflicting lock cannot be arranged on a descriptor this process holds --
# that is precisely the state the fence exists to declare impossible. So the
# function is overridden at the anchor AG and DT use, one line after the lock is
# acquired, which leaves every earlier stage running the real backend.
DVCOPY="$tmp/ewouldblock.sh"
awk '{print} index($0,"DISPATCH_LOCK=\"$1\"")>0 {print "  lock_take() { [ \"$1\" = 9 ] && return 1; return 0; }   # INJECTED: the backend ANSWERS, with EWOULDBLOCK"}' \
  "$SCRIPT" > "$DVCOPY"
chmod +x "$DVCOPY"
assert_eq "$(grep -c 'INJECTED' "$DVCOPY" | tr -d ' ')" "1" DV   # ANCHOR: exactly one site
DVHO="$(NEWHO dv)"
rm -f "$SHIM_SPAWNS"; live_json "running"
DV_OUT="$(bash "$DVCOPY" "$DVHO" "dv" --cwd "$tmp/work" 2>&1)"; dv_rc=$?
assert_eq "$dv_rc" "2" DV
assert_no_file "$SHIM_SPAWNS" DV
# What the backend said, and what this process watched, as two separate claims.
assert_contains "held by a DIFFERENT open file description" "$DV_OUT" DV
assert_contains "descriptor for it is still open" "$DV_OUT" DV
# NOT the other arm's sentence. `lock_take` answered; saying it could not is the
# defect this case exists for, and saying "could not be re-checked" would mean
# the wrong branch ran.
assert_missing "could not be re-checked" "$DV_OUT" DV
assert_missing "could not answer" "$DV_OUT" DV
# Its control: put the interpretation back inside the observation, exactly as the
# hook read at the head of micro-review 6. The exit code, the refusal and the
# absent spawn are IDENTICAL on the mutant -- only the message differs, which is
# why nothing but the message could have caught this.
DVMUT="$tmp/ewouldblock-contradiction.sh"
sed 's|^    _vlfd="this process.s descriptor for it is still open"$|    _vlfd="the descriptor is still open, so it is the lock backend that could not answer"|' "$DVCOPY" > "$DVMUT"
if cmp -s "$DVCOPY" "$DVMUT"; then
  echo "FAIL[DV]: the contradiction mutant is identical to the hook -- verify_lock's observation string moved, and this control cannot fail"; fail=1
elif ! bash -n "$DVMUT" 2>/dev/null; then
  echo "FAIL[DV]: the contradiction mutant does not parse, so it proves nothing about the fixed hook"; fail=1
else
  DVHO2="$(NEWHO dv-mut)"
  rm -f "$SHIM_SPAWNS"; live_json "running"
  DV_OUT2="$(bash "$DVMUT" "$DVHO2" "dv-mut" --cwd "$tmp/work" 2>&1)"; dv_rc2=$?
  assert_eq "$dv_rc2" "2" DV
  assert_no_file "$SHIM_SPAWNS" DV
  assert_contains "could not answer" "$DV_OUT2" DV
fi
rm -f "$DVMUT" "$DVCOPY"

# ---- DU. every direct reader of `lock_take`'s status is accounted for -------
# The defect DT pins was invisible to case DR because DR's population is reason
# VARIABLES and this one was a `die` string. The general form is "a caller that
# turns lock_take's tri-state into prose", and there are exactly two of them, so
# the class is closed by enumeration rather than by hunting the next instance:
# `lock_hold`, which collapses the status into its own tri-state and says
# nothing, and `verify_lock`, which is the one that speaks. A third caller must
# be reviewed rather than discovered by a later round.
#   THE POPULATION GREP IS THE WHOLE CASE, so it is written to fail loudly
# rather than quietly. It used to require the literal `lock_take ` with ONE
# SPACE; a tab is shell whitespace, and a third caller written `lock_take<tab>9`
# parsed, read the status into prose, and left this census reporting two (round 6
# micro-review 6, reproduced with exactly that mutant). It now accepts any blank,
# a `;`, or end of line after the name, and whole-line comments are dropped
# first. A `lock_take` inside a TRAILING comment would be counted -- a false
# POSITIVE, which stops the suite and asks for a review, which is the direction
# this census is allowed to be wrong in.
du_callers() { # $1=script -> the call sites, one per line
  grep -v '^[[:blank:]]*#' "$1" | grep -E 'lock_take([[:blank:]]|;|$)' || true
}
DU_CALLERS="$(du_callers "$SCRIPT" | grep -c . | tr -d ' ')"
assert_eq "$DU_CALLERS" "2" DU
assert_eq "$(grep -c '^  lock_take "\$1"; _lh=\$?$' "$SCRIPT" | tr -d ' ')" "1" DU
assert_eq "$(grep -c '^  lock_take 9; _vl=\$?$' "$SCRIPT" | tr -d ' ')" "1" DU
# The control, and it is the mutant that falsified the old census: a third direct
# caller whose only difference is the whitespace after the name. Built with a
# real tab, and checked for having bitten, because a control whose anchor missed
# is a control that cannot fail.
DUMUT="$tmp/handoff-du-tabcaller.sh"
awk -v tab="$(printf '\t')" '{print} /^  lock_take 9; _vl=\$\?$/{print "  lock_take" tab "9; _rogue=$?; [ \"$_rogue\" = 3 ] && die \"the lock backend crashed\""}' \
  "$SCRIPT" > "$DUMUT"
if cmp -s "$SCRIPT" "$DUMUT"; then
  echo "FAIL[DU]: the tab-caller mutant is identical to the hook -- verify_lock's call site moved, and this control cannot fail"; fail=1
elif ! bash -n "$DUMUT" 2>/dev/null; then
  echo "FAIL[DU]: the tab-caller mutant does not parse, so it is not a caller this census has to see"; fail=1
else
  assert_eq "$(du_callers "$DUMUT" | grep -c . | tr -d ' ')" "3" DU
fi
rm -f "$DUMUT"

# ---- DW. every direct reader of `lock_hold`'s status is accounted for -------
# DU closes the class for `lock_take`. `lock_hold` has the SAME defect surface
# and no census: it collapses four distinct situations into status 2 (an
# unobservable `-L`, a symlink, the `exec 8>>` open, and lock_take answering
# neither 0 nor 1), so any caller that says WHICH of the four happened is naming
# a cause it did not observe. Two callers have already done exactly that -- the
# `lease_probe` trailing comment (round 6 micro-review 5) and the `_wr=2` retry
# comment (micro-review 6), both of which called status 2 "a failed open". The
# instances were corrected; this census is the class, so a fifth caller has to be
# reviewed rather than found by a later round.
#   Same whitespace-agnostic population as DU, and for the same reason: a caller
# written `lock_hold<tab>8` is a caller.
dw_callers() { # $1=script -> the call sites, one per line
  grep -v '^[[:blank:]]*#' "$1" | grep -E 'lock_hold([[:blank:]]|;|$)' || true
}
# The definition itself is NOT in this population -- there the name is followed
# by `(` -- so every match is a caller, exactly as in DU. The definition is
# asserted separately so that renaming the function fails here rather than
# emptying the census silently.
assert_eq "$(dw_callers "$SCRIPT" | grep -c . | tr -d ' ')" "4" DW
assert_eq "$(grep -c '^lock_hold() { # \$1=fd  \$2=path$' "$SCRIPT" | tr -d ' ')" "1" DW
assert_eq "$(grep -c '^  lock_hold 7 "\$_r.alert.\$_ak.flock"; _ah=\$?$' "$SCRIPT" | tr -d ' ')" "1" DW
assert_eq "$(grep -c '^  lock_hold 9 "\$1"; _rc=\$?$' "$SCRIPT" | tr -d ' ')" "1" DW
assert_eq "$(grep -c '^  lock_hold 8 "\$1"; _lp=\$?$' "$SCRIPT" | tr -d ' ')" "1" DW
assert_eq "$(grep -c '^      lock_hold 8 "\$LEASE_FILE"; _wr=\$?$' "$SCRIPT" | tr -d ' ')" "1" DW
# The control: a fifth caller, tab-separated, that turns status 2 into prose.
# Checked for having bitten -- a control whose anchor missed cannot fail.
DWMUT="$tmp/handoff-dw-tabcaller.sh"
awk -v tab="$(printf '\t')" '{print} /^  lock_hold 9 "\$1"; _rc=\$\?$/{print "  lock_hold" tab "9 \"$1\"; _rogue=$?; [ \"$_rogue\" = 2 ] && die \"the lease could not be opened\""}' \
  "$SCRIPT" > "$DWMUT"
if cmp -s "$SCRIPT" "$DWMUT"; then
  echo "FAIL[DW]: the tab-caller mutant is identical to the hook -- the dispatch call site moved, and this control cannot fail"; fail=1
elif ! bash -n "$DWMUT" 2>/dev/null; then
  echo "FAIL[DW]: the tab-caller mutant does not parse, so it is not a caller this census has to see"; fail=1
else
  assert_eq "$(dw_callers "$DWMUT" | grep -c . | tr -d ' ')" "5" DW
fi
rm -f "$DWMUT"

# ---- DX. every function with a degraded status is accounted for -------------
# DU and DW each census the callers of ONE status function. That answers two
# instances of "a caller narrates a status it did not observe" and says nothing
# about the other tri-states in the hook -- proved: appending `because its mount
# is unavailable` to `claim_lock`'s status-2 refusal for `legacy_lock_present`
# leaves DR, DU and DW all green (round 6 micro-review 7, reproduced with exactly
# that mutant). Chasing the next instance is what this branch keeps doing wrong,
# so the POPULATION is frozen instead: every function that RETURNS a status of
# 2 or more is listed here with the reviewed reason its degraded status cannot
# become an invented cause. A fifteenth stops the suite and asks for that review.
#   WHAT THIS BUYS AND WHAT IT DOES NOT -- restated after micro-review 8, which
# falsified the first version of this paragraph. It does not verify the
# dispositions: they are prose, reviewed by a human, exactly like
# `claim-census.js`'s audit list. And the set is NOT "every function that can be
# degraded" -- that population is not decidable by reading shell. A status can
# also arrive by falling off the end of an external command (`notify`,
# `_notify_darwin`, `_notify_linux`), off a node pipeline (`_row_present_raw`),
# through a variable (`timed_to_file`'s `return "$_rc"`), or as `exit 2` (`die`);
# each was read at micro-review 8 and none of them narrates a cause, but none is
# in this census either. What DX guarantees is narrower and still worth having:
# a new LITERAL degraded return is a review decision rather than a silent one.
# The rest of the invariant is carried at the other end, by DY, which freezes the
# operator-facing message TEXT itself -- an invented cause has to be SAID before
# it can be suffered, and DY sees every saying.
#   The boundary parsing is the census's own soft spot and micro-review 8 named
# four ways past it, so it is written to the shapes bash actually accepts: a
# definition line is scanned WITH its body (a one-line `f() { return 2; }` is
# 17 of this hook's 74 definitions, and the old awk `next`ed straight past its
# return), `function f {` is a definition too, and a return no function encloses
# is reported as <UNATTRIBUTED> rather than dropped.
dx_status_fns() { # $1=script -> the functions with a `return N`, N >= 2
  awk '
    /^[A-Za-z_][A-Za-z0-9_]*\(\)[[:blank:]]*\{/ ||
    /^function[[:blank:]]+[A-Za-z_][A-Za-z0-9_]*([[:blank:]]*\(\))?[[:blank:]]*\{/ {
      fn=$0
      if (fn ~ /^function/) { sub(/^function[[:blank:]]+/,"",fn); sub(/[[:blank:]]*(\(\))?[[:blank:]]*\{.*/,"",fn) }
      else                  { sub(/\(\).*/,"",fn) }
      if ($0 ~ /return [2-9][0-9]*([[:blank:]]|;|\}|$)/) print fn   # a one-line definition
      next
    }
    /^\}/ { fn=""; next }
    /^[[:blank:]]*#/ { next }
    /return [2-9][0-9]*([[:blank:]]|;|$)/ { print (fn == "" ? "<UNATTRIBUTED>" : fn) }
  ' "$1" | LC_ALL=C sort -u
}
# name             disposition -- why a degraded status here cannot invent a cause
DX_WANT="$tmp/dx-want.txt"
cat > "$DX_WANT" <<'DXW'
epoch                observed  2 = no usable clock; all three degraded callers say only that, naming no mechanism
file_exists          probe     only ever run through fs_get, which converts and PUBLISHES its status
fs_get               publishes fs_why_set on every one of its 2 paths -- this is the constructor
legacy_lock_present  delegates its only 2 comes from fs_get, so FS_WHY_TXT is live for its caller
lock_hold            censused  callers enumerated by case DW; it publishes nothing of its own
lock_take            censused  callers enumerated by case DU; it publishes nothing of its own
mtime_of             probe     only ever run through fs_get, which converts and PUBLISHES its status
path_state           probe     only ever called from inside file_exists/mtime_of/rec_get_raw, i.e. inside fs_get
rec_get_raw          probe     only ever run through fs_get, which converts and PUBLISHES its status
rec_num              delegates 2 comes from rec_read, which comes from fs_get
rec_read             delegates 2 comes from fs_get, so FS_WHY_TXT is live for its caller
retire_self          publishes every one of its 7 twos sets RETIRED before returning, and the caller prints RETIRED verbatim
row_present          observed  runs timed_to_file itself; both narrations say only "could not be run"
transcript_for       probe     only ever run through fs_get, which converts and PUBLISHES its status
watch_once           protocol  3 and 4 are the hook's exit protocol, not an observation about the world
DXW
DX_GOT="$tmp/dx-got.txt"
dx_status_fns "$SCRIPT" > "$DX_GOT"
if ! cmp -s <(awk '{print $1}' "$DX_WANT" | LC_ALL=C sort) "$DX_GOT"; then
  echo "FAIL[DX]: the set of functions that can return a degraded status changed. Each one needs a reviewed reason its status cannot become an invented cause -- that is a review decision, not an edit:"
  diff <(awk '{print $1}' "$DX_WANT" | LC_ALL=C sort) "$DX_GOT" | sed 's/^/    /'
  fail=1
fi
# The two dispositions that point AT another case are checked, not taken on trust:
# "censused by DU/DW" is worth nothing if DU or DW has been deleted. `$0` is this
# suite file, so a solo run of DX has to carry DU and DW with it.
assert_eq "$(grep -c '^# ---- DU\. ' "$0" | tr -d ' ')" "1" DX
assert_eq "$(grep -c '^# ---- DW\. ' "$0" | tr -d ' ')" "1" DX
# The control: a sixteenth function with a degraded status. It must be reported.
DXMUT="$tmp/handoff-dx-newfn.sh"
cp "$SCRIPT" "$DXMUT"
cat >> "$DXMUT" <<'DXFN'
mount_state() { # $1=path -- a sixteenth degraded status, for the control in case DX
  [ -d "$1" ] && return 0
  return 2
}
DXFN
if cmp -s "$SCRIPT" "$DXMUT"; then
  echo "FAIL[DX]: the new-function mutant is identical to the hook, so this control cannot fail"; fail=1
elif ! bash -n "$DXMUT" 2>/dev/null; then
  echo "FAIL[DX]: the new-function mutant does not parse, so it proves nothing about the census above"; fail=1
else
  case "$(dx_status_fns "$DXMUT")" in
    *mount_state*) ;;
    *) echo "FAIL[DX]: a new function with a degraded status was not reported, so this census cannot see the shape it exists for"; fail=1 ;;
  esac
fi
rm -f "$DXMUT"
# Three more controls, one per way micro-review 8 got past the boundary parsing.
# Each mutant is a sixteenth degraded status written in a spelling bash accepts
# and the first version of this census did not; each must be reported.
for _dxk in oneline oneline_comment function_kw unattributed; do
  DXMUT2="$tmp/handoff-dx-$_dxk.sh"
  cp "$SCRIPT" "$DXMUT2"
  case "$_dxk" in
    oneline)         printf 'mount_state() { [ -d "$1" ] || return 2; printf 1; }\n'                >> "$DXMUT2" ;;
    oneline_comment) printf 'mount_state() { return 2; }   # the 12-instance shape in this hook\n'  >> "$DXMUT2" ;;
    function_kw)     printf 'function mount_state {\n  [ -d "$1" ] && return 0\n  return 2\n}\n' >> "$DXMUT2" ;;
    unattributed)    printf 'mount_state() {\n  printf 1\n}\nreturn 2\n'                          >> "$DXMUT2" ;;
  esac
  _dxwant=mount_state; [ "$_dxk" = unattributed ] && _dxwant='<UNATTRIBUTED>'
  if ! bash -n "$DXMUT2" 2>/dev/null; then
    echo "FAIL[DX]: the $_dxk mutant does not parse, so it proves nothing about the census above"; fail=1
  else
    case "$(dx_status_fns "$DXMUT2")" in
      *"$_dxwant"*) ;;
      *) echo "FAIL[DX]: a degraded status spelled '$_dxk' was not reported as '$_dxwant', so this census drops it silently -- got: $(dx_status_fns "$DXMUT2" | tr '\n' ' ')"; fail=1 ;;
    esac
  fi
  rm -f "$DXMUT2"
done
# And the census must not have grown a FALSE positive doing it: the hook itself
# still has exactly the fifteen, and nothing unattributable.
assert_eq "$(dx_status_fns "$SCRIPT" | grep -c . | tr -d ' ')" "15" DX
assert_eq "$(dx_status_fns "$SCRIPT" | grep -c 'UNATTRIBUTED' | tr -d ' ')" "0" DX
rm -f "$DX_WANT" "$DX_GOT"

# ---- DY. every sentence the operator can be told is a review decision --------
# THE REGION REWRITE. Rounds 6.6, 6.7 and 6.8 each answered "a message names a
# mechanism it did not observe" with a census of one more FUNCTION -- DU's
# callers, then DW's, then DX's population -- and each time the next micro-review
# walked past it, because "which functions can be degraded" is not decidable by
# reading shell: a status arrives by literal return, by variable, by falling off
# a pipeline or an external command, or as `exit`. Three rounds at the same rate
# is the signal to rewrite the region rather than run a fourth pass, so this case
# censuses the OTHER end: an invented cause has to be SAID before an operator can
# suffer it.
#
# CORRECTED IN MICRO-REVIEW 9 -- the first version of this case was OVERSTATED.
# It censused `die` message literals only, and its header claimed "everything the
# hook can say is a literal in this one file". That claim was wrong twice over:
#   * `die` is not the only channel. The hook also speaks through `alert_once`
#     (22 sites), `prelaunch_die` (6), `notify` (5), and a bare `printf ... >&2`
#     (3). None of those were in the population, so "every sentence" covered 81
#     of the 117 lines that say something.
#   * a message need not be a literal AT the channel. `die "$_recfail"` puts the
#     variable NAME in the census and leaves the sentence -- written far above --
#     unfrozen; eight direct sites share that one variable.
# And it froze the wrong thing: hashing the sorted TEXT alone discards which site
# says what, so two guards can EXCHANGE explanations and the digest holds. That
# is not hypothetical -- micro-review 9 built it and it survived: swap need_num's
# two bound messages and a timeout of 0 is refused as "implausibly large" while
# 1000000 is told it must be at least 1.
#
# So the census now emits `channel|function|source line` for every line that puts
# operator-visible words into any channel, INCLUDING the assignment of a variable
# that carries a whole message. A positional binding (`_am="$3"`) is not one --
# it holds no sentence, and counting it would inflate the population with a line
# no operator can read. Freezing the LINE rather than the text binds each
# sentence to the site that says it, so a permutation is red. The population is
# 127 lines and was measured, not assumed. Rewording an operator message is
# therefore a review decision: update the digest deliberately, in the same commit
# as the words. That is the cost, and it is the point.
#   DY still does NOT judge whether a sentence is honest -- no census can. It
# makes the set of sentences, and the sites that say them, a thing a human signed
# off on. The degraded-reason constructors are DR's population; DY reaches them
# only where they are assigned words, and between the two cases both spellings of
# "the operator was told something" are covered.
dy_sites() { # $1=script -> channel|function|source line, one line per saying
  awk '
    # Pass 1 collects the variables that carry a WHOLE message; pass 2 emits every
    # operator-facing line, tagged by channel and enclosing function.
    function isreal(pre) { return pre !~ /(^|[[:blank:]])#/ }
    # a message variable counts only where it is ASSIGNED OPERATOR-VISIBLE WORDS:
    # a purely positional binding (_am="$3") carries no sentence and must not inflate the census.
    function assigns_words(s, v,   rhs) {
      if (!match(s, "(^|[[:blank:]]|;)" v "=")) return 0
      rhs = substr(s, RSTART + RLENGTH)
      sub(/;.*/, "", rhs)
      gsub(/\$\{[^}]*\}|\$[A-Za-z_][A-Za-z0-9_]*|\$[0-9#@*?]/, "", rhs)
      return rhs ~ /[A-Za-z]/
    }
    function trim(x) { sub(/^[[:blank:]]+/,"",x); sub(/[[:blank:]]+$/,"",x); return x }
    NR==FNR {
      if ($0 ~ /^[[:blank:]]*#/) next
      msg = ""
      # die and notify take the message as their FIRST quoted argument;
      # alert_once and prelaunch_die take it as their LAST.
      if (match($0, /(^|[^A-Za-z_])(die|notify)[[:blank:]]+"[^"]*"/)) {
        msg = substr($0, RSTART, RLENGTH); sub(/^[^"]*"/, "", msg); sub(/"$/, "", msg)
      } else if (match($0, /(^|[^A-Za-z_])(alert_once|prelaunch_die)[[:blank:]]/)) {
        n = split($0, a, "\""); if (n >= 3) msg = a[n-1]
      }
      if (msg != "") {
        bare = msg
        gsub(/\$\{[^}]*\}|\$[A-Za-z_][A-Za-z0-9_]*/, "", bare)
        if (trim(bare) == "") {                       # carried entirely by variables
          while (match(msg, /\$\{?[A-Za-z_][A-Za-z0-9_]*/)) {
            v = substr(msg, RSTART, RLENGTH); sub(/^\$\{?/, "", v)
            MSGVAR[v] = 1
            msg = substr(msg, RSTART + RLENGTH)
          }
        }
      }
      next
    }
    /^[A-Za-z_][A-Za-z0-9_]*\(\)[[:blank:]]*\{/ { fn=$0; sub(/\(\).*/,"",fn) }
    /^\}/ { fn="" }
    /^[[:blank:]]*#/ { next }
    {
      ch = ""
      if (match($0, /(^|[^A-Za-z_])die[[:blank:]]+"/)     && isreal(substr($0,1,RSTART))) ch = ch "die,"
      if (match($0, /(^|[^A-Za-z_])prelaunch_die[[:blank:]]/) && isreal(substr($0,1,RSTART))) ch = ch "prelaunch_die,"
      if (match($0, /(^|[^A-Za-z_])alert_once[[:blank:]]/) && isreal(substr($0,1,RSTART))) ch = ch "alert_once,"
      if (match($0, /(^|[^A-Za-z_])notify[[:blank:]]+"/)  && isreal(substr($0,1,RSTART))) ch = ch "notify,"
      if ($0 ~ />&2/ && $0 ~ /printf[[:blank:]]+\047/)                                        ch = ch "stderr,"
      for (v in MSGVAR) if (assigns_words($0, v)) ch = ch "msgvar,"
      if (ch == "") next
      sub(/,$/, "", ch)
      print ch "|" (fn=="" ? "<toplevel>" : fn) "|" trim($0)
    }
  ' "$1" "$1"
}
dy_digest() { dy_sites "$1" | LC_ALL=C sort | shasum -a 256 | cut -d' ' -f1; }
# a line may carry more than one channel, so split before counting rather than
# matching the whole field -- a count that a compound tag can slip past is the
# "presence, not coverage" shape this branch has produced eight times.
dy_chan()   { dy_sites "$1" | cut -d'|' -f1 | tr ',' '\n' | grep -c "^$2\$" | tr -d ' '; }
# 127, not 123. The retirement work of 2026-08-26 added four sentences and
# reworded one, and each was read before this number moved:
#   * the usage line gains "--no-retire keeps this seat alive" -- a new flag the
#     operator can pass has to appear where the flags are listed;
#   * dispatch refuses a second handoff naming the SENTINEL PATH, so the operator
#     can check the claim rather than take it, and names `--force` as the way out;
#   * --retire-exec's own arity check, an internal usage line;
#   * two from retire_exec, which are the ones that matter: it declines to stop
#     the seat and says which of the three OBSERVED conditions stopped it
#     (`$_re_reason`, set only at the three sites that saw one), and it reports a
#     pid that survived SIGKILL with "may still read as awaiting input" -- a
#     hedge, because whether the daemon re-derives that state is not observed here.
# None of the five names a mechanism it did not see; that is the review, and the
# digest below is what freezes it.
assert_eq "$(dy_sites "$SCRIPT" | grep -c . | tr -d ' ')" "127" DY
for _dyc in die:83 alert_once:22 prelaunch_die:6 notify:7 stderr:3 msgvar:6; do
  assert_eq "$(dy_chan "$SCRIPT" "${_dyc%%:*}")" "${_dyc##*:}" "DY ${_dyc%%:*}"
done
# every emitted row must carry all three fields and a real source line: a row
# whose third field is empty or a comment would be a census counting itself.
assert_eq "$(dy_sites "$SCRIPT" | awk -F'|' 'NF < 3 || $3 == "" || $3 ~ /^#/' | grep -c . | tr -d ' ')" "0" DY
assert_eq "$(dy_digest "$SCRIPT")" "c127c1842f61ff6fb71fdcb8ac8d96114bc0eb0a4e9370dbc8c59dc20109553b" DY
# Four controls, each the surviving mutant of a review round, whole-file.
# 1. micro-review 8's: a new degraded probe whose refusal names a mount nothing
#    observed -- the exact shape DU, DW and DX all stayed green on.
DYMUT="$tmp/handoff-dy-newdie.sh"
sed 's|^claim_lock() { # \$1=lock path (.flock)|mount_state() { [ -d "${1%/*}" ] \&\& return 0; return 2; }\nclaim_lock() { # $1=lock path (.flock)|' "$SCRIPT" > "$DYMUT"
printf 'claim_lock_mountguard() { mount_state "$1" || die "the mount containing $1 is unavailable"; }\n' >> "$DYMUT"
if cmp -s "$SCRIPT" "$DYMUT"; then
  echo "FAIL[DY]: the invented-cause mutant is identical to the hook, so this control cannot fail"; fail=1
elif ! bash -n "$DYMUT" 2>/dev/null; then
  echo "FAIL[DY]: the invented-cause mutant does not parse, so it proves nothing about the census above"; fail=1
else
  assert_eq "$(dy_sites "$DYMUT" | grep -c . | tr -d ' ')" "128" DY
  if [ "$(dy_digest "$DYMUT")" = "$(dy_digest "$SCRIPT")" ]; then
    echo "FAIL[DY]: a new operator message did not move the digest, so this census cannot see the shape it exists for"; fail=1
  fi
fi
rm -f "$DYMUT"
# 2. the one a COUNT cannot pass: reword an existing message without adding or
#    removing one. The count holds; the digest must not.
DYMUT2="$tmp/handoff-dy-reword.sh"
sed 's|die "unknown option: \$1"|die "unknown option: $1 (the mount may be unavailable)"|' "$SCRIPT" > "$DYMUT2"
if cmp -s "$SCRIPT" "$DYMUT2"; then
  echo "FAIL[DY]: the reword mutant is identical to the hook -- the 'unknown option' message moved, and this control cannot fail"; fail=1
elif ! bash -n "$DYMUT2" 2>/dev/null; then
  echo "FAIL[DY]: the reword mutant does not parse, so it proves nothing about the census above"; fail=1
else
  assert_eq "$(dy_sites "$DYMUT2" | grep -c . | tr -d ' ')" "127" DY
  if [ "$(dy_digest "$DYMUT2")" = "$(dy_digest "$SCRIPT")" ]; then
    echo "FAIL[DY]: a REWORDED operator message did not move the digest, so this census counts sentences rather than freezing them"; fail=1
  fi
fi
rm -f "$DYMUT2"
# 3. micro-review 9's first: the sentence is in a VARIABLE, and the mutant makes
#    it name a mount nobody probed. Nothing at the eight `die "$_recfail"` sites
#    changes, so a census of channel-site literals stays green on this.
DYMUT3="$tmp/handoff-dy-msgvar.sh"
sed "s|_recfail=\"cannot write the dispatch record \$REC |_recfail=\"cannot write the dispatch record \$REC because its mount is unavailable |" "$SCRIPT" > "$DYMUT3"
if cmp -s "$SCRIPT" "$DYMUT3"; then
  echo "FAIL[DY]: the message-variable mutant is identical to the hook, so this control cannot fail"; fail=1
elif ! bash -n "$DYMUT3" 2>/dev/null; then
  echo "FAIL[DY]: the message-variable mutant does not parse, so it proves nothing about the census above"; fail=1
else
  assert_eq "$(dy_sites "$DYMUT3" | grep -c . | tr -d ' ')" "127" DY
  assert_eq "$(dy_chan "$DYMUT3" die)" "83" DY
  if [ "$(dy_digest "$DYMUT3")" = "$(dy_digest "$SCRIPT")" ]; then
    echo "FAIL[DY]: an invented cause written into a message VARIABLE did not move the digest, so the census still reads only the channel line"; fail=1
  fi
fi
rm -f "$DYMUT3"
# 4. micro-review 9's second: a pure PERMUTATION. need_num's two bounds exchange
#    explanations, so a timeout of 0 is refused as implausibly large. The set of
#    sentences is unchanged, so a digest of the sorted TEXT cannot see it; only
#    binding each sentence to its line can.
DYMUT4="$tmp/handoff-dy-swap.sh"
sed -e "s|die \"\$1 must be at least \$_nmin, not '\$2'\"|die \"@@DYSWAP@@\"|" \
    -e "s|die \"\$1 is implausibly large ('\$2')\"|die \"\$1 must be at least \$_nmin, not '\$2'\"|" \
    -e "s|die \"@@DYSWAP@@\"|die \"\$1 is implausibly large ('\$2')\"|" "$SCRIPT" > "$DYMUT4"
# The superseded census, kept here as the CONTROL'S control: the swap must be
# invisible to it. Without this the case could pass because the mutant reworded
# something, which is control 2's job and proves nothing about site binding.
dy_literals() { # $1=script -> die() message literals only (DY before micro-review 9)
  awk '
    /^[[:blank:]]*#/ { next }
    { s = $0
      while (match(s, /(^|[^A-Za-z_])die "/)) {
        s = substr(s, RSTART + RLENGTH); q = index(s, "\"")
        if (q == 0) break
        print substr(s, 1, q - 1); s = substr(s, q + 1)
      } }
  ' "$1"
}
dy_litdigest() { dy_literals "$1" | LC_ALL=C sort | shasum -a 256 | cut -d' ' -f1; }
if cmp -s "$SCRIPT" "$DYMUT4"; then
  echo "FAIL[DY]: the permutation mutant is identical to the hook -- need_num's messages moved, and this control cannot fail"; fail=1
elif ! bash -n "$DYMUT4" 2>/dev/null; then
  echo "FAIL[DY]: the permutation mutant does not parse, so it proves nothing about the census above"; fail=1
else
  assert_eq "$(dy_sites "$DYMUT4" | grep -c . | tr -d ' ')" "127" DY
  assert_eq "$(dy_chan "$DYMUT4" die)" "83" DY
  if [ "$(dy_litdigest "$DYMUT4")" != "$(dy_litdigest "$SCRIPT")" ]; then
    echo "FAIL[DY]: the permutation control changed the SET of messages, so it is a reword and cannot show what site binding buys"; fail=1
  fi
  if [ "$(dy_digest "$DYMUT4")" = "$(dy_digest "$SCRIPT")" ]; then
    echo "FAIL[DY]: two guards exchanged their explanations and the digest held, so this census freezes sentences without freezing who says them"; fail=1
  fi
fi
rm -f "$DYMUT4"


# ============================================================================
# CHARTER — what an unattended successor is actually TOLD
# ============================================================================
# The charter is the entirety of a successor's standing instructions, and it is
# the one thing in this hook that no test can observe by running it: it is a
# string handed to a process that does not exist here. So it is asserted as text
# and as a CONTRACT WITH THE DOC. The doc claim is the load-bearing half --
# `docs/handoff-successor.md` tells a reader what sessions are told, and a doc
# that has drifted is documentation of a prompt no session was ever given.
CH_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CH_DOCS="$CH_ROOT/docs/handoff-successor.md"

ch_hook() { # the CHARTER as the successor receives it, with the shell quoting off
  sed -n '/^  CHARTER="/,/objective\."$/p' "$1" \
    | sed -e '1s/^  CHARTER="//' -e '$s/"$//'
}
ch_doc() {  # the block the doc claims is reproduced verbatim
  awk '/<!-- CHARTER-BLOCK-BEGIN -->/{f=1;next} /<!-- CHARTER-BLOCK-END -->/{f=0} f' "$1" \
    | sed '/^```$/d'
}

CH="$(ch_hook "$SCRIPT")"
# A comparison between two extractions is worth nothing until each is known to
# have extracted something: a regex that matches nothing leaves both sides empty
# and equal, and CHARTER-3 below would pass against a file with no charter in it
# at all. The count is what makes the agreement mean something.
assert_eq "$(printf '%s\n' "$CH" | grep -c .)" "8" CHARTER-0

# ---- CHARTER-1. no prohibition-shaped merge instruction survives -------------
# The bullet this replaced read "Do not merge to main and do not push to a shared
# remote". It was an ABSOLUTE prohibition with no gate, and it contradicted the
# standing directive to merge whenever merging is mechanically safe -- so on
# 2026-08-26 seat 4b5fd6f9 had to violate its own dispatch prompt to do the
# correct thing. Enumerated as a CLASS rather than as the one sentence, because
# the defect is the shape (an ungated prohibition), not the wording.
for _chbad in 'do not merge' 'never merge' 'do not push' 'never push' 'do not deploy'; do
  if printf '%s\n' "$CH" | grep -qi -- "$_chbad"; then
    echo "FAIL[CHARTER-1]: the successor charter still contains the ungated prohibition '$_chbad' -- a successor told this must break its charter to do the correct thing"
    fail=1
  fi
done

# ---- CHARTER-2. ...and the gate list is really there -------------------------
# The negative above is only half a test: deleting the merge bullet outright
# would satisfy it. Each of these is a gate whose loss changes what a successor
# does, so each is pinned by name.
assert_contains "Merge when every required gate below passes" "$CH" CHARTER-2
assert_contains "do not wait for permission" "$CH" CHARTER-2
assert_contains "that is not a reason to hold one" "$CH" CHARTER-2
assert_contains "the head you merge is the head that was reviewed" "$CH" CHARTER-2
assert_contains "the deploy freeze CLEAR" "$CH" CHARTER-2
assert_contains "FROZEN and UNKNOWN both FAIL" "$CH" CHARTER-2
assert_contains "UNESTABLISHED" "$CH" CHARTER-2
assert_contains "watch the deploy pinned by YOUR merge SHA" "$CH" CHARTER-2

# ---- CHARTER-3. hook and doc say the SAME thing ------------------------------
CH_DOC_TXT="$(ch_doc "$CH_DOCS")"
assert_eq "$(printf '%s\n' "$CH_DOC_TXT" | grep -c .)" "8" CHARTER-3
if [ "$CH" != "$CH_DOC_TXT" ]; then
  echo "FAIL[CHARTER-3]: hooks/handoff.sh and docs/handoff-successor.md disagree about the charter --"
  diff <(printf '%s\n' "$CH") <(printf '%s\n' "$CH_DOC_TXT") | sed 's/^/    /'
  fail=1
fi
# The control. An equality test between two extractions of the same shape is the
# classic assertion that cannot fail -- so the doc is MUTATED and the comparison
# must notice. The mutation is applied to a COPY, and the tracked file's digest
# is asserted unchanged by the same block that mutates, because this tree is
# auto-pushed and a fault armed in it would be a fault pushed to a shared remote.
CH_TRACKED_DIGEST="$(shasum -a 256 "$CH_DOCS" | cut -d' ' -f1)"
CH_MUT="$tmp/handoff-successor.mutant.md"
grep -v '^- After merging, watch the deploy' "$CH_DOCS" > "$CH_MUT"
if [ "$(ch_doc "$CH_MUT")" = "$CH" ]; then
  echo "FAIL[CHARTER-3]: a bullet DELETED from the doc still compares equal to the hook, so the agreement asserted above proves nothing"
  fail=1
fi
assert_eq "$(shasum -a 256 "$CH_DOCS" | cut -d' ' -f1)" "$CH_TRACKED_DIGEST" CHARTER-3
rm -f "$CH_MUT"

# ============================================================================
# RETIRE — a VERIFIED dispatch makes the predecessor terminal
# ============================================================================
# The bug: dispatch ended at "verified", the predecessor returned to its turn
# loop, and `claude agents` listed it as awaiting input forever. Measured on
# session 01c496eb: firstTerminalAt stayed null after a successful handoff.
#
# Retirement is bound to the predecessor FIVE ways, and every one of them is a
# way of refusing rather than a way of proceeding, because the consequence is a
# signal to a live process. These cases exercise each refusal with a fixture
# that makes exactly one of them false, so a binding that stopped being checked
# shows up as a case that no longer refuses.
#
# NO TEST HERE MAY KILL A REAL SESSION. The suite unsets CLAUDE_JOB_DIR /
# CLAUDE_CODE_SESSION_ID / CLAUDE_PID at the top for that reason; every case
# below sets all three explicitly, at fixtures it created.
#
# The seat is a REAL process, not an asserted one. `_seat_ancestry` walks `ps`
# for a live process named `claude` that is a genuine ancestor of the running
# script, so nothing short of that topology satisfies it -- which is the point.
# /bin/sh is reached through a SYMLINK named `claude`: a copy of a system binary
# is SIGKILLed on this platform (measured: exit 137, the signature does not
# survive the copy), while the symlink execs the signed original and `ps` reports
# the link path, which is what the ancestry probe matches on.
mkdir -p "$tmp/seat"
ln -sf /bin/sh "$tmp/seat/claude"

RT_SEAT=""
rt_alive()     { [ -n "$RT_SEAT" ] && kill -0 "$RT_SEAT" 2>/dev/null; }
rt_kill_seat() { [ -n "$RT_SEAT" ] && kill -9 "$RT_SEAT" 2>/dev/null; RT_SEAT=""; return 0; }
rt_assert_alive() { # $1=case -- the seat must still be running
  sleep 0.5
  rt_alive || { echo "FAIL[$1]: the predecessor seat was stopped even though the retirement refused or was disarmed"; fail=1; }
}
rt_assert_dead() { # $1=case
  local n=0
  while rt_alive && [ "$n" -lt 250 ]; do sleep 0.1; n=$(( n + 1 )); done
  rt_alive && { echo "FAIL[$1]: the predecessor seat (pid $RT_SEAT) is still running -- the marker is not the durable half, the stop is"; fail=1; }
  return 0
}
rt_fixture() { # $1=job short  $2=session id -> a predecessor job dir nobody else owns
  _rtf="$tmp/jobs/$1"
  rm -rf "$_rtf"; mkdir -p "$_rtf"
  printf '{"sessionId":"%s","state":"running","tempo":"working","detail":"working on the thing","firstTerminalAt":null}\n' \
    "${3:-$2}" > "$_rtf/state.json"
  printf '%s' "$_rtf"
}
rt_digest() { shasum -a 256 "$1" | cut -d' ' -f1; }
rt_dispatch() { # $1=jobdir $2=session id $3=handoff file $4=objective; rest -> handoff.sh
  local jd="$1" sid="$2" ho="$3" obj="$4"; shift 4
  rm -f "$tmp/seat.rc"; : > "$tmp/seat.out"
  CLAUDE_JOB_DIR="$jd" CLAUDE_CODE_SESSION_ID="$sid" \
  "$tmp/seat/claude" -c '
      # The seat names ITSELF as CLAUDE_PID, exactly as a real one does.
      CLAUDE_PID="${RT_PID_OVERRIDE:-$$}"; export CLAUDE_PID
      _o="$1"; _r="$2"; shift 2
      bash "$@" > "$_o" 2>&1
      echo "$?" > "$_r"
      # Stay alive so the retirement has a real process to stop -- and stay alive
      # in a LOOP rather than in a final `sleep`, because sh execs a simple last
      # command IN PLACE, and the seat would stop being named `claude` at exactly
      # the moment the ancestry probe looks at it.
      _n=0; while [ "$_n" -lt 300 ]; do sleep 0.2; _n=$(( _n + 1 )); done
    ' seat "$tmp/seat.out" "$tmp/seat.rc" "$SCRIPT" "$ho" "$obj" --cwd "$tmp/work" "$@" &
  RT_SEAT=$!
  local n=0
  while [ ! -f "$tmp/seat.rc" ] && [ "$n" -lt 600 ]; do sleep 0.1; n=$(( n + 1 )); done
  RT_RC="$(cat "$tmp/seat.rc" 2>/dev/null || echo "never-exited")"
  RT_OUT="$(cat "$tmp/seat.out" 2>/dev/null)"
}

# ---- RETIRE-1/2/7. the happy path -------------------------------------------
R1_SID="aaaaaaaa-2222-3333-4444-555555555555"
R1_JD="$(rt_fixture aaaaaaaa "$R1_SID")"
# The SUCCESSOR's own job dir, created so RETIRE-2 observes a real directory
# rather than asserting about one that never existed.
R1_SUC="$tmp/jobs/$SHORT"; rm -rf "$R1_SUC"; mkdir -p "$R1_SUC"
printf '{"sessionId":"%s","state":"running","tempo":"working","detail":"the successor, working","firstTerminalAt":null}\n' \
  "$UUID" > "$R1_SUC/state.json"
R1_SUC_DIGEST="$(rt_digest "$R1_SUC/state.json")"

live_json "running"
R1_HO="$(NEWHO retire1)"; R1_REC="$R1_HO.dispatch"
rt_dispatch "$R1_JD" "$R1_SID" "$R1_HO" "retire me"
assert_eq "$RT_RC" "0" RETIRE-1
assert_contains "retired : pending" "$RT_OUT" RETIRE-1

# RETIRE-7 (R10): the detached killer must not have inherited the dispatch lock.
# It outlives the dispatcher by design, so a leaked fd 9 would hold the
# per-handoff lock for the life of a process nobody is waiting on.
#   THE PLACEMENT IS THE ASSERTION. This ran at the END of RETIRE-1 for one
# revision, and the mutant that removes `9>&- 8>&- 7>&-` from the nohup line
# SURVIVED it -- by then the killer had already signalled, recorded `retired`
# and exited, so its inherited descriptors were closed and the lock read free.
# The leak is only observable while the child is alive, which is here: the
# dispatching shell has exited (RT_RC is written after it does, so its own fd 9
# is closed), and the killer is inside its SIGTERM -> grace -> SIGKILL window,
# ten seconds wide by default. A leaked descriptor is HELD at exactly this
# moment and free at every later one.
#   The mutant was caught anyway, by case CO, several hundred lines further on --
# which is the failure this ordering fixes rather than excuses: a leak found by
# an unrelated case is found by luck, and the case that names R10 must be the one
# that sees it.
assert_not_held "$R1_REC.flock" RETIRE-7

R1_SENT="$tmp/session-state/$R1_SID.handed-off"
assert_file "$R1_SENT" RETIRE-1
assert_eq "$(cat "$R1_SENT" 2>/dev/null)" "$SHORT" RETIRE-1

R1_ST="$(cat "$R1_JD/state.json" 2>/dev/null)"
assert_contains '"state":"done"' "$R1_ST" RETIRE-1
assert_contains '"tempo":"idle"' "$R1_ST" RETIRE-1
assert_contains "handed off to $SHORT" "$R1_ST" RETIRE-1
# firstTerminalAt is asserted POSITIVELY, not as "no longer null": the whole
# symptom was a seat whose firstTerminalAt stayed null forever, and `not null`
# is also satisfied by any garbage the writer happened to put there.
printf '%s' "$R1_ST" | grep -q '"firstTerminalAt":"[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T' || {
  echo "FAIL[RETIRE-1]: state.json carries no ISO firstTerminalAt -- got: $R1_ST"; fail=1; }
assert_rec "$R1_REC" "retired_predecessor=aaaaaaaa" RETIRE-1
await_rec "$R1_REC" '^retire_state=retired$' 300 || {
  echo "FAIL[RETIRE-1]: the retirement never recorded an outcome -- got: $(sed -n 's/^retire_state=//p' "$R1_REC" | tail -1)"; fail=1; }
rt_assert_dead RETIRE-1
# The rollback copy exists only for the window in which a rollback is possible.
assert_no_file "$R1_JD/state.json.pre-retire" RETIRE-1

# RETIRE-2 (R6): the successor is the one thing that must NOT be touched. Its job
# dir is a sibling of the predecessor's under the same parent, and its short id is
# what the dispatch record names -- so a retirement that read its subject from the
# record instead of from its own environment would land exactly here.
assert_eq "$(rt_digest "$R1_SUC/state.json")" "$R1_SUC_DIGEST" RETIRE-2


# ---- RETIRE-3. the tripwire: the seat's own id IS the successor's -------------
# The record names the SUCCESSOR. A retirement that derived its subject from the
# record would kill the session it had just started, and the two ids collapsing is
# the only way that can happen -- so it is a hard refusal rather than a check.
# This reuses $tmp/jobs/11111111 as the PREDECESSOR, which is why RETIRE-2 asserts
# above this line and not below it.
rt_kill_seat
R3_SID="$SHORT-2222-3333-4444-555555555555"
R3_JD="$(rt_fixture "$SHORT" "$R3_SID")"
R3_DIGEST="$(rt_digest "$R3_JD/state.json")"
live_json "running"
R3_HO="$(NEWHO retire3)"
rt_dispatch "$R3_JD" "$R3_SID" "$R3_HO" "tripwire"
assert_eq "$RT_RC" "0" RETIRE-3
assert_contains "REFUSED: this seat's job id IS the successor's" "$RT_OUT" RETIRE-3
assert_rec "$R3_HO.dispatch" "retire_state=refused_is_successor" RETIRE-3
assert_no_file "$tmp/session-state/$R3_SID.handed-off" RETIRE-3
assert_eq "$(rt_digest "$R3_JD/state.json")" "$R3_DIGEST" RETIRE-3
rt_assert_alive RETIRE-3
rt_kill_seat

# ---- RETIRE-3B. live, named `claude`, and NOT an ancestor --------------------
# The control for the ancestry walk. The stranger satisfies every OTHER thing the
# probe looks at -- it is alive, and `ps` reports it as `claude` -- so a probe
# that had degenerated into `kill -0` plus a name match would accept it. The only
# thing false about it is the lineage.
R3B_STRANGER_OUT="$tmp/stranger.out"
"$tmp/seat/claude" -c '_n=0; while [ "$_n" -lt 200 ]; do sleep 0.2; _n=$(( _n + 1 )); done' >"$R3B_STRANGER_OUT" 2>&1 &
R3B_STRANGER=$!
R3B_SID="bbbbbbbb-2222-3333-4444-555555555555"
R3B_JD="$(rt_fixture bbbbbbbb "$R3B_SID")"
R3B_DIGEST="$(rt_digest "$R3B_JD/state.json")"
live_json "running"
R3B_HO="$(NEWHO retire3b)"
export RT_PID_OVERRIDE="$R3B_STRANGER"
rt_dispatch "$R3B_JD" "$R3B_SID" "$R3B_HO" "not my lineage"
unset RT_PID_OVERRIDE
assert_contains "REFUSED: pid $R3B_STRANGER is not a live" "$RT_OUT" RETIRE-3B
assert_rec "$R3B_HO.dispatch" "retire_state=refused_not_ancestor" RETIRE-3B
assert_no_file "$tmp/session-state/$R3B_SID.handed-off" RETIRE-3B
assert_eq "$(rt_digest "$R3B_JD/state.json")" "$R3B_DIGEST" RETIRE-3B
kill -0 "$R3B_STRANGER" 2>/dev/null || {
  echo "FAIL[RETIRE-3B]: the stranger exited on its own, so the refusal above may be about a DEAD pid rather than about lineage -- the case proves nothing"; fail=1; }
kill -9 "$R3B_STRANGER" 2>/dev/null || true
rt_assert_alive RETIRE-3B
rt_kill_seat

# ---- RETIRE-3C. state.json records somebody else's session -------------------
# The job dir is inherited far more often than it is wrong, so "this dir is named
# after my session id" is checked against the file the DAEMON writes, not against
# the environment alone. Here the two disagree.
rt_kill_seat
R3C_SID="cccccccc-2222-3333-4444-555555555555"
R3C_JD="$(rt_fixture cccccccc "$R3C_SID" "99999999-dead-dead-dead-999999999999")"
R3C_DIGEST="$(rt_digest "$R3C_JD/state.json")"
live_json "running"
R3C_HO="$(NEWHO retire3c)"
rt_dispatch "$R3C_JD" "$R3C_SID" "$R3C_HO" "someone else's job dir"
assert_contains "REFUSED: $R3C_JD/state.json records session" "$RT_OUT" RETIRE-3C
assert_rec "$R3C_HO.dispatch" "retire_state=refused_state_mismatch" RETIRE-3C
assert_eq "$(rt_digest "$R3C_JD/state.json")" "$R3C_DIGEST" RETIRE-3C
rt_assert_alive RETIRE-3C
rt_kill_seat

# ---- RETIRE-3D. CLAUDE_JOB_DIR does not name this session --------------------
R3D_SID="99999999-2222-3333-4444-555555555555"
R3D_JD="$(rt_fixture ffffffff "$R3D_SID")"
live_json "running"
R3D_HO="$(NEWHO retire3d)"
rt_dispatch "$R3D_JD" "$R3D_SID" "$R3D_HO" "inherited job dir"
assert_contains "REFUSED: CLAUDE_JOB_DIR (ffffffff) does not name this session" "$RT_OUT" RETIRE-3D
assert_rec "$R3D_HO.dispatch" "retire_state=refused_jobdir_not_ours" RETIRE-3D
assert_no_file "$tmp/session-state/$R3D_SID.handed-off" RETIRE-3D
rt_assert_alive RETIRE-3D
rt_kill_seat

# ---- RETIRE-4. an UNVERIFIED dispatch retires nothing -------------------------
# R7. The whole justification for stopping the predecessor is that the work is
# demonstrably in someone else's hands. A dispatch that could not confirm the
# successor has not established that, and a seat that reads awaiting-input is
# strictly better than work nobody holds.
R4_SID="dddddddd-2222-3333-4444-555555555555"
R4_JD="$(rt_fixture dddddddd "$R4_SID")"
R4_DIGEST="$(rt_digest "$R4_JD/state.json")"
printf '[]\n' > "$SHIM_AGENTS"        # the successor never appears in the list
R4_HO="$(NEWHO retire4)"
rt_dispatch "$R4_JD" "$R4_SID" "$R4_HO" "never confirmed"
[ "$RT_RC" != "0" ] || { echo "FAIL[RETIRE-4]: an unverified dispatch exited 0"; fail=1; }
assert_missing "retired :" "$RT_OUT" RETIRE-4
assert_no_file "$tmp/session-state/$R4_SID.handed-off" RETIRE-4
assert_eq "$(rt_digest "$R4_JD/state.json")" "$R4_DIGEST" RETIRE-4
if grep -q '^retire_state=' "$R4_HO.dispatch" 2>/dev/null; then
  echo "FAIL[RETIRE-4]: a failed dispatch recorded a retire_state -- retirement ran on a path that never reached 'verified'"; fail=1
fi
rt_assert_alive RETIRE-4
rt_kill_seat
live_json "running"

# ---- RETIRE-5. the opt-outs, and the seat that has nothing to retire ---------
R5_SID="eeeeeeee-2222-3333-4444-555555555555"
R5_JD="$(rt_fixture eeeeeeee "$R5_SID")"
R5_HO="$(NEWHO retire5a)"
rt_dispatch "$R5_JD" "$R5_SID" "$R5_HO" "flag opt-out" --no-retire
assert_eq "$RT_RC" "0" RETIRE-5
assert_contains "retired : no (--no-retire)" "$RT_OUT" RETIRE-5
assert_no_file "$tmp/session-state/$R5_SID.handed-off" RETIRE-5
rt_assert_alive RETIRE-5
rt_kill_seat

R5B_SID="eeee1111-2222-3333-4444-555555555555"
R5B_JD="$(rt_fixture eeee1111 "$R5B_SID")"
R5B_HO="$(NEWHO retire5b)"
export CLAUDE_HANDOFF_RETIRE=0
rt_dispatch "$R5B_JD" "$R5B_SID" "$R5B_HO" "env opt-out"
unset CLAUDE_HANDOFF_RETIRE
assert_contains "retired : no (disarmed by CLAUDE_HANDOFF_RETIRE=0)" "$RT_OUT" RETIRE-5
assert_no_file "$tmp/session-state/$R5B_SID.handed-off" RETIRE-5
rt_assert_alive RETIRE-5
rt_kill_seat

# ...and the ordinary case this whole suite runs in: an attended shell with no
# job of its own. It must skip, not refuse, and certainly not guess at a pid.
R5C_HO="$(NEWHO retire5c)"
out="$(GOF "$R5C_HO" "no job dir" 2>&1)"; code=$?
assert_eq "$code" "0" RETIRE-5
assert_contains "retired : no (not a background seat: no CLAUDE_JOB_DIR)" "$out" RETIRE-5

# ---- RETIRE-6. a retired seat may not dispatch a SECOND successor ------------
# R8's other half. The sentinel outlives the process, so a seat that somehow gets
# another turn -- a wake, a revival wave, a human resuming it -- cannot start a
# second successor against work already in flight. RETIRE-1's sentinel is still
# on disk, which is the point: this is the same session id asking again.
R6_HO="$(NEWHO retire6)"
R6_SPAWNS_BEFORE="$(grep -c . "$SHIM_SPAWNS" 2>/dev/null || echo 0)"
out="$(CLAUDE_CODE_SESSION_ID="$R1_SID" bash "$SCRIPT" "$R6_HO" "again" --cwd "$tmp/work" 2>&1)"; code=$?
assert_eq "$code" "2" RETIRE-6
assert_contains "already handed off" "$out" RETIRE-6
assert_no_file "$R6_HO.dispatch" RETIRE-6
# Refusing has to mean nothing was LAUNCHED. A guard that dies after the spawn
# reports a refusal and leaves a second successor running on the same work.
assert_eq "$(grep -c . "$SHIM_SPAWNS" 2>/dev/null || echo 0)" "$R6_SPAWNS_BEFORE" RETIRE-6
# ...and --force is the override, so the guard is a default and not a wall.
out="$(CLAUDE_CODE_SESSION_ID="$R1_SID" bash "$SCRIPT" "$R6_HO" "again" --cwd "$tmp/work" --force 2>&1)"; code=$?
assert_eq "$code" "0" RETIRE-6
assert_rec "$R6_HO.dispatch" "state=verified" RETIRE-6

# ---- RETIRE-9. the successor dies between verification and the signal --------
# The window the abort path exists for. It cannot be hit by racing, because both
# agent-list reads come through the same shim: the flip is keyed on the record
# already saying `state=verified`, which places it strictly after the dispatch's
# own reads and strictly before the retirement's re-read.
#
# What must happen is a ROLLBACK, not merely a skipped kill: the sentinel and the
# terminal state were written before the child was spawned, so leaving them would
# be a seat that reads `done` with nobody holding the work.
#
# WHAT THIS CASE DOES NOT PIN, stated because the mutation run measured it: the
# EXISTENCE of the act-time re-read. Replacing `if ! read_agents` with `if false`
# in `retire_exec` leaves this case GREEN -- with no fresh list the successor
# looks absent, the retirement aborts, and abort is exactly what RETIRE-9 asks
# for. That mutant is caught by RETIRE-1 instead, where a happy-path dispatch
# then aborts and records `retire_aborted` where `retired` was expected. The
# re-verify is pinned by the PAIR (RETIRE-1 must proceed, RETIRE-9 must abort),
# never by this case alone, and a future edit that weakens RETIRE-1 silently
# un-pins it here too.
R9_SID="dddd1111-2222-3333-4444-555555555555"
R9_JD="$(rt_fixture dddd1111 "$R9_SID")"
R9_DIGEST="$(rt_digest "$R9_JD/state.json")"
live_json "running"
R9_HO="$(NEWHO retire9)"; R9_REC="$R9_HO.dispatch"
export SHIM_AGENTS_AFTER="$tmp/agents-after.json" SHIM_AGENTS_AFTER_REC="$R9_REC"
printf '[]\n' > "$SHIM_AGENTS_AFTER"
rt_dispatch "$R9_JD" "$R9_SID" "$R9_HO" "successor dies"
unset SHIM_AGENTS_AFTER SHIM_AGENTS_AFTER_REC
assert_eq "$RT_RC" "0" RETIRE-9
# The dispatcher BELIEVED it would retire -- "pending" is the honest word for a
# claim whose irreversible half had not happened yet.
assert_contains "retired : pending" "$RT_OUT" RETIRE-9
await_rec "$R9_REC" '^retire_state=retire_aborted$' 300 || {
  echo "FAIL[RETIRE-9]: the retirement did not abort on a vanished successor -- retire_state=$(sed -n 's/^retire_state=//p' "$R9_REC" | tail -1)"; fail=1; }
assert_no_file "$tmp/session-state/$R9_SID.handed-off" RETIRE-9
assert_eq "$(rt_digest "$R9_JD/state.json")" "$R9_DIGEST" RETIRE-9
assert_no_file "$R9_JD/state.json.pre-retire" RETIRE-9
rt_assert_alive RETIRE-9
rt_kill_seat
live_json "running"

# ---- RETIRE-10. a successor that is listed but NOT positively live -----------
# The fail-OPEN half of the act-time re-verify, found by Codex review of the
# landed range and reproduced before it was believed. The check tested
# `$DONE_STATES` -- a DENYLIST -- so anything outside that list authorised an
# irreversible kill: the empty string, a future `claude agents` enum value, and
# `blocked`, which is reachable today by any successor that stops on an approval
# prompt. RETIRE-9 cannot see this: there the successor is ABSENT, which the old
# code refused for a different reason (`-z "$_re_id"`), so the denylist was never
# the deciding branch in any existing case.
#
# The distinction from RETIRE-9 is the point -- the successor here IS listed and
# IS non-terminal. Only "positively observed live" may authorise retirement, so
# the expected outcome is the same full rollback RETIRE-9 asserts.
R10_SID="eeee1111-2222-3333-4444-555555555555"
R10_JD="$(rt_fixture eeee1111 "$R10_SID")"
R10_DIGEST="$(rt_digest "$R10_JD/state.json")"
live_json "running"
R10_HO="$(NEWHO retire10)"; R10_REC="$R10_HO.dispatch"
export SHIM_AGENTS_AFTER="$tmp/agents-after-blocked.json" SHIM_AGENTS_AFTER_REC="$R10_REC"
# Same row the dispatch verified, with ONE field changed. Built from $SHORT and
# $UUID so a rename of either cannot leave this case asserting against a name
# that no longer exists.
printf '[{"id":"%s","cwd":"%s","kind":"background","startedAt":1787000000000,"sessionId":"%s","state":"blocked"}]\n' \
  "$SHORT" "$tmp/work" "$UUID" > "$SHIM_AGENTS_AFTER"
rt_dispatch "$R10_JD" "$R10_SID" "$R10_HO" "successor blocks"
unset SHIM_AGENTS_AFTER SHIM_AGENTS_AFTER_REC
assert_eq "$RT_RC" "0" RETIRE-10
assert_contains "retired : pending" "$RT_OUT" RETIRE-10
await_rec "$R10_REC" '^retire_state=retire_aborted$' 300 || {
  echo "FAIL[RETIRE-10]: a successor in state 'blocked' authorised retirement -- retire_state=$(sed -n 's/^retire_state=//p' "$R10_REC" | tail -1)"; fail=1; }
# The abort must be attributed to the STATE, not to absence: the two paths have
# different reasons and a rollback for the wrong reason is a passing test over a
# broken branch.
grep -q "not positively live" "$R10_REC" 2>/dev/null || {
  echo "FAIL[RETIRE-10]: aborted, but not for the state -- the reason must name the non-live state"; fail=1; }
assert_no_file "$tmp/session-state/$R10_SID.handed-off" RETIRE-10
assert_eq "$(rt_digest "$R10_JD/state.json")" "$R10_DIGEST" RETIRE-10
assert_no_file "$R10_JD/state.json.pre-retire" RETIRE-10
rt_assert_alive RETIRE-10
rt_kill_seat
live_json "running"

# ---- RETIRE-11. the grace value is validated like every other number ---------
# `RETIRE_GRACE_SEC` shipped without the `need_num` its three siblings get. The
# consequence is not a loud failure: the script runs under `set -u` and not
# `set -e`, so `[ "$_re_n" -lt "$RETIRE_GRACE_SEC" ]` errors, the loop is SKIPPED,
# and the configured graceful shutdown silently becomes an immediate SIGKILL.
# Both directions are asserted -- a validation test that only checks the refusal
# passes just as well when the flag has been wired to refuse everything.
R11_OUT="$(CLAUDE_HANDOFF_RETIRE_GRACE=ten bash "$SCRIPT" --status 2>&1)" && R11_RC=0 || R11_RC=$?
# NOT assert_ne: this suite has no such helper, and an undefined function under
# `set -u` without `set -e` prints "command not found" to stderr and lets the
# case PASS -- the same fail-open shape RETIRE-10 exists to close.
[ "$R11_RC" != "0" ] || { echo "FAIL[RETIRE-11]: a malformed grace value was ACCEPTED (rc=0)"; fail=1; }
assert_contains "CLAUDE_HANDOFF_RETIRE_GRACE must be a whole number" "$R11_OUT" RETIRE-11
# 0 is a legitimate choice (kill at once), so the floor is 0 and not 1.
R11B_OUT="$(CLAUDE_HANDOFF_RETIRE_GRACE=0 bash "$SCRIPT" --status 2>&1)" && R11B_RC=0 || R11B_RC=$?
assert_eq "$R11B_RC" "0" RETIRE-11
case "$R11B_OUT" in
  *"RETIRE_GRACE"*) echo "FAIL[RETIRE-11]: a valid grace of 0 was refused -- the floor must be 0, not 1"; fail=1 ;;
esac

# Nothing below this line depends on a seat, and a seat left running would idle
# for a minute after the suite has printed its verdict.
pkill -f "$tmp/seat/claude" 2>/dev/null || true

# The verdict is the LAST line of this file on purpose: it used to sit above the
# cases appended after it, so those cases printed their failures and the suite
# still exited 0 and printed PASS.
[ "$fail" = 0 ] && echo "PASS: handoff" || exit 1
