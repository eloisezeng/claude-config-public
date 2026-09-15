#!/usr/bin/env bash
# Tests for bin/compaction-stats.py — the instrument that judges whether the
# 2026-09-15 autoCompactWindow change worked.
#
# WHY THIS SUITE EXISTS
# ---------------------
# The success criterion is a pass/fail rule the user set by hand: the p90 of each
# session's WORST 60-MINUTE WINDOW must fall from the pinned baseline of 6 to 3
# or below. A rule of that shape written only in prose gets re-litigated every
# time somebody re-derives it, so it ships here as pure functions with the
# baseline pinned as a committed fixture. The after-measurement then runs the
# same rule over the same definition, and a wrong number is a red test rather
# than a correction in a report.
#
# What is actually pinned:
#   - worst_window() counts events in a sliding hour, including both ends.
#   - nearest_rank_percentile() is nearest-rank, never interpolated: the
#     statistic is a COUNT, and a fractional verdict invites an argument about
#     the interpolation instead of about the change.
#   - verdict() reports IMPROVED-BUT-SHORT as a FAILURE, because the criterion
#     is an absolute ceiling and not a direction of travel.
#   - the fixture still reproduces a p90 of exactly 6, so the baseline the
#     verdict compares against cannot drift under it.
set -u
BIN="$(cd "$(dirname "$0")/.." && pwd)/bin/compaction-stats.py"
FIXTURE="$(cd "$(dirname "$0")/.." && pwd)/bin/compaction-stats.baseline.csv"
fail=0

assert_contains() { case "$2" in *"$1"*) ;; *) echo "FAIL[$3]: expected to contain: $1"; fail=1;; esac; }
assert_missing()  { case "$2" in *"$1"*) echo "FAIL[$3]: expected NOT to contain: $1"; fail=1;; *) ;; esac; }
assert_eq()       { [ "$1" = "$2" ] || { echo "FAIL[$3]: expected '$2' got '$1'"; fail=1; }; }

[ -x "$BIN" ]     || { echo "FAIL[setup]: $BIN is not executable"; exit 1; }
[ -f "$FIXTURE" ] || { echo "FAIL[setup]: pinned baseline $FIXTURE is missing"; exit 1; }

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT

# macOS ships bash 3.2, which cannot parse a here-document inside a command
# substitution. Every inline script below is therefore written to a file first
# and then run, rather than piped straight into "$( ... )".

# ---------------------------------------------------------------------------
# A: the pure decision rule
# ---------------------------------------------------------------------------
cat > "$tmp/rule.py" <<'PY'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("cs", sys.argv[1])
cs = importlib.util.module_from_spec(spec); spec.loader.exec_module(cs)
H = 3600

def check(name, got, want):
    print(f"{'ok' if got == want else 'BAD'} {name}: got {got!r} want {want!r}")

# worst_window. The fixtures are deliberately NOT degenerate: each has a
# reachable wrong answer that a different windowing rule would produce.
check("empty",            cs.worst_window([]), 0)
check("single",           cs.worst_window([0]), 1)
# Six inside one hour, then a long quiet gap, then two more. A rule that
# counted the LAST window, or an average, would answer 2 or 2.67.
burst = [0, 300, 900, 1500, 2400, 3000] + [10*H, 10*H + 600]
check("burst-then-quiet", cs.worst_window(burst), 6)
# Exactly one hour apart is TWO events within an hour's span, not one.
check("exact-boundary",   cs.worst_window([0, H]), 2)
# One second past the hour is not.
check("just-outside",     cs.worst_window([0, H + 1]), 1)
# Unsorted input must give the same answer as sorted input.
check("unsorted",         cs.worst_window(list(reversed(burst))), 6)
# The window slides: the worst hour here straddles the middle, so a rule that
# only measured from the first event would answer 3.
slide = [0, 3500, 3550, 3600, 3650]
check("sliding",          cs.worst_window(slide), 4)

