#!/usr/bin/env bash
# lane-status.sh — the ONE place that knows when an operational lane is CLOSED,
# and the ONE reader of a lanes/*.md front matter. Sourced, never executed.
#
# WHY THIS EXISTS. "Which statuses mean closed?" is a value that has to agree
# across files: `hooks/handoff.sh` asks it at close time to find open work
# nobody is on, and `inject-ops-lanes.sh` asks it to decide what a session is
# shown at startup. Written down twice it drifts, and the drift is invisible in
# exactly the direction that matters — a status one file calls closed and the
# other calls open makes a lane either reported twice or silently dropped, and
# no diff can answer which. (Measured 2026-10-04 over the 95 lane files on this
# machine: 23 `open`, and 19 closed in SIX different spellings — `completed`,
# `superseded`, `closed — completed <date>` and four `completed — <prose>`
# tails. The reader that knew only `closed-*` counted all 19 as open work.)
#
# THE RULE: the status's FIRST WHITESPACE-DELIMITED TOKEN decides. Lane files
# are hand-written and their status lines routinely carry a prose tail naming
# the pull request, the deploy and the date — that tail is a human's note, not
# part of the state, so matching the whole value would make the state unreadable
# the moment somebody annotated it. `closed-*` is kept because the ledger's own
# read rule used it and files on disk still spell it that way.
#
# Anything NOT in the set is OPEN, including a status nobody has seen before.
# That direction is deliberate: an unrecognised status surfaces as open work in
# front of a human, while the other direction hides a lane from everyone.
LANE_CLOSED_FIRST_TOKENS=" closed completed cancelled canceled superseded abandoned "

# lane_status_is_closed <status value, prose tail and all> -> 0 when closed
lane_status_is_closed() {
  _lsc="${1%%[[:space:]]*}"
  [ -n "$_lsc" ] || return 1
  case "$_lsc" in
    closed-*) return 0 ;;
  esac
  case "$LANE_CLOSED_FIRST_TOKENS" in
    *" $_lsc "*) return 0 ;;
  esac
  return 1
}

# lane_file_read <lanes/*.md path> <max bytes to read> — parse the front matter.
# Sets LANE_FM_STATUS, LANE_FM_LANE, LANE_FM_OBJECTIVE, LANE_FM_POINTER and
# LANE_FM_HAS_STATUS; returns 1 when the file could not be read at all, which a
# caller must not read as an empty front matter.
#
# LANE_FM_HAS_STATUS is 1 only when the front matter carries a `status:` line.
# The field has ONE spelling. A file that writes it some other way (`state:` is
# the one hand-writers reach for) has no status this reader can see, and an
# empty status is OPEN by the rule above — so `state: completed` was listed as
# open work forever, with a blank where the status prints and nothing saying
# why. (Measured 2026-10-11 over 102 lane files: 62 `status:`, 31 `state:`, 9
# of those 31 finished.) The second spelling is deliberately NOT accepted:
# accepting it keeps two spellings alive, and the writer below only knows one.
# A caller that prints a row says LANE_NO_STATUS_LABEL in the status's place,
# so the missing line is a complaint somebody reads rather than a blank.
LANE_NO_STATUS_LABEL="NO-STATUS-LINE"
#
# THE READ IS BOUNDED, and the bound is the CALLER's, because the two callers
# pay for it differently: a synchronous SessionStart hook must not stall a
# session on a hand-written file with no closing `---`, while a close-time scan
# can afford more. A lane file is prose with a front matter on top, so a bound
# is generous for the fields and strict about the stall.
lane_file_read() {
  LANE_FM_STATUS=""; LANE_FM_LANE=""; LANE_FM_OBJECTIVE=""; LANE_FM_POINTER=""
  LANE_FM_HAS_STATUS=0
  [ -f "$1" ] && [ -r "$1" ] || return 1
  # TAB-separated, because every field here is free-form text: `status` carries
  # a prose tail with em dashes and parentheses, `objective` is a sentence and
  # `pointer` is a path. `|` is the one delimiter an operator has actually typed
  # into these files, which is how a hand-written `lane: junk X junk` once hid
  # an unrelated lane from the startup listing.
  _lfr="$(head -c "$2" "$1" 2>/dev/null | awk '
    function val(s) { sub(/^[^:]*:[[:blank:]]*/, "", s); return s }
    /^---$/ { fm++; next }
    fm >= 2 { exit }
    /^lane:/      { lane = val($0) }
    /^status:/    { status = val($0); has = 1 }
    /^pointer:/   { ptr = val($0) }
    /^objective:/ { obj = val($0) }
    END { printf "%d\t%s\t%s\t%s\t%s", has, status, lane, ptr, obj }
  ')" || return 1
  LANE_FM_HAS_STATUS="${_lfr%%$'\t'*}"; _lfr="${_lfr#*$'\t'}"
  LANE_FM_STATUS="${_lfr%%$'\t'*}";  _lfr="${_lfr#*$'\t'}"
  LANE_FM_LANE="${_lfr%%$'\t'*}";    _lfr="${_lfr#*$'\t'}"
  LANE_FM_POINTER="${_lfr%%$'\t'*}"; _lfr="${_lfr#*$'\t'}"
  LANE_FM_OBJECTIVE="$_lfr"
  return 0
}

# lane_status_shown — the word a listing prints for the lane just read: the
# status's first token, or LANE_NO_STATUS_LABEL when the file has no `status:`
# line at all. One function, so the two listings cannot print the gap two ways.
lane_status_shown() {
  if [ "$LANE_FM_HAS_STATUS" = 1 ]; then printf '%s' "${LANE_FM_STATUS%%[[:space:]]*}"
  else printf '%s' "$LANE_NO_STATUS_LABEL"; fi
}

# lane_file_set_status <lanes/*.md path> <status value> — the ONE writer of a
# lane file's status. Replaces the first `status:` line of the front matter, or
# adds one directly under `lane:` when the file has none. Returns 1, leaving
# the file untouched, when the file has no front matter carrying a `lane:` line
# (it is then not a lane file, and this must not turn it into one) or when the
# rewrite could not be written.
#
# WHY THIS EXISTS. A dispatched lane's state lives in two places: its dispatch
# record, which `handoff.sh --close` writes, and the front matter of its own
# file, which the listings read. Closing wrote only the first, so a lane closed
# correctly went on being listed as open work by its own file. Two effects that
# have to happen together are one call; this is the second one.
#
# The whole file is rewritten through a temporary beside it and renamed, so a
# reader never sees half a file. The value is one line by construction: a value
# spanning lines could forge another field.
lane_file_set_status() {
  [ -f "$1" ] && [ -w "$1" ] || return 1
  case "$2" in *'
'*) return 1 ;; esac
  _lss_tmp="$1.status.$$"
  LANE_SET_STATUS="$2" awk '
    BEGIN { v = ENVIRON["LANE_SET_STATUS"] }
    done || fm >= 2 { print; next }
    /^---$/ {
      fm++
      # a front matter that closes with a lane but no status gets one here
      if (fm == 2 && lane && !done) { print "status: " v; done = 1 }
      print; next
    }
    fm == 1 && /^lane:/ { lane = 1; print; next }
    fm == 1 && /^status:/ { print "status: " v; done = 1; next }
    { print }
    END { exit((done && lane) ? 0 : 1) }
  ' "$1" > "$_lss_tmp" 2>/dev/null || { rm -f "$_lss_tmp"; return 1; }
  mv -f "$_lss_tmp" "$1" 2>/dev/null || { rm -f "$_lss_tmp"; return 1; }
  return 0
}
