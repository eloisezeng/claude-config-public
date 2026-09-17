#!/usr/bin/env bash
# Guards the session-start context budget (bin/context-budget.py).
#
# The budget is a RATCHET: limits may only ever fall. A test that merely ran
# --check on the real repo would be green the day it shipped and green forever
# after, including on the day the guard broke -- so most of what is below is
# mutant controls proving each rule can actually redden.
#
# Every mutant is built in a TEMP COPY and the tool is pointed at it with
# --root. This tree has a launchd watcher that auto-commits within about a
# minute, so a fault armed in place would be committed and pushed before the
# test finished. The last check asserts the tracked files were not touched.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CB="$ROOT/bin/context-budget.py"
fail=0

ok() { echo "  ok: $1"; }
bad() { echo "  FAIL: $1"; fail=1; }

# Byte-hash the two budgeted files up front so the last assertion can prove
# this test mutated nothing tracked.
before="$(shasum "$ROOT/CLAUDE.md" "$ROOT/memories/global/MEMORY.md" | awk '{print $1}')"

# --- 1. the real repo is within budget -------------------------------------
if "$CB" --check >/dev/null 2>&1; then
  ok "real repo is within its context budget"
else
  echo "  FAIL: real repo EXCEEDS its context budget:"
  "$CB" --check 2>&1 | sed 's/^/    /'
  fail=1
fi

# --- 2. mutant control: an oversized line must redden ----------------------
# Without this, a --check that always returned 0 would pass test 1 forever.
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/memories/global"
cp "$ROOT/CLAUDE.md" "$tmp/CLAUDE.md"
cp "$ROOT/memories/global/"*.md "$tmp/memories/global/"
# measure() RUNS the injection hook to count what actually reaches context, so the
# copy needs it too. Without this the positive control below fails and every
# mutant control after it proves nothing.
cp "$ROOT/inject-global-memory.sh" "$tmp/inject-global-memory.sh"

# Positive control FIRST: the unmutated copy must PASS. Without this, a copy
# that reddened for any unrelated reason (a missing file, a bad --root) would
# make the mutant control below pass for the wrong reason.
if "$CB" --check --root="$tmp" >/dev/null 2>&1; then
  ok "positive control: the unmutated copy passes"
else
  bad "the unmutated copy already fails -- the mutant control below proves nothing"
fi

# A directive longer than the current limit, appended inside the section.
python3 - "$tmp/CLAUDE.md" <<'PY'
import sys
p = sys.argv[1]
lines = open(p, encoding="utf-8").read().split("\n")
i = lines.index("## Working directives")
lines.insert(i + 2, "- " + "x" * 4000 + " `[[nonexistent-memory]]`.")
open(p, "w", encoding="utf-8").write("\n".join(lines))
PY
if "$CB" --check --root="$tmp" >/dev/null 2>&1; then
  bad "an oversized directive did NOT redden --check (the guard is inert)"
else
  ok "mutant control: an oversized directive reddens --check"
fi

# --- 3. the ratchet refuses to RAISE a limit -------------------------------
# The whole anti-accumulation property. If --set-baseline could raise, every
# regression would be absorbed by re-baselining instead of being trimmed.
out="$("$CB" --set-baseline --root="$tmp" 2>&1)"
rc=$?
if [ "$rc" = 0 ]; then
  bad "--set-baseline ACCEPTED a grown file; the ratchet does not hold"
elif echo "$out" | grep -q "REFUSED"; then
  ok "ratchet refuses to raise a limit"
else
  bad "--set-baseline failed for the wrong reason: $out"
fi

# --- 4. a broken scanner must not read as a huge improvement ---------------
# Renaming the section zeroes the directive metric. A naive budget would call
# that a 100% saving and ratchet the limit down to nothing.
cp "$ROOT/CLAUDE.md" "$tmp/CLAUDE.md"
sed -i '' 's/^## Working directives$/## Renamed Section/' "$tmp/CLAUDE.md"
if "$CB" --check --root="$tmp" 2>&1 | grep -q "the scanner is broken"; then
  ok "a zeroed metric is reported as a broken scanner, not an improvement"
else
  bad "renaming the directives section was silently accepted"
fi

# --- 5. orphan-fact detection distinguishes the two link forms -------------
# MEMORY.md uses [slug](slug.md); CLAUDE.md uses [[slug]]. Matching only the
# wikilink form made every index line report all its facts as orphaned.
if python3 - "$CB" <<'PY'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("cb", sys.argv[1])
cb = importlib.util.module_from_spec(spec); spec.loader.exec_module(cb)
assert cb.links("- rule `[[a-slug]]`.") == ["a-slug"], "wikilink form"
assert cb.links("- [a-slug](a-slug.md) - hook") == ["a-slug"], "markdown form"
bodies = {"a-slug": "the body mentions `30.5s` but not the other one"}
assert cb.orphan_facts("- x `30.5s` `99.9s` [a-slug](a-slug.md)", bodies) == ["99.9s"]
PY
then ok "orphan-fact detection handles both link forms"
else bad "orphan-fact detection is wrong"
fi

