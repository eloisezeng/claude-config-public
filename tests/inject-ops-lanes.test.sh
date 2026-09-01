#!/bin/bash
# inject-ops-lanes.test.sh — the SessionStart ledger view (2026-08-31 decision).
#
# The hook has one hard rule (it must NEVER break a session: any failure is
# exit 0 with no output) and one design rule (worker locality: a seat carrying
# CLAUDE_HANDOFF_LANE sees its OWN lane plus a count, never the full queue).
# Every case below asserts through the hook's stdout, because stdout is the
# only artifact a session ever sees.
set -u

SCRIPT="$(cd "$(dirname "$0")/.." && pwd)/inject-ops-lanes.sh"
[ -f "$SCRIPT" ] || { echo "FAIL[IL]: no hook at $SCRIPT"; exit 1; }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
fail=0

assert_contains() { case "$2" in *"$1"*) ;; *) echo "FAIL[$3]: expected to contain: $1 -- got: $2"; fail=1 ;; esac; }
assert_missing()  { case "$2" in *"$1"*) echo "FAIL[$3]: expected NOT to contain: $1 -- got: $2"; fail=1 ;; esac; }
assert_eq()       { [ "$1" = "$2" ] || { echo "FAIL[$3]: expected '$2' got '$1'"; fail=1; }; }

# The hook resolves the ledger from CLAUDE_OPS_DIR first; without this every
# case below would read the REAL ~/.claude/ops of whoever runs the suite.
export CLAUDE_OPS_DIR="$tmp/ops"
unset CLAUDE_HANDOFF_LANE 2>/dev/null

RUN() { out="$(bash "$SCRIPT" 2>&1)"; rc=$?; }

# ---- IL-1. no ledger at all -> silent success ------------------------------
RUN
assert_eq "$rc" "0" IL-1
assert_eq "$out" "" IL-1

# ---- IL-2. an empty ledger -> silent success --------------------------------
mkdir -p "$tmp/ops/dispatches" "$tmp/ops/lanes"
RUN
assert_eq "$rc" "0" IL-2
assert_eq "$out" "" IL-2

# ---- fixtures for the populated cases ---------------------------------------
mkdir -p "$tmp/records"
printf 'session_id=aaaa1111\nstate=verified\nobjective=fix the flux capacitor end to end\n' > "$tmp/records/one.dispatch"
printf 'session_id=bbbb2222\nstate=launching\nobjective=rebuild the index\n' > "$tmp/records/two.dispatch"
ln -sfn "$tmp/records/one.dispatch" "$tmp/ops/dispatches/HANDOFF-flux-11111111"
ln -sfn "$tmp/records/two.dispatch" "$tmp/ops/dispatches/HANDOFF-index-22222222"
cat > "$tmp/ops/lanes/loose-item.md" <<'EOF'
---
lane: loose-item
status: blocked-on-user
objective: waiting on a decision only the operator can make
---
Body text the hook must never print.
EOF

# ---- IL-3. coordinator view: both sections, counts, plain objectives --------
RUN
assert_eq "$rc" "0" IL-3
assert_contains "Dispatched (2):" "$out" IL-3
assert_contains "HANDOFF-flux-11111111 (seat aaaa1111, verified): fix the flux capacitor" "$out" IL-3
assert_contains "Not dispatched (1):" "$out" IL-3
assert_contains "loose-item [blocked-on-user]: waiting on a decision" "$out" IL-3
assert_contains "a seat dying never closes its lane" "$out" IL-3
assert_missing "Body text the hook must never print" "$out" IL-3

# ---- IL-4. a closed-* lanes file hides its dispatched key --------------------
# Read rule 1 of the ledger: a lanes/-file disposition outranks a symlink that
# has not been cleaned up yet.
cat > "$tmp/ops/lanes/flux-closed.md" <<'EOF'
---
lane: HANDOFF-flux-11111111
status: closed-completed
objective: fix the flux capacitor end to end
---
EOF
RUN
assert_eq "$rc" "0" IL-4
assert_contains "Dispatched (1):" "$out" IL-4
assert_missing "HANDOFF-flux-11111111" "$out" IL-4
rm -f "$tmp/ops/lanes/flux-closed.md"

# ---- IL-5. worker view: own lane, the close command, and ONLY a count -------
CLAUDE_HANDOFF_LANE="HANDOFF-flux-11111111" RUN
assert_eq "$rc" "0" IL-5
assert_contains "worker view" "$out" IL-5
assert_contains "Your lane: HANDOFF-flux-11111111 — fix the flux capacitor end to end" "$out" IL-5
assert_contains "--close HANDOFF-flux-11111111 completed" "$out" IL-5
assert_contains "Other open lanes: 2" "$out" IL-5
# locality: the other lanes' names and objectives must NOT reach the worker
assert_missing "HANDOFF-index-22222222" "$out" IL-5
assert_missing "rebuild the index" "$out" IL-5
assert_missing "loose-item" "$out" IL-5

