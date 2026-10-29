#!/bin/bash
# inject-ops-lanes.sh — SessionStart hook: surface the open operational lanes
# from the ledger at ~/.claude/ops/ (see its README.md; decision record
# LIFECYCLE-DECISION-context-vs-handoff-2026-08-31.md).
#
# Locality rule (the point of this file): a WORKER — a seat dispatched by
# handoff.sh, identified by CLAUDE_HANDOFF_LANE in its environment — sees its
# OWN lane plus a count of the others, never the full queue. Everything else
# (a coordinator, an interactive session) sees the compact open set, so a
# coordinator death is recoverable from any fresh session.
#
# The lane marker is a FILTER HINT, never authority: ownership authority is the
# dispatch record's session_id. A seat that inherited a stale marker (a plain
# `claude --bg` child of a worker inherits the parent's env) just gets the
# narrower view, which is safe — narrower is never lost, because the ledger
# itself is on disk either way.
#
# bash on purpose (hook PATH may not carry node); must NEVER break a session:
# any failure → exit 0 with no output. Budgeted output; sentence-per-line.

set -u

# Byte-math on purpose: the output contract (the $budget below) is BYTES, and
# in a UTF-8 locale ${#var} counts CHARACTERS while head -c counts bytes — an
# objective of 110 four-byte code points would pass a character test at 4× its
# byte allowance. LC_ALL=C makes ${#} and printf's %.Ns precision count bytes
# too; any byte clip can then land mid-code-point, so every clipped string is
# repaired to valid UTF-8 with iconv -c (drops the partial trailing sequence)
# before the ellipsis is appended. iconv missing or emitting nothing falls back
# to the unrepaired clip — worse rendering, never a broken session.
LC_ALL=C
export LC_ALL
clip110() { # $1=string → stdout: its first ≤110 bytes, repaired to valid UTF-8
  # Success is judged by OUTPUT, never exit code: iconv -c on this platform
  # exits 1 while emitting the correct repair (measured: a 110-byte
  # boundary-cut clip → rc=1 with the valid 108-byte repair on stdout), so an
  # `||` fallback here ran BOTH commands and emitted repair + raw clip —
  # doubling the line and re-introducing the invalid bytes (IL-12 caught it).
  _r="$(printf '%.110s' "$1" | iconv -f UTF-8 -t UTF-8 -c 2>/dev/null)"
  if [ -n "$_r" ]; then printf '%s' "$_r"; else printf '%.110s' "$1"; fi
}

# The rule for which lane statuses mean CLOSED, and the reader of a lanes/*.md
# front matter, are SOURCED and never reimplemented here: hooks/handoff.sh asks
# the same question at close time, and two copies of it drift in the one
# direction no diff can show — a status one of them calls closed and the other
# calls open leaves a lane either reported twice or dropped by everybody.
#
# Unreadable means this hook STOPS — a listing built on a guessed rule is worse
# than none, because it reads exactly like the ledger — but it stops with ONE
# LINE saying so rather than in silence. Silence here is indistinguishable from
# an empty ledger, which is the one message that must never be sent by accident:
# a session told there is no open work stops looking for any.
LIB="$(cd "$(dirname "$0")" 2>/dev/null && pwd -P)/hooks/lib/lane-status.sh"
if [ ! -r "$LIB" ] || ! . "$LIB" 2>/dev/null; then
  printf '# Operational ledger (~/.claude/ops/) — NOT READ: hooks/lib/lane-status.sh is missing beside %s, so which lanes are closed could not be established. Read ~/.claude/ops/ by hand; do not read this as "no open lanes".\n' "$0"
  exit 0
fi

OPS_DIR="${CLAUDE_OPS_DIR:-${CLAUDE_CONFIG_DIR:-$HOME/.claude}/ops}"
[ -d "$OPS_DIR" ] || exit 0

budget=2400

