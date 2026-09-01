#!/usr/bin/env bash
# Tests for hooks/context-watchdog.mjs — plain bash, no bats dependency.
# The hook is driven through its real interface: a hook JSON payload on stdin
# pointing at a real transcript file, and JSON on stdout.
set -u
HOOK="$(cd "$(dirname "$0")/.." && pwd)/hooks/context-watchdog.mjs"
fail=0
assert_contains() { case "$2" in *"$1"*) ;; *) echo "FAIL[$3]: expected to contain: $1"; fail=1;; esac; }
assert_missing()  { case "$2" in *"$1"*) echo "FAIL[$3]: expected NOT to contain: $1"; fail=1;; *) ;; esac; }
assert_eq()       { [ "$1" = "$2" ] || { echo "FAIL[$3]: expected '$2' got '$1'"; fail=1; }; }

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
export TMPDIR="$tmp"   # the PostToolUse band file lives under TMPDIR
# The handed-off sentinel directory. Pointed at $tmp for EVERY case, not only the
# HANDEDOFF ones: the default is the real ~/.claude/session-state, so a suite run
# on a machine that has genuinely handed off sessions would read a live sentinel
# and silence cases that are supposed to speak.
export CLAUDE_HANDOFF_STATE_DIR="$tmp/session-state"

T="$tmp/transcript.jsonl"
# $1 = window tokens, $2 = extra json fields on the entry (may be empty)
write_transcript() {
  printf '{"type":"assistant"%s,"timestamp":"%s","message":{"usage":{"input_tokens":%s,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}\n' \
    "${2:-}" "$(date -u +%FT%TZ)" "$1" > "$T"
}
# An ISO timestamp N seconds in the past. BSD and GNU date disagree on the flag,
# so both are tried — the resume band is a function of this value.
iso_ago() { # $1 = seconds ago
  if date -u -v-1S +%FT%TZ >/dev/null 2>&1; then date -u -v-"$1"S +%FT%TZ
  else date -u -d "-$1 seconds" +%FT%TZ; fi
}
# The window the hook reports is input + cache_read + cache_creation. Every band
# case above puts the whole total in input_tokens, so dropping either cached term
# from the sum changes nothing they observe — while in a real session the cached
# terms ARE the window (a resumed session is almost entirely cache_read).
write_usage() { # $1=input $2=cache_read $3=cache_creation [$4=seconds ago]
  printf '{"type":"assistant","timestamp":"%s","message":{"usage":{"input_tokens":%s,"cache_read_input_tokens":%s,"cache_creation_input_tokens":%s}}}\n' \
    "$(iso_ago "${4:-0}")" "$1" "$2" "$3" > "$T"
}
run() { # $1 = event name, $2 = session id
  printf '{"hook_event_name":"%s","transcript_path":"%s","session_id":"%s"}' "$1" "$T" "$2" | node "$HOOK"
}
# The additionalContext as the model actually receives it: JSON-decoded, so an
# assertion can quote the launcher invocation exactly as written, quotes and all.
ctx() { # stdin = hook stdout
  jq -r '.hookSpecificOutput.additionalContext // ""'
}

# The exact invocations the hook must hand the model. Asserting the whole string
# — launcher path AND both placeholders — is the point: a substring check for
# "handoff.sh" survives a mutation that renames the path to a script that does
# not exist, and the model would faithfully run the broken command.
# QUOTED, and with `--` before the objective: an unquoted <absolute-handoff-path>
# breaks on any path containing a space, and without `--` an objective beginning
# with a dash is read as an option. The model runs this string verbatim.
URGENT_CMD='`~/dotfiles/claude/hooks/handoff.sh "<absolute-handoff-path>" -- "<one-line objective>"`'
WARN_CMD='`~/dotfiles/claude/hooks/handoff.sh "<handoff-file>" -- "<objective>"`'

# ---- A. URGENT names the launcher, with the exact invocation --------------
# Since the 2026-08-31 lifecycle decision the urgent band's message is "sync
# durable state and let auto-compact fire", with dispatch reserved for genuine
# task boundaries — so the band must carry the ledger sync, must NOT order a
# mid-task dispatch, and still carries the exact boundary-dispatch invocation.
write_transcript 155000
out="$(run UserPromptSubmit sA)"
assert_contains "$URGENT_CMD" "$(printf '%s' "$out" | ctx)" A
# the durable-state sync is the whole point of the band now
assert_contains "~/.claude/ops" "$out" A
assert_contains "do NOT dispatch a successor merely because context is high" "$out" A
assert_contains "genuine task boundary" "$out" A
# the demoted behaviour must stay demoted: no autonomous mid-task dispatch order
assert_missing "Hand off AUTONOMOUSLY" "$out" A
# the no-blocking rule must survive the rewire
assert_contains "NEVER stop work to wait" "$out" A

