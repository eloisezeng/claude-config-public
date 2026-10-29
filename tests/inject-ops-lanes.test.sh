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
assert_contains "Open, no session on it (1) — nobody is doing this work:" "$out" IL-3
assert_contains "loose-item [blocked-on-user]: waiting on a decision" "$out" IL-3
# THE ORDER IS THE POINT, not just the heading: the section naming work nobody
# is doing has to be the one a session reads first. Asserting both headings are
# present passes for either order, which is how the stranded lane came to sit
# behind two rows of lanes that already had seats.
il3_ns="$(printf '%s' "$out" | grep -n '^Open, no session on it' | head -1 | cut -d: -f1)"
il3_dp="$(printf '%s' "$out" | grep -n '^Dispatched (' | head -1 | cut -d: -f1)"
[ -n "$il3_ns" ] && [ -n "$il3_dp" ] && [ "$il3_ns" -lt "$il3_dp" ] || {
  echo "FAIL[IL-3]: the open-with-no-session section must come FIRST (no-session at line ${il3_ns:-absent}, dispatched at line ${il3_dp:-absent})"; fail=1; }
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
assert_contains "lane rows are NOT shown — read ~/.claude/ops/ in full" "$out" IL-8
# THE CAP NAMES THE NUMBER IT DROPPED. A cap that truncates in silence reads
# exactly like a ledger with nothing more in it, so the one reader who should
# open the full thing has no reason to. Both numbers are asserted against the
# fixture's own arithmetic: 61 lane rows exist here (60 bulk dispatches + the
# loose lane file), the shown count is counted out of the output, and the
# dropped count must be the difference -- which a hardcoded word cannot be. The
# total is DERIVED from the ledger on disk rather than written down, because a
# literal here drifts the next time a case above leaves a fixture behind and the
# only symptom is a control that has quietly stopped checking the arithmetic.
il8_links="$(find "$tmp/ops/dispatches" -maxdepth 1 -type l | grep -c . | tr -d ' ')"
il8_files="$(ls "$tmp/ops/lanes"/*.md 2>/dev/null | grep -c . | tr -d ' ')"
# the derivation below assumes every lane file present here is OPEN; say so, so
# a future closed fixture reddens here instead of skewing the total in silence
assert_eq "$il8_files" "1" IL-8
il8_total=$(( il8_links + il8_files ))
il8_shown="$(printf '%s' "$out" | grep -c '^- ' | tr -d ' ')"
il8_drop="$(printf '%s' "$out" | sed -n 's/^… truncated: \([0-9][0-9]*\) of \([0-9][0-9]*\) lane rows.*/\1 \2/p')"
[ -n "$il8_drop" ] || { echo "FAIL[IL-8]: the truncation line names no counts -- got: $out"; fail=1; }
il8_d="${il8_drop%% *}"; il8_t="${il8_drop##* }"
assert_eq "$il8_t" "$il8_total" IL-8
assert_eq "$il8_d" "$(( il8_total - il8_shown ))" IL-8
[ "${il8_d:-0}" -gt 0 ] || { echo "FAIL[IL-8]: the cap reported dropping 0 rows although it truncated -- a count that cannot be non-zero names nothing"; fail=1; }

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
# 2026-10-04: the DECIDING BYTE moved. The rule is now the status's first token
# against a set, not a `closed-` prefix, so `status: closed` INSIDE the bound
# already closes the lane and the old fixture's two halves both read closed.
# `superseded` is the replacement: its final `d` is the byte that decides, since
# a truncated `supersede` is in no set and leaves the lane open. The structure
# is unchanged and so is the claim -- included side's deciding byte AT 8192,
# excluded side's at 8193, surviving set exactly {8192}.
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
IL10_F="$tmp/ops/lanes/decider-past-the-bound.md"
printf -- '---\nlane: HANDOFF-flux-11111111\n' > "$IL10_F"
il10_pad "$IL10_F" 8175
printf 'status: superseded\n---\n' >> "$IL10_F"
[ "$(head -c 8192 "$IL10_F" | tail -c 17)" = "status: supersede" ] || {
  echo "FAIL[IL-10]: the excluded fixture leaks its deciding byte inside the bound, so this half pins nothing"; fail=1; }
[ "$(head -c 8193 "$IL10_F" | tail -c 18)" = "status: superseded" ] || {
  echo "FAIL[IL-10]: the excluded fixture's deciding byte is not at 8193, so this half tests a looser bound than it claims"; fail=1; }
RUN
assert_eq "$rc" "0" IL-10
assert_contains "HANDOFF-flux-11111111 (seat aaaa1111" "$out" IL-10
rm -f "$IL10_F"
# The included side: the same marker with its "closed-" hyphen AT byte 8192
# must hide the dispatched row, or the assertion above passes for the wrong
# reason (a bound tighter than the contract, or closing never working at all).
IL10_G="$tmp/ops/lanes/decider-at-the-bound.md"
printf -- '---\nlane: HANDOFF-flux-11111111\n' > "$IL10_G"
il10_pad "$IL10_G" 8174
printf 'status: superseded\n---\n' >> "$IL10_G"
[ "$(head -c 8192 "$IL10_G" | tail -c 18)" = "status: superseded" ] || {
  echo "FAIL[IL-10]: the included fixture's deciding byte is not at byte 8192, so this half pins nothing"; fail=1; }
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