# ---- IL-6. worker with a stale marker: named as such, never a crash ---------
CLAUDE_HANDOFF_LANE="HANDOFF-gone-99999999" RUN
assert_eq "$rc" "0" IL-6
assert_contains "not in the open dispatched set" "$out" IL-6
assert_contains "Other open lanes: 3" "$out" IL-6

# ---- IL-7. a dangling dispatch link is surfaced, not swallowed --------------
ln -sfn "$tmp/records/never-written.dispatch" "$tmp/ops/dispatches/HANDOFF-dangle-33333333"
RUN
assert_eq "$rc" "0" IL-7
assert_contains "HANDOFF-dangle-33333333: RECORD MISSING" "$out" IL-7
assert_contains "investigate, do not delete" "$out" IL-7
# F11 of the 2026-08-31 review: checking the warning TEXT alone passes a mutant
# that reports the dangling lane and then deletes it — an open lane vanishing
# without a disposition, the exact loss the ledger exists to prevent. The link
# must survive the hook; only the test cleans it up.
[ -L "$tmp/ops/dispatches/HANDOFF-dangle-33333333" ] || { echo "FAIL[IL-7]: the hook deleted the dangling lane link it reported"; fail=1; }
rm -f "$tmp/ops/dispatches/HANDOFF-dangle-33333333"

# ---- IL-8. the budget: many lanes truncate to the cap, with a pointer -------
i=0
while [ "$i" -lt 60 ]; do
  printf 'session_id=cc%06d\nstate=verified\nobjective=a long objective line that pads the output toward the budget %06d\n' "$i" "$i" > "$tmp/records/bulk$i.dispatch"
  ln -sfn "$tmp/records/bulk$i.dispatch" "$tmp/ops/dispatches/HANDOFF-bulk$i-4444444$i"
  i=$((i + 1))
done
RUN
assert_eq "$rc" "0" IL-8
# F7 of the 2026-08-31 review: the budget is BYTES, and ${#out} in this test
# shell counts characters in a UTF-8 locale — the same mistake the hook made.
# Measure with wc -c so a multibyte over-budget output cannot read green.
outbytes="$(printf '%s' "$out" | wc -c | tr -d ' ')"
[ "$outbytes" -le 2400 ] || { echo "FAIL[IL-8]: output is $outbytes BYTES, over the 2400 budget"; fail=1; }
assert_contains "truncated — read ~/.claude/ops/ in full" "$out" IL-8

# ---- IL-9. a long objective is clipped per line, not passed through ---------
rm -f "$tmp/ops/dispatches"/HANDOFF-bulk*
long="$(printf 'x%.0s' $(seq 1 200))"
printf 'session_id=dddd4444\nstate=verified\nobjective=%s\n' "$long" > "$tmp/records/long.dispatch"
ln -sfn "$tmp/records/long.dispatch" "$tmp/ops/dispatches/HANDOFF-long-55555555"
RUN
assert_eq "$rc" "0" IL-9
assert_missing "$long" "$out" IL-9
assert_contains "…" "$out" IL-9

# ---- IL-10. the lane-file read is BOUNDED at exactly 8192 bytes -------------
# F5 of the 2026-08-31 review: lanes/*.md is hand-written, so a huge file with
# no closing --- must not stall this synchronous SessionStart hook until the
# host timeout. A wall-clock assertion would measure the machine, so the bound
# is pinned by OUTCOME at its exact boundary — a far-out marker plus a near-in
# control proves only that SOME bound exists (a `head -c 64` mutant passed
# both). The byte that decides is the HYPHEN completing "closed-", not the
# line's newline: awk parses the final unterminated line as a record, and
# is_closed's closed-* glob needs only that 7-byte prefix — a first rebuild
# that put the newline at 8192 and the line START at 8193 left every bound in
# [8182, 8206] alive (round-2 micro-review; 8191- and 8193-byte mutants
# measured surviving). So: the included side's hyphen lands AT byte 8192 (any
# smaller bound cuts it — no match, lane stays open, its assert fails) and the
# excluded side's hyphen at byte 8193 (any larger bound completes it — lane
# closes, its assert fails). The surviving set is exactly {8192}.
il10_pad() { # $1=file  $2=exact byte size the content must reach
  _p=$(( $2 - $(wc -c < "$1") - 4 ))
  { printf 'p: '; head -c "$_p" /dev/zero | tr '\0' 'x'; printf '\n'; } >> "$1"
}
IL10_F="$tmp/ops/lanes/hyphen-past-the-bound.md"
printf -- '---\nlane: HANDOFF-flux-11111111\n' > "$IL10_F"
il10_pad "$IL10_F" 8178
printf 'status: closed-completed\n---\n' >> "$IL10_F"
[ "$(head -c 8192 "$IL10_F" | tail -c 14)" = "status: closed" ] || {
  echo "FAIL[IL-10]: the excluded fixture leaks its hyphen inside the bound, so this half pins nothing"; fail=1; }