# ---- B. WARN nudges without claiming urgency ------------------------------
write_transcript 125000
out="$(run UserPromptSubmit sB)"
assert_contains "warn threshold" "$out" B
assert_contains "$WARN_CMD" "$(printf '%s' "$out" | ctx)" B
assert_contains "~/.claude/ops" "$out" B
assert_missing "Auto-compact will fire" "$out" B

# ---- C. below WARN says nothing ------------------------------------------
write_transcript 40000
out="$(run UserPromptSubmit sC)"
assert_eq "$out" "" C

# ---- D. PostToolUse URGENT also names the launcher, and throttles ---------
write_transcript 160000
out="$(run PostToolUse sD)"
assert_contains "$URGENT_CMD" "$(printf '%s' "$out" | ctx)" D
assert_contains "~/.claude/ops" "$out" D
assert_missing "Hand off AUTONOMOUSLY" "$out" D
# same band again -> silent
out="$(run PostToolUse sD)"
assert_eq "$out" "" D
# crossing into a new 25K band -> speaks again
write_transcript 190000
out="$(run PostToolUse sD)"
assert_contains "$URGENT_CMD" "$(printf '%s' "$out" | ctx)" D

# ---- D2. PostToolUse WARN names the launcher too --------------------------
# The warn band is the one that fires at a task boundary, i.e. the band that
# actually gets used most; it must carry a runnable command, not just advice.
write_transcript 125000
out="$(run PostToolUse sD2)"
assert_contains "$WARN_CMD" "$(printf '%s' "$out" | ctx)" D2
assert_missing "Auto-compact fires lossily" "$out" D2

# ---- E. a subagent's usage must not be read as this session's window ------
# isSidechain entries describe the SUBAGENT's window; counting them would make
# a 35K subagent look like the parent shrank.
write_transcript 155000
printf '{"type":"assistant","isSidechain":true,"timestamp":"%s","message":{"usage":{"input_tokens":35000,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}\n' \
  "$(date -u +%FT%TZ)" >> "$T"
out="$(run UserPromptSubmit sE)"
assert_contains "handoff.sh" "$out" E

# ---- F. a broken payload must never break the session --------------------
out="$(printf 'not json' | node "$HOOK" 2>&1)"; code=$?
assert_eq "$code" "0" F
assert_eq "$out" "" F
out="$(printf '{"hook_event_name":"UserPromptSubmit","transcript_path":"/nope/nope.jsonl"}' | node "$HOOK" 2>&1)"; code=$?
assert_eq "$code" "0" F
assert_eq "$out" "" F

# ---- G. the band edges themselves, both events ---------------------------
# The thresholds are the whole contract, and every earlier case sits comfortably
# inside a band, so a `>` written where `>=` was meant — or a threshold nudged by
# a thousand — changes nothing any of them observe. These cross the boundary.
# Note ~120K prints for 119,999 too (it is rounded), so the band WORDING is what
# distinguishes them, never the reported number.
band_case() { # $1=event  $2=tokens  $3=session  $4=silent|warn|urgent  $5=label
  write_transcript "$2"
  local o c
  o="$(run "$1" "$3")"
  case "$4" in
    silent) assert_eq "$o" "" "$5" ;;
    warn)
      c="$(printf '%s' "$o" | ctx)"
      assert_contains "$WARN_CMD" "$c" "$5"
      assert_missing "$URGENT_CMD" "$c" "$5"
      ;;
    urgent)
      c="$(printf '%s' "$o" | ctx)"
      assert_contains "$URGENT_CMD" "$c" "$5"
      assert_missing "$WARN_CMD" "$c" "$5"
      ;;
  esac
}

