#!/usr/bin/env bash
# Tests for hooks/compaction-recovery.mjs — plain bash, no bats dependency.
# The hook is driven through its real interface: a SessionStart hook payload on
# stdin pointing at a real transcript file, and JSON on stdout.
#
# WHAT THIS HOOK IS FOR
# ---------------------
# Measured 2026-09-14 over 5,660 automatic boundaries across both config roots:
# every compaction re-injects a MEDIAN 85,542 tokens (skills, CLAUDE.md + memory
# index, the summary itself, hook context) before the session does anything —
# about HALF the post-compaction window, whose median is 107.7K against a median
# 166K before the boundary. An earlier version of this header said ~34K; that was
# the cache_read component alone and missed roughly 52K of cache_creation. A cycle
# therefore buys a median 54K tokens, 12 minutes, 32 assistant turns and 8 tool
# calls, for a median 144-second stall.
# In the 25 assistant records following each boundary there were 2,282 Bash calls,
# 278 Reads and 138 Edits, with one source file re-read 34 times. Orientation
# reads therefore refill the window in a handful of tool calls and the session
# compacts again. The hook's job is to say so at the only moment it matters, and
# to escalate when the cycle repeats: the thresholds come from the same cadence
# measurement (median 10.0 minutes between compactions; >=3 within a 60-minute
# window held at 200 of 232 boundaries, against 1 of 232 at a 10-minute window).
set -u
HOOK="$(cd "$(dirname "$0")/.." && pwd)/hooks/compaction-recovery.mjs"
fail=0

assert_contains() { case "$2" in *"$1"*) ;; *) echo "FAIL[$3]: expected to contain: $1"; fail=1;; esac; }
assert_missing()  { case "$2" in *"$1"*) echo "FAIL[$3]: expected NOT to contain: $1"; fail=1;; *) ;; esac; }
assert_eq()       { [ "$1" = "$2" ] || { echo "FAIL[$3]: expected '$2' got '$1'"; fail=1; }; }

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
T="$tmp/transcript.jsonl"

# An ISO timestamp N minutes in the past. BSD and GNU date disagree on the flag.
iso_min_ago() { # $1 = minutes ago
  if date -u -v-1M +%FT%TZ >/dev/null 2>&1; then date -u -v-"$1"M +%FT%TZ
  else date -u -d "-$1 minutes" +%FT%TZ; fi
}
# A transcript whose compact_boundary records sit at the given minute offsets.
# Each boundary is followed by the summary record and an ordinary assistant turn,
# so the parser is never handed a file of nothing but markers.
write_boundaries() { # $@ = minutes ago, oldest first
  : > "$T"
  for m in "$@"; do
    printf '{"type":"system","subtype":"compact_boundary","timestamp":"%s"}\n' "$(iso_min_ago "$m")" >> "$T"
    printf '{"type":"user","isCompactSummary":true,"timestamp":"%s","message":{"content":"summary"}}\n' "$(iso_min_ago "$m")" >> "$T"
    printf '{"type":"assistant","timestamp":"%s","message":{"content":"work"}}\n' "$(iso_min_ago "$m")" >> "$T"
  done
}
run() { # $1 = source, $2 = transcript path (may be empty), [$3 = hook path]
  local h="${3:-$HOOK}"
  if [ -n "$2" ]; then
    printf '{"hook_event_name":"SessionStart","source":"%s","transcript_path":"%s","session_id":"s1"}' "$1" "$2" | node "$h"
  else
    printf '{"hook_event_name":"SessionStart","source":"%s","session_id":"s1"}' "$1" | node "$h"
  fi
}
ctx() { jq -r '.hookSpecificOutput.additionalContext // ""'; }
sysmsg() { jq -r '.systemMessage // ""'; }

# ---- A. every source but `compact` is silent -------------------------------
# A SessionStart hook group with no `matcher` fires on startup, resume, clear AND
# compact. This hook gates on `source` itself rather than on a matcher, because a
# matcher that is not honoured as expected would silence it entirely, and silence
# is the failure that cannot be noticed.
write_boundaries 5 3 1
for s in startup resume clear; do
  assert_eq "$(run "$s" "$T")" "" "A-$s"
done

# ---- B. tier 1: one compaction, the protocol, no interruption --------------
write_boundaries 5
out="$(run compact "$T")"
c="$(printf '%s' "$out" | ctx)"
assert_contains "[compaction-recovery tier 1]" "$c" B
assert_contains "The summary above IS the durable state of the work" "$c" B
assert_contains "Never re-read a whole file" "$c" B
assert_contains "Freshness checks survive, but BOUNDED" "$c" B
assert_contains "not an orientation pass" "$c" B
# The user 2026-09-15: a handoff is preferable even on the FIRST compaction where the
# state of the work is already durable on disk. Tier 1 must say so, and must not read
# as "compaction is always the right answer".
assert_contains "One compaction is normal and is not a failure" "$c" B-normal
assert_contains "already durable on disk" "$c" B-durable-state-clause
assert_contains "PREFERABLE to continuing here" "$c" B-handoff-preferable
# tier 1 is the normal case, so it must not interrupt her with a system message
assert_eq "$(printf '%s' "$out" | sysmsg)" "" B-no-systemMessage

