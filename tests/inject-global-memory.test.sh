#!/usr/bin/env bash
# Tests for inject-global-memory.mjs — plain bash, no bats dependency.
set -u
HOOK="$(cd "$(dirname "$0")/.." && pwd)/inject-global-memory.mjs"
fail=0
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

# Case D: oversize -> truncated + pointer line
awk 'BEGIN { for (i = 0; i < 400; i++) print "- [x](x.md) — padding line to exceed the byte budget for truncation test" }' > "$tmp/global/MEMORY.md"
out="$(CLAUDE_GLOBAL_MEMORY_DIR="$tmp/global" node "$HOOK")"
assert_contains "truncated — read" "$out"
# Measure with node, not "${#out}": the hook budgets in JS string length, while
# bash counts BYTES under a non-UTF-8 locale (the default in Git Bash). Every
# em-dash in the index then counts 3x and a compliant output reads as oversize.
len="$(printf '%s' "$out" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>process.stdout.write(String(s.length)))')"
# 12000 follows BUDGET in inject-global-memory.mjs (raised 8000 -> 12000 on your word,
# ccc293a); this cap must move with that constant or the truncation fixture trips it.
[ "$len" -le 12000 ] || { echo "FAIL: output exceeds hard cap ($len chars)"; fail=1; }

[ "$fail" = 0 ] && echo "PASS: inject-global-memory" || exit 1