# WARN = 120_000, URGENT = 150_000, and both are inclusive lower bounds.
band_case UserPromptSubmit 119999 sG1 silent G-ups-119999
band_case UserPromptSubmit 120000 sG2 warn   G-ups-120000
band_case UserPromptSubmit 149999 sG3 warn   G-ups-149999
band_case UserPromptSubmit 150000 sG4 urgent G-ups-150000

# PostToolUse throttles per session, so each edge gets its own session id;
# otherwise a later case would be silenced by an earlier one's band file.
band_case PostToolUse 119999 sG5 silent G-ptu-119999
band_case PostToolUse 120000 sG6 warn   G-ptu-120000
band_case PostToolUse 149999 sG7 warn   G-ptu-149999
band_case PostToolUse 150000 sG8 urgent G-ptu-150000

# ---- H. the same totals, distributed across the three usage fields -------
# Each band edge again with the total carried by cache_read, by cache_creation,
# and split three ways. Dropping a term from the sum reports a smaller window and
# silently skips a band — the failure mode is exactly "the hook went quiet".
dist_case() { # $1=event $2=in $3=cr $4=cc $5=session $6=silent|warn|urgent $7=label
  write_usage "$2" "$3" "$4"
  local o c
  o="$(run "$1" "$5")"
  case "$6" in
    silent) assert_eq "$o" "" "$7" ;;
    warn)   c="$(printf '%s' "$o" | ctx)"; assert_contains "$WARN_CMD" "$c" "$7"; assert_missing "$URGENT_CMD" "$c" "$7" ;;
    urgent) c="$(printf '%s' "$o" | ctx)"; assert_contains "$URGENT_CMD" "$c" "$7"; assert_missing "$WARN_CMD" "$c" "$7" ;;
  esac
}
# all of it cached-read (the shape of a resumed session)
dist_case UserPromptSubmit 0 119999 0 sH1 silent H-cr-119999
dist_case UserPromptSubmit 0 120000 0 sH2 warn   H-cr-120000
dist_case UserPromptSubmit 0 149999 0 sH3 warn   H-cr-149999
dist_case UserPromptSubmit 0 150000 0 sH4 urgent H-cr-150000
# all of it cache-creation (the shape of the first turn after a cache lapse)
dist_case UserPromptSubmit 0 0 119999 sH5 silent H-cc-119999
dist_case UserPromptSubmit 0 0 120000 sH6 warn   H-cc-120000
dist_case UserPromptSubmit 0 0 150000 sH7 urgent H-cc-150000
# mixed, summing to exactly each edge
dist_case UserPromptSubmit 40000 40000 39999 sH8  silent H-mix-119999
dist_case UserPromptSubmit 40000 40000 40000 sH9  warn   H-mix-120000
dist_case UserPromptSubmit 50000 50000 50000 sH10 urgent H-mix-150000
dist_case PostToolUse     40000 40000 39999 sH11 silent H-ptu-mix-119999
dist_case PostToolUse     40000 40000 40000 sH12 warn   H-ptu-mix-120000
dist_case PostToolUse     50000 50000 50000 sH13 urgent H-ptu-mix-150000