# nearest_rank_percentile. Alternatives are reachable: linear interpolation
# would answer 9.1 for the p90 below, and "index int(q*N)" would answer 9.
xs = list(range(1, 11))          # 1..10
check("p90-nearest-rank", cs.nearest_rank_percentile(xs, 0.90), 9)
check("p100",             cs.nearest_rank_percentile(xs, 1.00), 10)
check("p10-floor",        cs.nearest_rank_percentile(xs, 0.10), 1)
check("p50-even",         cs.nearest_rank_percentile([1, 2, 3, 4], 0.50), 2)
try:
    cs.nearest_rank_percentile([], 0.9); print("BAD empty-percentile: no raise")
except ValueError: print("ok empty-percentile raises")
try:
    cs.nearest_rank_percentile([1], 0); print("BAD zero-quantile: no raise")
except ValueError: print("ok zero-quantile raises")

# verdict. Each branch is exercised, including the one that is easy to get
# wrong: a real improvement that still misses the ceiling is NOT a pass.
for obs, want_pass, want_word in [
    (3, True,  "PASS"),
    (1, True,  "PASS"),
    (4, False, "IMPROVED BUT SHORT"),
    (5, False, "IMPROVED BUT SHORT"),
    (6, False, "NO CHANGE"),
    (7, False, "WORSE"),
]:
    passed, line = cs.verdict(obs)
    ok = (passed == want_pass) and line.startswith(want_word)
    print(f"{'ok' if ok else 'BAD'} verdict({obs}): {line}")

# The project hash must not reproduce its input, and must be stable.
name = "-Users-user-Coding-your-other-project--claude-worktrees-secret-lane"
h = cs.hash_project(name)
check("hash-stable", h, cs.hash_project(name))
check("hash-hides",  name in h or h in name, False)
PY
out="$(python3 "$tmp/rule.py" "$BIN" 2>&1)"
assert_missing "BAD "        "$out" "A: pure decision rule"
assert_missing "Traceback"   "$out" "A: pure decision rule"
assert_contains "ok burst-then-quiet" "$out" "A: worst_window ran"
assert_contains "ok verdict(4)"       "$out" "A: verdict ran"

# ---------------------------------------------------------------------------
# B: the pinned baseline still reads 6, and the CLI says so
# ---------------------------------------------------------------------------
b_out="$("$BIN" baseline 2>&1)"; b_ec=$?
assert_eq "$b_ec" "0" "B: baseline exit status"
assert_contains "sessions counted:           616" "$b_out" "B: fixture row count"
assert_contains "p90 6"                           "$b_out" "B: fixture p90 is 6"
assert_contains "p90 <= 3"                        "$b_out" "B: target is stated"

# ---------------------------------------------------------------------------
# C: the fixture carries no project directory name into the public mirror
# ---------------------------------------------------------------------------
leak="$(grep -ciE 'your-module|netorg|orgnet|your-other-project|arbitrage|lavish|example-co|Coding' "$FIXTURE" || true)"
assert_eq "$leak" "0" "C: no project name in the pinned fixture"
# The fixture is the baseline the verdict compares against. An unremarked edit
# to it would redefine success without changing a line of code, so its content
# is pinned by digest: a deliberate re-baseline must update this line and say so.
fx_sha="$(shasum -a 256 "$FIXTURE" | awk '{print $1}')"
assert_eq "$fx_sha" "c5a241574da033e48c104c48943fecb6752c8edea56a64085ac7b32346d83ea2" "C: pinned baseline is byte-identical"
assert_eq "$(grep -c . "$FIXTURE")" "617" "C: fixture is 616 rows plus a header"

hdr="$(head -1 "$FIXTURE")"
assert_eq "$hdr" "session,root,project,start_utc,end_utc,duration_h,boundaries,boundaries_per_hour,max_boundaries_per_60min" "C: fixture columns"

# ---------------------------------------------------------------------------
# D: a real end-to-end measurement over a synthetic config root
#    This is the control: the same code path that will judge the change, run
#    against transcripts whose answer is known by construction.
# ---------------------------------------------------------------------------
proj="$tmp/root/projects/-fixture-project"; mkdir -p "$proj"

