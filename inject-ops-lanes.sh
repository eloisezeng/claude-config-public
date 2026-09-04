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

OPS_DIR="${CLAUDE_OPS_DIR:-${CLAUDE_CONFIG_DIR:-$HOME/.claude}/ops}"
[ -d "$OPS_DIR" ] || exit 0

budget=2400

# --- collect closed lane keys from lanes/*.md (read rule 1: closed-* wins) ---
closed=""
lane_meta=""   # "status|lane|objective" per line for non-closed lane files
if [ -d "$OPS_DIR/lanes" ]; then
  for f in "$OPS_DIR/lanes"/*.md; do
    [ -f "$f" ] || continue
    # Bounded read (8 KB): lanes/*.md is hand-written, so a huge file with no
    # closing --- must not stall this synchronous hook until the host timeout.
    # (The dispatch records read below stay unbounded on purpose: their sole
    # writer is rec_put, line-oriented and small by construction.)
    line="$(head -c 8192 "$f" 2>/dev/null | awk -F': *' '
      /^---$/ { fm++; next } fm >= 2 { exit }
      $1 == "lane"      { lane = $2 }
      $1 == "status"    { status = $2 }
      $1 == "objective" { obj = substr($0, index($0, ":") + 2) }
      END { printf "%s|%s|%s", status, lane, obj }
    ')" || continue
    case "$line" in
      closed-*)
        rest="${line#*|}"; key="${rest%%|*}"
        # is_closed tests token containment in a space-delimited aggregate, so
        # a hand-written lane value carrying a space ("junk HANDOFF-x junk")
        # would hide the unrelated open lane HANDOFF-x from the coordinator
        # view. Only a value in the lane-key charset may join the closed set;
        # a malformed value closes nothing (its own file stays inert — safe,
        # because a closed lane was never meant to render anyway).
        case "$key" in
          ''|*[!0-9A-Za-z._-]*) : ;;
          *) closed="$closed $key" ;;
        esac ;;
      ?*)
        lane_meta="$lane_meta$line
" ;;
    esac
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

# --- non-dispatched open lanes ---
other_lines=""
other_count=0
if [ -n "$lane_meta" ]; then
  while IFS='|' read -r st lane obj; do
    [ -n "$lane" ] || continue
    [ "${#obj}" -gt 110 ] && obj="$(clip110 "$obj")…"
    other_lines="$other_lines- $lane [$st]: $obj
"
    other_count=$((other_count + 1))
  done <<EOF
$lane_meta
EOF
fi

total=$((disp_count + other_count))
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
  [ "$disp_count" -gt 0 ] && out="${out}Dispatched ($disp_count):
$disp_lines"
  [ "$other_count" -gt 0 ] && out="${out}Not dispatched ($other_count):
$other_lines"
  out="${out}A lane is open until an explicit disposition closes it (see ~/.claude/ops/README.md); a seat dying never closes its lane.
Record any unresolved work this session discovers and is not handing forward in ~/.claude/ops/lanes/ before the window ends.
"
fi

if [ "${#out}" -gt "$budget" ]; then   # bytes, not characters — LC_ALL=C above
  out="$(printf '%s' "$out" | head -c $((budget - 80)))"
  # Trimming to the last newline already lands on a valid UTF-8 boundary (0x0A
  # is never a continuation byte); the iconv pass repairs the no-newline case.
  prev="${out%$'\n'*}"
  # Same output-judged pattern as clip110: iconv -c exits 1 on the repair it
  # got right, so keying on its exit code here kept the UNREPAIRED text.
  _r="$(printf '%s' "$prev" | iconv -f UTF-8 -t UTF-8 -c 2>/dev/null)"
  if [ -n "$_r" ]; then out="$_r"; else out="$prev"; fi
  out="$out
… (truncated — read ~/.claude/ops/ in full)"
fi

printf '%s' "$out"
exit 0