# ---- I. the resume band, at its own two boundaries -----------------------
# The resume band is a function of the WALL CLOCK, so the wall clock is PINNED: a
# --require preload replaces Date.now() with a fixed epoch, and every fixture
# timestamp here is derived from that same epoch.
# The previous shape wrote "3599 seconds ago" with `date`, which truncates to the
# whole second — so the fixture's real age was 3599 + frac(now), and the test's own
# runtime (~0.2s) was added on top. The margin to the 3,600s boundary was
# 1s - frac(now) - runtime, i.e. NEGATIVE about one run in ten: measured on
# 2026-08-18, the old I-3599 assertion failed in 2 of 20 full-suite runs. A boundary
# that holds only when the machine is fast is not a boundary test — and a pinned
# clock also lets the boundary be crossed by ONE MILLISECOND, which the wall-clock
# version could never do.
CLOCK="$tmp/fixed-clock.cjs"
cat > "$CLOCK" <<'EOF'
// Test-only clock pin. The hook reads Date.now() once (the resume gap) and
// Date.parse for the fixture's timestamp; only the former is replaced.
const fixed = Number(process.env.CW_FIXED_NOW_MS);
if (Number.isFinite(fixed) && fixed > 0) Date.now = () => fixed;
EOF
# 2033-05-18T03:33:20Z — deliberately in the FUTURE. Every "resume expected" fixture
# below therefore carries a timestamp LATER than the real now, so a preload that
# failed to load would yield a negative gap and fail those assertions loudly rather
# than let them pass for the wrong reason.
FIXED_NOW_MS=2000000000000
write_usage_before() { # $1=ms before the pinned now $2=input $3=cache_read $4=cache_creation
  printf '{"type":"assistant","timestamp":"%s","message":{"usage":{"input_tokens":%s,"cache_read_input_tokens":%s,"cache_creation_input_tokens":%s}}}\n' \
    "$(node -e 'process.stdout.write(new Date(Number(process.argv[1]) - Number(process.argv[2])).toISOString())' "$FIXED_NOW_MS" "$1")" \
    "$2" "$3" "$4" > "$T"
}
runp() { # run(), with the clock pinned; a subshell so the pin never leaks to other cases
  ( export CW_FIXED_NOW_MS="$FIXED_NOW_MS" NODE_OPTIONS="--require $CLOCK"; run "$1" "$2" )
}
RESUME_SAYS="idle >1h"
# one millisecond past the hour: the resume band
write_usage_before 3600001 0 155000 0
out="$(runp UserPromptSubmit sI1)"
assert_contains "$RESUME_SAYS" "$out" I-3600001ms
assert_missing "urgent threshold" "$(printf '%s' "$out" | ctx)" I-3600001ms
# EXACTLY one hour: the comparison is strict, so this is NOT the resume band — it
# falls through to urgent
write_usage_before 3600000 0 155000 0
out="$(runp UserPromptSubmit sI2)"
assert_missing "$RESUME_SAYS" "$out" I-3600000ms
assert_contains "$URGENT_CMD" "$(printf '%s' "$out" | ctx)" I-3600000ms
# idle, but under RESUME_MIN (100K) and under WARN: silent
write_usage_before 3600001 0 99999 0
assert_eq "$(runp UserPromptSubmit sI3)" "" I-min-99999
# idle at exactly RESUME_MIN: the resume band, even though 100K is below WARN
write_usage_before 3600001 0 100000 0
out="$(runp UserPromptSubmit sI4)"
assert_contains "$RESUME_SAYS" "$out" I-min-100000
# PostToolUse has no resume band — an idle gap there must still report the window
write_usage_before 7200000 0 155000 0
out="$(runp PostToolUse sI5)"
assert_missing "$RESUME_SAYS" "$out" I-ptu
assert_contains "$URGENT_CMD" "$(printf '%s' "$out" | ctx)" I-ptu

# ---- J. a record LARGER than the tail must not silence the hook ----------
# The reader used to take a fixed 1 MiB suffix of the transcript. A single
# assistant record can be bigger than that (one measured at 1,100,158 bytes), and
# a read that lands mid-record yields a FRAGMENT: every JSON.parse fails, the
# reader reports "no usage", and the hook emits nothing — no WARN, no URGENT — on
# precisely the sessions closest to the auto-compact cliff. The window has to grow
# until a whole main-chain record is inside it.
#
# The fixture is two records: a 125K (WARN) one first, then a >1 MiB one at 160K
# (URGENT). Asserting BOTH bands is the point — "~160K" fails under the fixed-tail
# reader (which emits nothing at all), and "~125K" absent proves the grown window
# still reports the LAST record rather than the first one it happens to reach.
pad="$(head -c 1100000 /dev/zero | tr '\0' 'x')"
{
  printf '{"type":"assistant","timestamp":"%s","message":{"usage":{"input_tokens":125000,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}\n' "$(iso_ago 0)"
  printf '{"type":"assistant","pad":"%s","timestamp":"%s","message":{"usage":{"input_tokens":160000,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}\n' "$pad" "$(iso_ago 0)"
} > "$T"
# Precondition, not decoration: if the fixture ever stopped exceeding the tail the
# case would pass under the very code it exists to catch (a control that cannot
# fail is not a control).
tsize="$(wc -c < "$T" | tr -d ' ')"
[ "$tsize" -gt 1048576 ] || { echo "FAIL[J]: fixture must exceed the 1 MiB tail, got $tsize bytes"; fail=1; }
out="$(run UserPromptSubmit sJ1)"
assert_contains "~160K" "$out" J-big-last
assert_missing  "~125K" "$out" J-big-last
assert_contains "$URGENT_CMD" "$(printf '%s' "$out" | ctx)" J-big-last
# ...and growing must not make the reader indiscriminate: a giant SIDECHAIN record
# is still a subagent's window, so the small main-chain record before it wins.
{
  printf '{"type":"assistant","timestamp":"%s","message":{"usage":{"input_tokens":155000,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}\n' "$(iso_ago 0)"
  printf '{"type":"assistant","isSidechain":true,"pad":"%s","timestamp":"%s","message":{"usage":{"input_tokens":30000,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}\n' "$pad" "$(iso_ago 0)"
} > "$T"
out="$(run UserPromptSubmit sJ2)"
assert_contains "~155K" "$out" J-big-sidechain
assert_missing  "~30K"  "$out" J-big-sidechain
assert_contains "$URGENT_CMD" "$(printf '%s' "$out" | ctx)" J-big-sidechain
unset pad