# ---- C. tier 2: the second compaction inside the hour forbids recovery reads
write_boundaries 20 2
out="$(run compact "$T")"
c="$(printf '%s' "$out" | ctx)"
assert_contains "[compaction-recovery tier 2]" "$c" C
assert_contains "CIRCUIT BREAKER, TIER 2" "$c" C
assert_contains "Recovery reads are now FORBIDDEN" "$c" C
assert_contains "compacted 2 times in the last hour" "$c" C
assert_contains "second compaction within the hour" "$(printf '%s' "$out" | sysmsg)" C-systemMessage
# The user 2026-09-15: a second automatic compaction inside 60 minutes means CHECKPOINT
# AND HAND OFF. Before that decision tier 2 only forbade recovery reads, which left a
# thrashing session reading less while still riding the same window down.
assert_contains "CHECKPOINT AND HAND OFF" "$c" C-checkpoint-and-hand-off
assert_contains "handoff.sh" "$c" C-names-the-launcher
assert_contains "hand the remainder to a fresh" "$c" C-hands-off
assert_contains "checkpoint durable state and hand off" "$(printf '%s' "$out" | sysmsg)" C-systemMessage-says-handoff
# The predicate is the recurrence COUNT alone. The user declined a projected tool-call
# threshold on 2026-09-15 because tasks vary too much in how many calls they need, so
# no tier may gate its instruction on one.
assert_missing "projected tool calls" "$c" C-no-tool-call-gate

# ---- D. tier 3: the third stops context expansion and checkpoints ----------
write_boundaries 40 20 2
out="$(run compact "$T")"
c="$(printf '%s' "$out" | ctx)"
assert_contains "[compaction-recovery tier 3]" "$c" D
assert_contains "CIRCUIT BREAKER, TIER 3" "$c" D
assert_contains "STOP EXPANDING CONTEXT NOW" "$c" D
assert_contains "~/.claude/ops/" "$c" D
assert_contains "context is thrashing" "$(printf '%s' "$out" | sysmsg)" D-systemMessage
# The user 2026-09-15: tier 3 is an UNCONDITIONAL handoff. The previous wording offered
# "either hand off, or tell the user the task does not fit", which a session could read
# as permission to do neither.
assert_contains "UNCONDITIONAL at this tier" "$c" D-unconditional
assert_contains "not one of two options" "$c" D-not-an-option
assert_missing "then either hand the remainder" "$c" D-no-optional-phrasing

# ---- E. the window is trailing, not cumulative -----------------------------
# Three boundaries 90 minutes old plus one now is a session that compacted a lot
# this morning and once just now; that is tier 1, not tier 3. Without this the
# breaker would latch for the rest of a long session and stop advising entirely.
write_boundaries 95 93 91 1
out="$(run compact "$T")"
assert_contains "[compaction-recovery tier 1]" "$(printf '%s' "$out" | ctx)" E

# ---- E2. mutant control: E is what pins the window -------------------------
# E passing is only evidence if a hook that ignored the 60-minute window would
# fail it. The window is widened on a COPY under $tmp — never on the tracked
# file, which this repo auto-commits every minute and publishes.
mut="$tmp/compaction-recovery-nowindow.mjs"
sed 's/^const WINDOW_MS = .*$/const WINDOW_MS = 365 * 24 * 60 * 60 * 1000;/' "$HOOK" > "$mut"
grep -q 'const WINDOW_MS = 365' "$mut" || { echo "FAIL[E2]: the mutation did not apply -- this control proves nothing"; fail=1; }
out="$(run compact "$T" "$mut")"
assert_contains "[compaction-recovery tier 3]" "$(printf '%s' "$out" | ctx)" E2-mutant-counts-everything
grep -q '^const WINDOW_MS = 60 \* 60 \* 1000;$' "$HOOK" || { echo "FAIL[E2]: the TRACKED hook was mutated"; fail=1; }

# ---- F. an unreadable transcript defaults to tier 1, never to a breaker ----
# An unreadable transcript must not silently escalate a session into "stop
# working". The protocol is the part that always applies; the tiers are an
# escalation on top of a measurement, so a missing measurement means no
# escalation rather than the strictest one.
out="$(run compact "$tmp/does-not-exist.jsonl")"
assert_contains "[compaction-recovery tier 1]" "$(printf '%s' "$out" | ctx)" F-missing-file
out="$(run compact "")"
assert_contains "[compaction-recovery tier 1]" "$(printf '%s' "$out" | ctx)" F-no-path

# ---- G. a hook may never break a session -----------------------------------
# Malformed stdin, a payload that is not an object, and an empty stdin all have
# to leave exit 0 and no output. A hook that throws here costs the session.
for bad in 'not json at all' '[]' 'null' ''; do
  out="$(printf '%s' "$bad" | node "$HOOK" 2>"$tmp/err")"; rc=$?
  assert_eq "$rc" "0" "G-exit-status"
  assert_eq "$out" "" "G-output"
  assert_eq "$(wc -c < "$tmp/err" | tr -d ' ')" "0" "G-stderr"
done

# ---- H. a boundary record that is not a boundary is not counted ------------
# The scan pre-filters on the literal string "compact_boundary" for speed, so a
# record merely MENTIONING it (an assistant turn discussing this very hook, which
# is a real transcript in this repo) must be rejected by the subtype check.
: > "$T"
printf '{"type":"system","subtype":"compact_boundary","timestamp":"%s"}\n' "$(iso_min_ago 5)" >> "$T"
for i in 1 2 3; do
  printf '{"type":"assistant","timestamp":"%s","message":{"content":"the subtype is compact_boundary"}}\n' "$(iso_min_ago 4)" >> "$T"
done
assert_contains "[compaction-recovery tier 1]" "$(run compact "$T" | ctx)" H

# ---- I. the tracked tree is unchanged by this suite ------------------------
# Every mutation above was written to $tmp. This repo auto-commits every minute,
# so a fault armed in place would be committed and published before anyone saw it.
if git -C "$(dirname "$HOOK")/.." status --porcelain -- hooks/compaction-recovery.mjs | grep -q .; then
  echo "FAIL[I]: the suite left hooks/compaction-recovery.mjs modified"; fail=1
fi

[ "$fail" = 0 ] && echo "PASS: compaction-recovery" || exit 1