# --- 6. the injected-entry counter must match the hook's REAL output format --
# The hook compacts `- [slug](slug.md)` to `- slug` before injecting. A counter
# still looking for `- [` matched almost nothing and reported 122 of 123 entries
# dropped while 65 were plainly present. If this ever reports every entry as
# dropped, the counter has stopped matching the format, not the hook stopped
# working.
dropped="$(python3 -c "
import importlib.util, sys
spec = importlib.util.spec_from_file_location('cb', '$CB')
cb = importlib.util.module_from_spec(spec); spec.loader.exec_module(cb)
m = cb.measure('$ROOT')
print(m['index_dropped'], m['index_count'])
")"
set -- $dropped
if [ "$1" -ge "$2" ]; then
  bad "the injected-entry counter matched NOTHING ($1 of $2 dropped) -- it is reading the wrong format"
else
  ok "injected-entry counter matches the hook's output ($(( $2 - $1 )) of $2 reach context)"
fi

# --- 8. the index-hook BILL may not read zero when the loss is largest ------
# The hook has two notice forms and only the long one used to carry "N chars
# cut". The long one's length grows with the index PATH, so a clone under a long
# root (a worktree path runs ~46 chars longer than the live checkout) fell back
# to the short form, and hook_chars_lost() -- which parsed "chars cut" and
# treated its absence as 0 -- reported 0 while 71 of 116 hooks were being cut, a
# measured 7,958 chars. The metric read its BEST possible value at its worst
# moment. Both halves are pinned here: the hook must name the count on the
# fallback path, and the reader must FAIL rather than report 0 when it cannot
# find one.
cb2="$(mktemp -d)"
trap 'rm -rf "$tmp" "$cb2"' EXIT
mkdir -p "$cb2/memories/global"
cp "$ROOT/CLAUDE.md" "$cb2/CLAUDE.md"
cp "$ROOT/memories/global/"*.md "$cb2/memories/global/"
# A SMALL reserve forces the fallback on every machine, so this case does not
# depend on how long mktemp's directory happens to be -- a positive control that
# only fires on one machine is not a control. (reserve=1000 was tried first and
# is the WRONG direction: the long notice then fits, the short path never runs,
# and the "names its count" assertion below passes on the long form. The mutant
# control after it is what caught that.)
sed 's/^  reserve=200$/  reserve=120/' "$ROOT/inject-global-memory.sh" \
  > "$cb2/inject-global-memory.sh"

notice="$(CLAUDE_GLOBAL_MEMORY_DIR="$cb2/memories/global" bash "$cb2/inject-global-memory.sh" | tail -1)"
case "$notice" in
  *"hooks abbreviated to"*) ok "short-notice fixture: the hook did abbreviate" ;;
  *) bad "short-notice fixture abbreviated NOTHING -- this case proves nothing: $notice" ;;
esac
case "$notice" in
  *"for the full line"*) bad "the LONG notice fired -- this case is not exercising the fallback: $notice" ;;
  *"chars cut"*) ok "the SHORT notice names the count it discarded" ;;
  *) bad "the short notice names no 'chars cut' figure: $notice" ;;
esac
lost="$("$CB" --check --root="$cb2" 2>&1 | sed -n 's/.*abbreviated away: \([0-9,]*\) chars.*/\1/p' | tr -d ,)"
if [ -n "$lost" ] && [ "$lost" -gt 0 ]; then
  ok "the bill reports the loss ($lost chars) on the short-notice path"
else
  bad "the bill read '${lost:-empty}' while the hook was abbreviating -- fail-open"
fi

# Mutant control, PARTIAL on purpose: strip only the count from the fallback,
# leaving the "hooks abbreviated to" phrase. A fully broken hook would fail for
# any number of reasons; this one is the exact shape the old code shipped, and
# the reader must refuse it instead of printing 0.
sed 's/, \$lost chars cut)"$/)"/' "$cb2/inject-global-memory.sh" > "$cb2/hook.mut"
mv "$cb2/hook.mut" "$cb2/inject-global-memory.sh"
mutnotice="$(CLAUDE_GLOBAL_MEMORY_DIR="$cb2/memories/global" bash "$cb2/inject-global-memory.sh" | tail -1)"
case "$mutnotice" in
  *"chars cut"*) bad "the mutant still names a count -- the sed missed, so the control below proves nothing" ;;
  *"hooks abbreviated to"*) ok "mutant control armed: abbreviating, naming no count" ;;
  *) bad "the mutant stopped abbreviating entirely: $mutnotice" ;;
esac
if out="$("$CB" --check --root="$cb2" 2>&1)"; then
  bad "an unmeasurable index-hook loss was reported as a number instead of refusing"
elif echo "$out" | grep -q "names no 'N chars cut'"; then
  ok "an unmeasurable loss FAILS CLOSED rather than reporting 0"
else
  bad "the check failed for the wrong reason: $out"
