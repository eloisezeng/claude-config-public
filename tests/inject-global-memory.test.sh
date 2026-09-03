#!/usr/bin/env bash
# Tests for inject-global-memory.mjs — plain bash, no bats dependency.
set -u
HOOK="$(cd "$(dirname "$0")/.." && pwd)/inject-global-memory.mjs"
fail=0

# The cap under test is the runtime's OWN budget, read from the file under test --
# never a second literal.  These four assertions each restated the old number; when
# the budget was raised on 2026-09-02 they still measured the old one and reddened
# on a value nobody had changed.  tests/inject-budget-parity.test.sh pins the two
# runtimes to the same value, so each test reads its own subject and they agree.
BUDGET="$(grep -E '^const BUDGET = [0-9]+;$' "$HOOK" | head -1 | grep -Eo '[0-9]+')"
[ -n "$BUDGET" ] || { echo "FAIL: no ^const BUDGET = N; line in $HOOK (anchor moved?)"; exit 1; }
assert_contains() { case "$2" in *"$1"*) ;; *) echo "FAIL: expected to contain: $1"; fail=1;; esac; }
assert_empty()    { [ -z "$1" ] && return; echo "FAIL: expected empty output, got: $1"; fail=1; }
assert_eq()       { [ "$1" = "$2" ] && return; echo "FAIL: expected '$2' got '$1'"; fail=1; }

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/global"

# Case A: non-empty index -> header + contents, exit 0
printf -- '- [Foo](foo.md) — a foo fact\n' > "$tmp/global/MEMORY.md"
out="$(CLAUDE_GLOBAL_MEMORY_DIR="$tmp/global" node "$HOOK")"; code=$?
assert_eq "$code" "0"
assert_contains "Global memory (cross-project)" "$out"
assert_contains "[Foo](foo.md)" "$out"

# Case B: missing file -> no output, exit 0
rm -f "$tmp/global/MEMORY.md"
out="$(CLAUDE_GLOBAL_MEMORY_DIR="$tmp/global" node "$HOOK")"; code=$?
assert_eq "$code" "0"; assert_empty "$out"

# Case C: whitespace-only -> no output
printf -- '   \n\n' > "$tmp/global/MEMORY.md"
out="$(CLAUDE_GLOBAL_MEMORY_DIR="$tmp/global" node "$HOOK")"
assert_empty "$out"

# Case E: comment-only (the scaffold state) -> treated as empty, no injected noise
printf -- '<!-- docs, no pointers yet -->\n' > "$tmp/global/MEMORY.md"
out="$(CLAUDE_GLOBAL_MEMORY_DIR="$tmp/global" node "$HOOK")"
assert_empty "$out"

# Case D: oversize -> hooks ABBREVIATED, no memory dropped.
# The whole point of the change: a memory that is not listed can never be
# unfolded, so the injection caps every hook to the longest length that fits
# and keeps all 400 slugs. Assert the count, not just the notice — a notice
# claiming "every one is listed" is a MENTION, and a mention is not a property.
awk 'BEGIN { for (i = 0; i < 400; i++) print "- [x" i "](x" i ".md) — padding line, long enough that the hook must be abbreviated to fit" }' > "$tmp/global/MEMORY.md"
out="$(CLAUDE_GLOBAL_MEMORY_DIR="$tmp/global" node "$HOOK")"
listed="$(printf '%s\n' "$out" | grep -c '^- ')"
[ "$listed" -eq 400 ] || { echo "FAIL: $listed of 400 memories listed (expected all 400)"; fail=1; }
assert_contains "hooks abbreviated to" "$out"
# Read the two NUMBERS out of the notice rather than pattern-matching on them:
# `*"0 hooks abbreviated"*` matches inside "400 hooks abbreviated", so the guard
# passed on exactly the output it existed to reject.
n_abbrev="$(printf '%s\n' "$out" | sed -n 's/.*[^0-9]\([0-9][0-9]*\) hooks abbreviated to.*/\1/p')"
n_cap="$(printf '%s\n' "$out" | sed -n 's/.*hooks abbreviated to \([0-9][0-9]*\) chars.*/\1/p')"
[ "${n_abbrev:-0}" -gt 0 ] || { echo "FAIL: notice claims abbreviation but cut nothing ($n_abbrev)"; fail=1; }
[ "${n_cap:-0}" -gt 0 ]    || { echo "FAIL: hooks abbreviated away entirely (cap=$n_cap)"; fail=1; }
[ "${#out}" -le "$BUDGET" ] || { echo "FAIL: exceeds budget $BUDGET (${#out})"; fail=1; }

# Case D2: the fallback. When the bare SLUGS alone overflow the budget there
# is nothing left to abbreviate, so entries must be dropped — and the notice must
# still name the count. Without this case the drop path is untested code.
awk 'BEGIN { for (i = 0; i < 400; i++) { s = sprintf("slug-%03d-padded-out-to-sixty-odd-characters-so-slugs-alone-overflow", i); print "- [" s "](" s ".md) — h" } }' > "$tmp/global/MEMORY.md"
out="$(CLAUDE_GLOBAL_MEMORY_DIR="$tmp/global" node "$HOOK")"
assert_contains "TRUNCATED:" "$out"
assert_contains "memories are NOT loaded" "$out"
case "$out" in
  *"TRUNCATED: 0 of "*) echo "FAIL: truncation notice reports 0 dropped"; fail=1;;
  *"TRUNCATED: of "*)   echo "FAIL: truncation notice has no count"; fail=1;;
esac
[ "${#out}" -le "$BUDGET" ] || { echo "FAIL: exceeds budget $BUDGET (${#out})"; fail=1; }

[ "$fail" = 0 ] && echo "PASS: inject-global-memory" || exit 1