[ "$(head -c 8193 "$IL10_F" | tail -c 15)" = "status: closed-" ] || {
  echo "FAIL[IL-10]: the excluded fixture's hyphen is not at byte 8193, so this half tests a looser bound than it claims"; fail=1; }
RUN
assert_eq "$rc" "0" IL-10
assert_contains "HANDOFF-flux-11111111 (seat aaaa1111" "$out" IL-10
rm -f "$IL10_F"
# The included side: the same marker with its "closed-" hyphen AT byte 8192
# must hide the dispatched row, or the assertion above passes for the wrong
# reason (a bound tighter than the contract, or closing never working at all).
IL10_G="$tmp/ops/lanes/hyphen-at-the-bound.md"
printf -- '---\nlane: HANDOFF-flux-11111111\n' > "$IL10_G"
il10_pad "$IL10_G" 8177
printf 'status: closed-completed\n---\n' >> "$IL10_G"
[ "$(head -c 8192 "$IL10_G" | tail -c 15)" = "status: closed-" ] || {
  echo "FAIL[IL-10]: the included fixture's hyphen is not at byte 8192, so this half pins nothing"; fail=1; }
RUN
assert_missing "HANDOFF-flux-11111111 (seat aaaa1111" "$out" IL-10
rm -f "$IL10_G"

# ---- IL-11. a malformed closed lane value closes NOTHING --------------------
# F6 of the 2026-08-31 review: is_closed tests token containment in a
# space-delimited aggregate, so a hand-written `lane: junk HANDOFF-x junk`
# used to hide the UNRELATED dispatched lane HANDOFF-x from the coordinator
# view. Only a value in the lane-key charset may join the closed set. IL-4 is
# this case's positive control — a well-formed closed value does hide its row.
printf -- '---\nlane: junk HANDOFF-flux-11111111 junk\nstatus: closed-completed\n---\n' > "$tmp/ops/lanes/malformed-closed.md"
RUN
assert_eq "$rc" "0" IL-11
assert_contains "HANDOFF-flux-11111111 (seat aaaa1111" "$out" IL-11
rm -f "$tmp/ops/lanes/malformed-closed.md"

# ---- IL-12. a multibyte objective clips at BYTES and stays valid UTF-8 ------
# F7 of the 2026-08-31 review: ${#} counts characters in a UTF-8 locale, so a
# 200-character multibyte objective passed a 110 "byte" test at 3× its
# allowance; and a byte clip can land mid-code-point. The hook now counts
# bytes (LC_ALL=C) and repairs the clip with iconv -c. The 3-byte € makes both
# halves observable: 110 bytes is 36 whole chars + a partial one.
euro="$(printf '\342\202\254')"
mb=""; i=0
while [ "$i" -lt 200 ]; do mb="$mb$euro"; i=$((i + 1)); done
printf 'session_id=eeee5555\nstate=verified\nobjective=%s\n' "$mb" > "$tmp/records/mb.dispatch"
ln -sfn "$tmp/records/mb.dispatch" "$tmp/ops/dispatches/HANDOFF-multibyte-66666666"
RUN
assert_eq "$rc" "0" IL-12
assert_missing "$mb" "$out" IL-12
printf '%s' "$out" | iconv -f UTF-8 -t UTF-8 >/dev/null 2>&1 || { echo "FAIL[IL-12]: hook output is not valid UTF-8 after clipping a multibyte objective"; fail=1; }
mbcount="$(printf '%s' "$out" | grep -o "$euro" | wc -l | tr -d ' ')"
[ "$mbcount" -eq 36 ] || { echo "FAIL[IL-12]: $mbcount multibyte chars survived a 110-BYTE clip — a 110-byte clip of 3-byte € is exactly 36 whole chars after the iconv repair (a %.120s mutant gives 40; character counting gives 110)"; fail=1; }
rm -f "$tmp/ops/dispatches/HANDOFF-multibyte-66666666"

[ "$fail" = 0 ] && echo "PASS: inject-ops-lanes" || exit 1