# ---- IL-13. a disposed lane is not open work, in every spelling it has ------
# What this listing was for months: the reader knew only `closed-*`, so 19 of
# the 42 rows a session saw at startup were lanes already disposed of (measured
# 2026-10-04 over the 95 lane files on this machine, in SIX spellings). Nineteen
# finished rows mixed into forty-two is a listing nobody reads, and that is how
# the genuinely stranded lane sat in it unnoticed.
#
# Every spelling measured on disk is swept, and so is the other direction: a
# status nobody has seen before must stay OPEN, because an unrecognised status
# in front of a human is recoverable and a hidden lane is not.
rm -f "$tmp/ops/dispatches"/HANDOFF-* "$tmp/ops/lanes"/*.md
ln -sfn "$tmp/records/one.dispatch" "$tmp/ops/dispatches/HANDOFF-flux-11111111"
il13_lane() { # $1=slug  $2=status
  printf -- '---\nlane: %s\nstatus: %s\nobjective: the %s objective\n---\n' "$1" "$2" "$1" \
    > "$tmp/ops/lanes/$1.md"
}
il13_i=0
for il13_st in "completed" "cancelled" "superseded" "closed-completed" \
               "closed — completed 2026-09-11" "completed — PR #67 merged as 6891e31"; do
  il13_i=$((il13_i + 1))
  il13_lane "il13-done-$il13_i" "$il13_st"
done
il13_lane il13-still-open open
il13_lane il13-unseen-status mid-review
RUN
assert_eq "$rc" "0" IL-13
il13_j=0
while [ "$il13_j" -lt "$il13_i" ]; do
  il13_j=$((il13_j + 1))
  assert_missing "il13-done-$il13_j" "$out" "IL-13 spelling $il13_j"
done
# the positive control: the open lanes are still there, so the six assertions
# above are about those statuses and not about lane files having stopped
# rendering at all.
assert_contains "il13-still-open [open]" "$out" IL-13
assert_contains "il13-unseen-status [mid-review]" "$out" IL-13
assert_contains "Open, no session on it (2)" "$out" IL-13
# ...and a prose tail is a human's NOTE, not the state: only the first token is
# printed, or a status line naming a commit and a date becomes the row.
il13_lane il13-annotated "open — waiting on a decision only the operator can make"
RUN
assert_contains "il13-annotated [open]" "$out" IL-13
assert_missing "waiting on a decision only the operator" "$out" IL-13

# ---- IL-14. a lane file with NO `status:` line says so, in the row -----------
# The field has one spelling. Measured 2026-10-11 over 102 lane files: 31 wrote
# it `state:`, which this reader does not see, so nine FINISHED lanes were
# listed as open with an empty pair of brackets and nothing saying why. The row
# now names the missing line, and the other spelling is still not a status: if
# it were accepted, `il14-state-done` would vanish from the listing here.
rm -f "$tmp/ops/lanes"/*.md
printf -- '---\nlane: il14-state-done\nstate: completed\nobjective: finished, spelled the other way\n---\n' \
  > "$tmp/ops/lanes/il14-state-done.md"
printf -- '---\nlane: il14-no-line\nobjective: no status of any spelling\n---\n' \
  > "$tmp/ops/lanes/il14-no-line.md"
il13_lane il14-empty-status ""
il13_lane il14-control open
RUN
assert_eq "$rc" "0" IL-14
assert_contains "il14-state-done [NO-STATUS-LINE]" "$out" IL-14
assert_contains "il14-no-line [NO-STATUS-LINE]" "$out" IL-14
# a `status:` line that is present and EMPTY is a different fact from an absent
# one, and is not relabelled: the line is there, somebody left it blank.
assert_contains "il14-empty-status []" "$out" IL-14
assert_contains "il14-control [open]" "$out" IL-14

# ---- IL-15. a lane file with no `lane:` line is COUNTED, not dropped ----------
# Measured 2026-10-11: nine files in lanes/ are plain notes with no front
# matter. They have no name to be listed under, and the listing used to skip
# them without a word, so nine pieces of recorded work appeared nowhere.
assert_missing "NOT listed below" "$out" "IL-15 control: nothing unlisted yet"
printf '# a note with no front matter\n\nOpened by somebody.\n' > "$tmp/ops/lanes/il15-plain-a.md"
printf '# another\n' > "$tmp/ops/lanes/il15-plain-b.md"
RUN
assert_eq "$rc" "0" IL-15
assert_contains "NOT listed below: 2 file(s)" "$out" IL-15
assert_contains "il14-control [open]" "$out" IL-15

[ "$fail" = 0 ] && echo "PASS: inject-ops-lanes" || exit 1