# ---- K. the read cap must report a FAILED measurement, not go silent -----
# The growing window is bounded (MAX_TAIL_BYTES), and hitting that bound used to
# return the same `null` as "read the whole file, found nothing" — so the hook
# emitted nothing at all on the transcripts most likely to be enormous, which is
# this hook's own worst failure mode (its comment: "this hook's failure mode is
# silence"). The cap and the honest-empty case must now be distinguishable from
# the outside.
#
# Pinned against the REAL constant, not an env-lowered one: a lowered cap would
# test a path the product never takes. If the constant moves, this case must be
# resized deliberately rather than quietly testing nothing — so assert it.
grep -q 'MAX_TAIL_BYTES = 16 \* 1_048_576' "$HOOK" \
  || { echo "FAIL[K]: hook no longer declares MAX_TAIL_BYTES = 16 * 1_048_576 — resize the K fixtures to the new cap"; fail=1; }
CAP=$((16 * 1048576))

# K1 — cause (a): the only main-chain usage record sits beyond the cap, so every
# window the reader is allowed to take is padding (a mid-record fragment in real
# life). Must report the failure, and must NOT invent a number in either direction.
{
  printf '{"type":"assistant","timestamp":"%s","message":{"usage":{"input_tokens":155000,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}\n' "$(iso_ago 0)"
  dd if=/dev/zero bs=1048576 count=17 2>/dev/null | tr '\0' 'x'
  printf '\n'
} > "$T"
tsize="$(wc -c < "$T" | tr -d ' ')"
[ "$tsize" -gt "$CAP" ] || { echo "FAIL[K1]: fixture must exceed the $CAP-byte cap, got $tsize bytes"; fail=1; }
out="$(run UserPromptSubmit sK1)"
assert_contains "MEASUREMENT FAILED" "$out" K1-degraded
# A fabricated count is the specific thing the report must not do — neither the
# record's real 155K (which the reader never saw) nor a rounded-down 0K.
assert_missing "155K" "$out" K1-no-fabricated-count
assert_missing "~0K"  "$out" K1-no-fabricated-count
# Both reachable causes have to be named, because the hook cannot tell them apart
# and they mean opposite things: (a) an enormous main-chain record → the window
# may be near the cliff; (b) trailing subagent output → says nothing about it.
assert_contains "main-chain record larger than the cap" "$out" K1-names-cause-a
assert_contains "isSidechain" "$out" K1-names-cause-b

# K2 — cause (b): everything inside the cap PARSES, and is all subagent output.
# Same verdict, and it proves the degraded return is not merely "the bytes were
# unparseable".
pad="$(head -c 1048000 /dev/zero | tr '\0' 'x')"
: > "$T"
i=0
while [ "$i" -lt 18 ]; do
  printf '{"type":"assistant","isSidechain":true,"pad":"%s","timestamp":"%s","message":{"usage":{"input_tokens":30000,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}\n' "$pad" "$(iso_ago 0)" >> "$T"
  i=$((i + 1))
done
tsize="$(wc -c < "$T" | tr -d ' ')"
[ "$tsize" -gt "$CAP" ] || { echo "FAIL[K2]: sidechain fixture must exceed the $CAP-byte cap, got $tsize bytes"; fail=1; }
out="$(run UserPromptSubmit sK2)"
assert_contains "MEASUREMENT FAILED" "$out" K2-degraded
assert_missing  "~30K" "$out" K2-no-fabricated-count
unset pad

