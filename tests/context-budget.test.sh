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

# --- 7. this test mutated nothing tracked ----------------------------------
after="$(shasum "$ROOT/CLAUDE.md" "$ROOT/memories/global/MEMORY.md" | awk '{print $1}')"
if [ "$before" = "$after" ]; then
  ok "tracked files unchanged by this test"
else
  bad "THIS TEST MUTATED TRACKED FILES -- the auto-commit watcher will push them"
fi

[ "$fail" = 0 ] && echo "PASS: context-budget" || { echo "FAIL: context-budget"; exit 1; }