fi

# --- 9. the dangling-lane-pointer count, both directions -------------------
# REPORT-ONLY by design (lane files are operational scratch in many repos; a
# hard failure over them gets the guard switched off). So what is pinned is the
# MEASUREMENT, in both directions: a pointer with no body anywhere is counted, a
# pointer that resolves is not, and a lane-to-lane reference is not. A one-sided
# test would pass for a scanner that counted every pointer, or for one that
# counted none.
lanes="$(mktemp -d)"
trap 'rm -rf "$tmp" "$cb2" "$lanes"' EXIT
mkdir -p "$lanes/lanes"
real="$(ls "$ROOT/memories/global" | grep -v '^MEMORY.md$' | head -1)"; real="${real%.md}"
printf 'cites a real memory [[%s]] and a made-up one [[zzz-no-such-lesson-anywhere]]\n' \
  "$real" > "$lanes/lanes/alpha.md"
printf 'cites the other lane [[alpha]] and the same made-up one [[zzz-no-such-lesson-anywhere]]\n' \
  > "$lanes/lanes/beta.md"
lp="$(CLAUDE_OPS_DIR="$lanes" python3 -c "
import importlib.util, sys
spec = importlib.util.spec_from_file_location('cb', '$CB')
cb = importlib.util.module_from_spec(spec); spec.loader.exec_module(cb)
r = cb.lane_pointers('$ROOT')
print(r['lanes'], r['dangling'], ','.join(r['names']), r['counts'].get('zzz-no-such-lesson-anywhere'))
")"
set -- $lp
if [ "$1" = 2 ] && [ "$2" = 1 ] && [ "$3" = "zzz-no-such-lesson-anywhere" ] && [ "$4" = 2 ]; then
  ok "lane-pointer scan: counts the dangling one (2 lanes), not the resolving one, not the lane ref"
else
  bad "lane-pointer scan misread the fixture: got '$lp' (want '2 1 zzz-no-such-lesson-anywhere 2')"
fi

# An unreadable ledger must report NOT MEASURED, never 0: absence of a scan is
# not absence of debt. Without this the metric reads perfect on every machine
# that has no lane directory, which is every fresh clone.
absent="$(CLAUDE_OPS_DIR="$lanes/nonexistent" python3 -c "
import importlib.util, sys
spec = importlib.util.spec_from_file_location('cb', '$CB')
cb = importlib.util.module_from_spec(spec); spec.loader.exec_module(cb)
r = cb.lane_pointers('$ROOT')
print(repr(r['dangling']), '|', cb.lane_pointer_line(r))
")"
case "$absent" in
  "None | dangling lane pointers: NOT MEASURED"*) ok "no ledger reports NOT MEASURED, not 0" ;;
  *) bad "a missing ledger did not report NOT MEASURED: $absent" ;;
esac

# A project-local memory must RESOLVE a pointer. Resolving only against
# memories/global/ is the measurement error this metric exists to prevent: a
# 2026-09-17 inventory reported 8 dangling pointers cited by 2+ lanes, and all
# of them had bodies in one project's store.
# Pick a project memory that is NOT also in the global store, or the case would
# pass on the global resolution and prove nothing about the project one.
projmem=""
for d in "$HOME"/.claude*/projects/*/memory; do
  [ -d "$d" ] || continue
  for f in "$d"/*.md; do
    [ -f "$f" ] || continue
    b="$(basename "$f" .md)"
    [ "$b" = MEMORY ] && continue
    [ -f "$ROOT/memories/global/$b.md" ] && continue
    projmem="$b"; break
  done
  [ -n "$projmem" ] && break
done
if [ -n "$projmem" ]; then
  printf 'cites a PROJECT memory [[%s]]\n' "$projmem" > "$lanes/lanes/gamma.md"
  pd="$(CLAUDE_OPS_DIR="$lanes" python3 -c "
import importlib.util, sys
spec = importlib.util.spec_from_file_location('cb', '$CB')
cb = importlib.util.module_from_spec(spec); spec.loader.exec_module(cb)
print(','.join(cb.lane_pointers('$ROOT')['names']))
")"
  case "$pd" in
    *"$projmem"*) bad "a pointer answered by a PROJECT memory was counted as dangling" ;;
    *) ok "a project-local memory resolves its pointer (global-only would not)" ;;
  esac
  rm -f "$lanes/lanes/gamma.md"
else
  echo "  skip: no project memory store on this machine to resolve against"
fi

# --- 7. this test mutated nothing tracked ----------------------------------
after="$(shasum "$ROOT/CLAUDE.md" "$ROOT/memories/global/MEMORY.md" | awk '{print $1}')"
if [ "$before" = "$after" ]; then
  ok "tracked files unchanged by this test"
else
  bad "THIS TEST MUTATED TRACKED FILES -- the auto-commit watcher will push them"
fi

[ "$fail" = 0 ] && echo "PASS: context-budget" || { echo "FAIL: context-budget"; exit 1; }