# K3 — CONTROL, "suppressed" vs "dead": the identical fixture shape UNDER the cap
# still reports its number. Without this, K1 would pass under a mutant that
# reported "MEASUREMENT FAILED" for every transcript.
{
  printf '{"type":"assistant","timestamp":"%s","message":{"usage":{"input_tokens":155000,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}\n' "$(iso_ago 0)"
  dd if=/dev/zero bs=1048576 count=2 2>/dev/null | tr '\0' 'x'
  printf '\n'
} > "$T"
out="$(run UserPromptSubmit sK3)"
assert_contains "~155K" "$out" K3-under-cap-still-measures
assert_missing  "MEASUREMENT FAILED" "$out" K3-under-cap-still-measures

# K4 — CONTROL, the other direction: a whole file read end to end with no usage
# record at all is a measurement that SUCCEEDED and found nothing. Silence is the
# right answer there, and calling it degraded would fire on every fresh session.
printf 'not json\n{"type":"user","message":{"content":"hi"}}\n' > "$T"
out="$(run UserPromptSubmit sK4)"
assert_eq "$out" "" K4-no-usage-stays-silent

# K5 — PostToolUse: once per session, and it must NOT poison the numeric band
# file. Writing a sentinel into `<session>.band` would suppress every real band at
# or below it, so a transcript that recovers (the next main-chain record lands
# inside the cap) would go quiet exactly when it regained something true to say.
{
  printf '{"type":"assistant","timestamp":"%s","message":{"usage":{"input_tokens":155000,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}\n' "$(iso_ago 0)"
  dd if=/dev/zero bs=1048576 count=17 2>/dev/null | tr '\0' 'x'
  printf '\n'
} > "$T"
out="$(run PostToolUse sK5)"
assert_contains "MEASUREMENT FAILED" "$out" K5-ptu-degraded
out="$(run PostToolUse sK5)"
assert_eq "$out" "" K5-ptu-throttled
[ -f "$TMPDIR/claude-context-watchdog/sK5.degraded" ] \
  || { echo "FAIL[K5]: degraded throttle must use its own marker file"; fail=1; }
[ -f "$TMPDIR/claude-context-watchdog/sK5.band" ] \
  && { echo "FAIL[K5]: the degraded path must not write the numeric band file"; fail=1; }
# ...and the band still fires afterwards, in the SAME session.
write_usage 155000 0 0
out="$(run PostToolUse sK5)"
assert_contains "~155K" "$out" K5-band-not-poisoned
assert_missing  "MEASUREMENT FAILED" "$out" K5-band-not-poisoned

# ---- L. a COMPLETE record sitting exactly on the cap boundary survives ----
# `const from = partial ? size - want - 1 : 0` reads one byte BEFORE the window
# on purpose, so that `lines.shift()` always drops a fragment and never a whole
# record. Every case above is blind to that byte: J only proves the window grows
# until a big record is inside it, K1/K2 expect degradation from padding and
# sidechain tails, K3 recovers on a whole-file read, K4 expects silence. Round 6
# test-quality #1 supplied the mutant — drop the `- 1` — and it survived the
# entire suite. It has to be pinned at the CAP, because below the cap the window
# doubles again and the mutant recovers on the next pass; at the cap there is no
# next pass, so a complete record beginning exactly `size - MAX_TAIL_BYTES` bytes
# from the end is discarded and the operator is told the measurement FAILED
# instead of being told the window is at 155K, i.e. URGENT.
CAP=$((16 * 1048576))
grep -q 'MAX_TAIL_BYTES = 16 \* 1_048_576' "$HOOK" \
  || { echo "FAIL[L]: hook no longer declares MAX_TAIL_BYTES = 16 * 1_048_576 — resize the L fixture to the new cap"; fail=1; }