# --- read every lane FILE once --------------------------------------------
# Two things come out of it: the keys that closed lanes CLOSE (read rule 1 of
# the ledger — a lanes/-file disposition outranks a dispatches/ symlink nobody
# has cleaned up yet), and the OPEN ones, which are the lanes with no session on
# them at all.
#
# Closed lanes are no longer listed. They used to be: the reader knew only
# `closed-*`, so `completed`, `superseded` and every `completed — <prose>` tail
# counted as open work, and 19 of the 42 rows a session was shown at startup
# were lanes already disposed of (measured 2026-10-04 over 95 lane files). A
# listing that mixes 19 finished rows into 42 is a listing nobody reads, which
# is how a genuinely stranded lane sat in it unnoticed for a day.
closed=""
nosession_lines=""
nosession_count=0
unlisted_count=0
if [ -d "$OPS_DIR/lanes" ]; then
  for f in "$OPS_DIR/lanes"/*.md; do
    [ -f "$f" ] || continue
    # Bounded read (8 KB): lanes/*.md is hand-written, so a huge file with no
    # closing --- must not stall this synchronous hook until the host timeout.
    # (The dispatch records read below stay unbounded on purpose: their sole
    # writer is rec_put, line-oriented and small by construction.)
    lane_file_read "$f" 8192 || continue
    if lane_status_is_closed "$LANE_FM_STATUS"; then
      # is_closed tests token containment in a space-delimited aggregate, so a
      # hand-written lane value carrying a space ("junk HANDOFF-x junk") would
      # hide the unrelated open lane HANDOFF-x from the coordinator view. Only
      # a value in the lane-key charset may join the closed set; a malformed
      # value closes nothing (its own file stays inert — safe, because a closed
      # lane was never meant to render anyway).
      case "$LANE_FM_LANE" in
        ''|*[!0-9A-Za-z._-]*) : ;;
        *) closed="$closed $LANE_FM_LANE" ;;
      esac
      continue
    fi
    # A file with no `lane:` line has no name to list it under, so it is COUNTED
    # rather than dropped: a file in lanes/ that this listing cannot show is
    # still somebody's open work, and the count is the only sign of it here.
    [ -n "$LANE_FM_LANE" ] || { unlisted_count=$((unlisted_count + 1)); continue; }
    obj="$LANE_FM_OBJECTIVE"
    [ "${#obj}" -gt 110 ] && obj="$(clip110 "$obj")…"
    # Only the status's FIRST TOKEN is printed. The tail a lane file's status
    # routinely carries ("completed — PR #67 merged as 6891e31 on 2026-09-24")
    # is a human's note rather than the state, and the state is what a reader
    # scanning this section is looking for.
    nosession_lines="$nosession_lines- $LANE_FM_LANE [$(lane_status_shown)]: $obj
"
    nosession_count=$((nosession_count + 1))
  done
fi
is_closed() { case " $closed " in *" $1 "*) return 0 ;; esac; return 1; }

# --- collect open dispatched lanes from dispatches/ symlinks ---
disp_lines=""
disp_count=0
if [ -d "$OPS_DIR/dispatches" ]; then
  for l in "$OPS_DIR/dispatches"/*; do
    [ -L "$l" ] || continue
    key="${l##*/}"
    is_closed "$key" && continue
    rec="$(readlink "$l" 2>/dev/null)" || rec=""
    if [ -n "$rec" ] && [ -f "$rec" ]; then
      row="$(awk -F= '
        $1 == "session_id" { sid = $2 }
        $1 == "objective"  { obj = substr($0, 11) }
        $1 == "state"      { st = $2 }
        END { printf "%s|%s|%s", sid, st, obj }
      ' "$rec" 2>/dev/null)" || row="||"
      sid="${row%%|*}"; rest="${row#*|}"; st="${rest%%|*}"; obj="${rest#*|}"
      [ "${#obj}" -gt 110 ] && obj="$(clip110 "$obj")…"
      disp_lines="$disp_lines- $key (seat ${sid:-unrecorded}, $st): $obj
"
    else
      disp_lines="$disp_lines- $key: RECORD MISSING (dangling link — investigate, do not delete)
"
    fi
    disp_count=$((disp_count + 1))
  done
fi

total=$((disp_count + nosession_count))
[ "$total" -gt 0 ] || exit 0

mylane="${CLAUDE_HANDOFF_LANE:-}"

if [ -n "$mylane" ]; then
  # Worker view: own lane + a count. The full queue is deliberately not shown.
  out="# Operational ledger (~/.claude/ops/) — worker view