# Session 1: seven automatic boundaries inside one hour -> worst window 7.
# Session 2: two boundaries, hours apart -> worst window 1.
# Session 3: five boundaries in an hour, but every one hand-invoked -> excluded.
cat > "$tmp/iso.py" <<'PY'
import datetime, sys
# A fixed base instant, so every fixture timestamp is deterministic.
base = 1757894400
print(datetime.datetime.fromtimestamp(base + int(sys.argv[1]), datetime.timezone.utc)
      .isoformat().replace("+00:00", "Z"))
PY
emit() { # $1 = file, $2 = epoch offset seconds from a fixed base, $3 = trigger
  ts="$(python3 "$tmp/iso.py" "$2")"
  printf '{"type":"system","subtype":"compact_boundary","timestamp":"%s","compactMetadata":{"trigger":"%s"}}\n' "$ts" "$3" >> "$1"
  printf '{"type":"assistant","timestamp":"%s","message":{"usage":{"input_tokens":1}}}\n' "$ts" >> "$1"
}
s1="$proj/11111111-0000-0000-0000-000000000000.jsonl"
for off in 0 400 800 1200 1600 2000 2400; do emit "$s1" "$off" auto; done
s2="$proj/22222222-0000-0000-0000-000000000000.jsonl"
for off in 0 20000 40000; do emit "$s2" "$off" auto; done
s3="$proj/33333333-0000-0000-0000-000000000000.jsonl"
for off in 0 300 600 900 1200; do emit "$s3" "$off" manual; done

m_out="$("$BIN" measure --roots "$tmp/root" --csv "$tmp/out.csv" 2>&1)"; m_ec=$?
assert_contains "sessions counted:           2" "$m_out" "D: manual-only session excluded"
assert_contains "VERDICT: WORSE"                "$m_out" "D: a 7-in-an-hour session fails"
# Two sessions with worsts {7, 1}: nearest-rank p90 is 7.
assert_contains "p90 7"                         "$m_out" "D: measured p90"
assert_eq "$m_ec" "1" "D: a failing verdict exits non-zero"

got1="$(awk -F, '$1=="11111111"{print $9}' "$tmp/out.csv")"
assert_eq "$got1" "7" "D: session 1 worst window"
got2="$(awk -F, '$1=="22222222"{print $9}' "$tmp/out.csv")"
assert_eq "$got2" "1" "D: session 2 worst window"
assert_eq "$(grep -c 33333333 "$tmp/out.csv" || true)" "0" "D: manual session absent from the CSV"

# The opposite-answer control: counting the manual boundaries too must CHANGE
# the result. Without this, "manual excluded" would also pass for a script that
# never read the trigger field at all.
i_out="$("$BIN" measure --roots "$tmp/root" --include-manual 2>&1)"
assert_contains "sessions counted:           3" "$i_out" "D-control: manual session counted when asked"

# A passing verdict must be reachable from this same code path, or the PASS
# branch is never exercised end to end.
calm="$tmp/calm/projects/-fixture-project"; mkdir -p "$calm"
c1="$calm/44444444-0000-0000-0000-000000000000.jsonl"
for off in 0 20000 40000; do emit "$c1" "$off" auto; done
c_out="$("$BIN" measure --roots "$tmp/calm" 2>&1)"; c_ec=$?
assert_contains "VERDICT: PASS" "$c_out" "D-control: a calm root passes"
assert_eq "$c_ec" "0" "D-control: a passing verdict exits 0"

# ---------------------------------------------------------------------------
# E: the --since window actually filters
# ---------------------------------------------------------------------------
f_out="$("$BIN" measure --roots "$tmp/root" --since 2030-01-01 2>&1)"; f_ec=$?
assert_contains "not measurable" "$f_out" "E: a future window measures nothing"
assert_eq "$f_ec" "1" "E: an unmeasurable window exits non-zero"

if [ "$fail" -eq 0 ]; then echo "PASS: compaction-stats"; else echo "FAILURES: compaction-stats"; fi
exit "$fail"