# The fixture, byte-exact: a 7-byte prefix ending in the newline the reader is
# supposed to consume, then EXACTLY $CAP bytes whose first byte is the first byte
# of a complete main-chain usage record, then filler that parses to nothing.
L_REC="$(printf '{"type":"assistant","timestamp":"%s","message":{"usage":{"input_tokens":155000,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}' "$(iso_ago 0)")"
L_RECLEN=$(( ${#L_REC} + 1 ))
L_PADLEN=$(( CAP - L_RECLEN ))
{
  printf 'PREFIX\n'
  printf '%s\n' "$L_REC"
  head -c "$((L_PADLEN - 1))" /dev/zero | tr '\0' 'x'
  printf '\n'
} > "$T"
# Preconditions, not decoration. If either drifts the case still passes under the
# mutant it exists to catch, so both are asserted rather than assumed: the record
# must begin at EXACTLY size-CAP, and the byte before it must be the newline.
L_SIZE="$(wc -c < "$T" | tr -d ' ')"
assert_eq "$L_SIZE" "$((CAP + 7))" L-fixture-size
assert_eq "$(dd if="$T" bs=1 skip="$((L_SIZE - CAP))" count=1 2>/dev/null)" "{" L-record-on-boundary
assert_eq "$(dd if="$T" bs=1 skip="$((L_SIZE - CAP - 1))" count=1 2>/dev/null | od -An -c | tr -d ' ')" '\n' L-newline-before-boundary
out="$(run UserPromptSubmit sL1)"
assert_contains "~155K" "$out" L-boundary-record-survives
assert_missing  "MEASUREMENT FAILED" "$out" L-boundary-record-survives
assert_contains "$URGENT_CMD" "$(printf '%s' "$out" | ctx)" L-boundary-record-survives
# The case's own control: the mutant that survived round 6's suite must now die.
# It is built from the hook by substitution, so a rewrite that moves the read
# fails HERE (anchor not found) rather than silently testing nothing.
LMUT="$tmp/context-watchdog-noboundary.mjs"
sed 's/const from = partial ? size - want - 1 : 0;/const from = partial ? size - want : 0;/' "$HOOK" > "$LMUT"
if cmp -s "$HOOK" "$LMUT"; then
  echo "FAIL[L]: the boundary mutant is identical to the hook — the window read moved, and this control cannot fail"; fail=1
else
  out="$(printf '{"hook_event_name":"UserPromptSubmit","transcript_path":"%s","session_id":"sL2"}' "$T" | node "$LMUT")"
  assert_contains "MEASUREMENT FAILED" "$out" L-mutant-control
  assert_missing  "~155K" "$out" L-mutant-control
fi
rm -f "$LMUT" "$T.pad"


# ============================================================================
# HANDEDOFF — a seat that has already dispatched a successor is never told to
# dispatch another
# ============================================================================
# R8. Retirement is not instantaneous: the sentinel and the terminal state are
# written, and the stop happens in a detached child a moment later. In that gap
# the session is still taking tool calls -- including the ones the retirement
# itself provokes -- and every one of them re-enters this hook above the urgent
# threshold. Without the guard the seat is told, on its very next PostToolUse, to
# write a handoff file and dispatch a successor, and the second successor would
# duplicate work already in flight.
#
# Every case here is PAIRED with the same input minus the sentinel. A guard test
# that passes because the harness never produced the instruction in the first
# place proves nothing, and the pair is what rules that out
# ([[absence-needs-a-probe-that-could-see-presence]]).
mkdir -p "$tmp/session-state"
ho_arm()   { printf '11111111\n' > "$tmp/session-state/$1.handed-off"; }
HO_ADVICE="ALREADY handed its remaining work to a background successor"

# ---- HANDEDOFF-1/2. UserPromptSubmit, urgent band ---------------------------
write_transcript 155000
ho_arm hoA1
out="$(run UserPromptSubmit hoA1)"
assert_contains "$HO_ADVICE" "$out" HANDEDOFF-1
assert_missing  "$URGENT_CMD" "$(printf '%s' "$out" | ctx)" HANDEDOFF-1
# Not just the exact invocation: ANY mention of the launcher is an instruction to
# dispatch, however it is worded.
assert_missing  "handoff.sh" "$out" HANDEDOFF-1
assert_missing  "dispatch a fresh SESSION" "$out" HANDEDOFF-1
# The band still has to be REPORTED -- the guard suppresses the instruction, not
# the measurement, and a session that no longer knows its window is a new bug.
assert_contains "155K" "$out" HANDEDOFF-1
assert_contains "already handed off" "$out" HANDEDOFF-1   # the systemMessage half
# the control: same window, same event, no sentinel
out="$(run UserPromptSubmit hoA2)"
assert_contains "$URGENT_CMD" "$(printf '%s' "$out" | ctx)" HANDEDOFF-2
assert_missing  "$HO_ADVICE" "$out" HANDEDOFF-2

# ---- HANDEDOFF-3. UserPromptSubmit, warn band -------------------------------
write_transcript 125000
ho_arm hoB1
out="$(run UserPromptSubmit hoB1)"
assert_contains "$HO_ADVICE" "$out" HANDEDOFF-3
assert_missing  "$WARN_CMD" "$(printf '%s' "$out" | ctx)" HANDEDOFF-3
assert_missing  "handoff.sh" "$out" HANDEDOFF-3
out="$(run UserPromptSubmit hoB2)"
assert_contains "$WARN_CMD" "$(printf '%s' "$out" | ctx)" HANDEDOFF-3-control
assert_missing  "$HO_ADVICE" "$out" HANDEDOFF-3-control

# ---- HANDEDOFF-4. PostToolUse, urgent band ----------------------------------
# This is the site that actually fires during a retirement: the seat is not being
# prompted, it is running tools.
write_transcript 160000
ho_arm hoC1
out="$(run PostToolUse hoC1)"
assert_contains "$HO_ADVICE" "$out" HANDEDOFF-4
assert_missing  "handoff.sh" "$out" HANDEDOFF-4
assert_contains "already handed off" "$out" HANDEDOFF-4   # the systemMessage half
out="$(run PostToolUse hoC2)"
assert_contains "$URGENT_CMD" "$(printf '%s' "$out" | ctx)" HANDEDOFF-4-control
assert_missing  "$HO_ADVICE" "$out" HANDEDOFF-4-control

# ---- HANDEDOFF-5. PostToolUse, warn band ------------------------------------
write_transcript 125000
ho_arm hoD1
out="$(run PostToolUse hoD1)"
assert_contains "$HO_ADVICE" "$out" HANDEDOFF-5
assert_missing  "handoff.sh" "$out" HANDEDOFF-5
out="$(run PostToolUse hoD2)"
assert_contains "$WARN_CMD" "$(printf '%s' "$out" | ctx)" HANDEDOFF-5-control

# ---- HANDEDOFF-6. the sentinel is per SESSION, not a global mute ------------
# A sentinel is written for one session id. Reading the directory rather than the
# file -- or matching a prefix -- would silence every other session on the box,
# which is a far worse failure than the one being fixed.
write_transcript 155000
out="$(run UserPromptSubmit hoE-not-armed)"
assert_contains "$URGENT_CMD" "$(printf '%s' "$out" | ctx)" HANDEDOFF-6
assert_missing  "$HO_ADVICE" "$out" HANDEDOFF-6

# ---- HANDEDOFF-7. the degraded path is an instruction site too --------------
# When the window cannot be measured the hook still tells the session to hand off
# at the next boundary, launcher invocation and all -- so the guard has to reach
# that branch as well, and it is reached BEFORE the degraded early return.
{
  printf '{"type":"assistant","timestamp":"%s","message":{"usage":{"input_tokens":155000,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}\n' "$(iso_ago 0)"
  dd if=/dev/zero bs=1048576 count=17 2>/dev/null | tr '\0' 'x'
  printf '\n'
} > "$T"
ho_arm hoF1
out="$(run UserPromptSubmit hoF1)"
assert_contains "MEASUREMENT FAILED" "$out" HANDEDOFF-7   # still reports the failure...
assert_contains "$HO_ADVICE" "$out" HANDEDOFF-7           # ...with the handed-off advice
assert_missing  "handoff.sh" "$out" HANDEDOFF-7
out="$(run UserPromptSubmit hoF2)"
assert_contains "MEASUREMENT FAILED" "$out" HANDEDOFF-7-control
assert_contains "handoff.sh" "$out" HANDEDOFF-7-control
assert_missing  "$HO_ADVICE" "$out" HANDEDOFF-7-control

# ---- HANDEDOFF-8. the guard is a mute BUTTON, not a mute SWITCH -------------
# Below the warn band the hook says nothing at all, sentinel or no sentinel. A
# guard implemented as "if handed off, emit the advice" rather than "if handed
# off, substitute the advice" would start talking on every quiet tool call.
write_transcript 40000
ho_arm hoG1
assert_eq "$(run UserPromptSubmit hoG1)" "" HANDEDOFF-8
assert_eq "$(run PostToolUse hoG1)" "" HANDEDOFF-8

[ "$fail" = 0 ] && echo "PASS: context-watchdog" || exit 1