"
  link="$OPS_DIR/dispatches/$mylane"
  if [ -L "$link" ]; then
    rec="$(readlink "$link" 2>/dev/null)" || rec=""
    obj=""
    [ -n "$rec" ] && [ -f "$rec" ] && obj="$(awk -F= '$1=="objective"{o=substr($0,11)} END{print o}' "$rec" 2>/dev/null)"
    out="${out}Your lane: $mylane — ${obj:-objective unreadable}.
Your session ending does not close this lane: when the objective is COMPLETE (or cancelled/superseded), run \`~/dotfiles/claude/hooks/handoff.sh --close $mylane completed\` (or cancelled/superseded) with a one-line note; handing off onward with handoff.sh moves it automatically.
"
  else
    out="${out}Your environment names lane $mylane, but it is not in the open dispatched set (already closed, or registered before this ledger existed).
"
  fi
  others=$((total))
  [ -L "$link" ] && ! is_closed "$mylane" && others=$((total - 1))
  out="${out}Other open lanes: $others (ledger at ~/.claude/ops/ — leave them to their owners; record any NEW unresolved work you discover in ~/.claude/ops/lanes/ before your window ends).
"
else
  out="# Operational ledger (~/.claude/ops/) — open lanes
"
  # OPEN WITH NO SESSION ON IT COMES FIRST, because it is the only section that
  # names work nobody is doing. A dispatched lane has a seat and a watchdog; one
  # of these has neither. The lane that went unnoticed sat in this section,
  # under a heading that said only that it was "not dispatched", behind the
  # lanes that were already being worked on.
  [ "$unlisted_count" -gt 0 ] && out="${out}NOT listed below: $unlisted_count file(s) in ~/.claude/ops/lanes/ have no \`lane:\` front matter line, so they cannot be named here — read them.
"
  [ "$nosession_count" -gt 0 ] && out="${out}Open, no session on it ($nosession_count) — nobody is doing this work:
$nosession_lines"
  [ "$disp_count" -gt 0 ] && out="${out}Dispatched ($disp_count):
$disp_lines"
  out="${out}A lane is open until an explicit disposition closes it (see ~/.claude/ops/README.md); a seat dying never closes its lane.
Record any unresolved work this session discovers and is not handing forward in ~/.claude/ops/lanes/ before the window ends.
"
fi

# rows() counts the lane rows in a rendered block. Every one begins with "- " at
# the start of a line, which is the shape both section builders above emit; and
# `grep -c` is judged by its OUTPUT, because it prints 0 and exits 1 when it
# matches nothing, which here is an ordinary answer and not a failure.
rows() {
  _rn="$(printf '%s' "$1" | grep -c '^- ' 2>/dev/null || true)"
  printf '%s' "${_rn:-0}" | tr -d '[:space:]'
}

if [ "${#out}" -gt "$budget" ]; then   # bytes, not characters — LC_ALL=C above
  rows_before="$(rows "$out")"
  out="$(printf '%s' "$out" | head -c $((budget - 130)))"
  # Trimming to the last newline already lands on a valid UTF-8 boundary (0x0A
  # is never a continuation byte); the iconv pass repairs the no-newline case.
  prev="${out%$'\n'*}"
  # Same output-judged pattern as clip110: iconv -c exits 1 on the repair it
  # got right, so keying on its exit code here kept the UNREPAIRED text.
  _r="$(printf '%s' "$prev" | iconv -f UTF-8 -t UTF-8 -c 2>/dev/null)"
  if [ -n "$_r" ]; then out="$_r"; else out="$prev"; fi
  # THE CAP NAMES WHAT IT DROPPED. A cap that truncates in silence reads exactly
  # like a ledger with nothing more in it, so a reader who should open the full
  # thing has no reason to. The count is the whole signal: "19 of 46 lane rows
  # are NOT shown" is a reason to go and look, and "truncated" is not.
  out="$out
… truncated: $(( rows_before - $(rows "$out") )) of $rows_before lane rows are NOT shown — read ~/.claude/ops/ in full"
fi

printf '%s' "$out"
exit 0
