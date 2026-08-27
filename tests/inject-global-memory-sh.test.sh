#!/usr/bin/env bash
# Tests for inject-global-memory.sh — the bash SessionStart hook.
set -u
HOOK="$(cd "$(dirname "$0")/.." && pwd)/inject-global-memory.sh"
fail=0
assert_contains() { case "$2" in *"$1"*) ;; *) echo "FAIL: expected to contain: $1"; fail=1;; esac; }
assert_empty()    { [ -z "$1" ] && return; echo "FAIL: expected empty output, got: $1"; fail=1; }
assert_eq()       { [ "$1" = "$2" ] && return; echo "FAIL: expected '$2' got '$1'"; fail=1; }

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/global"

# Case A: non-empty index -> header + contents, exit 0
printf -- '- [Foo](foo.md) — a foo fact\n' > "$tmp/global/MEMORY.md"
out="$(CLAUDE_GLOBAL_MEMORY_DIR="$tmp/global" bash "$HOOK")"; code=$?
assert_eq "$code" "0"
assert_contains "Global memory (cross-project)" "$out"
assert_contains "[Foo](foo.md)" "$out"

# Case B: missing file -> no output
rm -f "$tmp/global/MEMORY.md"
out="$(CLAUDE_GLOBAL_MEMORY_DIR="$tmp/global" bash "$HOOK")"
assert_empty "$out"

# Case C: comment-only (scaffold) -> no output (multi-line comment stripped)
printf -- '<!-- a\n b\n c -->\n' > "$tmp/global/MEMORY.md"
out="$(CLAUDE_GLOBAL_MEMORY_DIR="$tmp/global" bash "$HOOK")"
assert_empty "$out"

# Case D: comment + real pointer -> comment stripped, pointer kept
printf -- '<!-- doc -->\n- [Bar](bar.md) — real\n' > "$tmp/global/MEMORY.md"
out="$(CLAUDE_GLOBAL_MEMORY_DIR="$tmp/global" bash "$HOOK")"
assert_contains "[Bar](bar.md)" "$out"
case "$out" in *"<!--"*) echo "FAIL: comment leaked into output"; fail=1;; esac

# Case E: oversize -> truncated, hard cap <= 12000 (= the script's budget; equality
# with the .mjs BUDGET is pinned by tests/inject-budget-parity.test.sh)
awk 'BEGIN { for (i = 0; i < 400; i++) print "- [x](x.md) — padding line to exceed the byte budget for truncation" }' > "$tmp/global/MEMORY.md"
out="$(CLAUDE_GLOBAL_MEMORY_DIR="$tmp/global" bash "$HOOK")"
assert_contains "truncated — read" "$out"
[ "${#out}" -le 12000 ] || { echo "FAIL: exceeds hard cap (${#out})"; fail=1; }

# Case F (decisive): works in a MINIMAL env where node/nvm is absent — bash is on /bin.
printf -- '- [Foo](foo.md) — fact\n' > "$tmp/global/MEMORY.md"
out="$(env -i PATH=/usr/bin:/bin CLAUDE_GLOBAL_MEMORY_DIR="$tmp/global" bash "$HOOK")"
assert_contains "Global memory (cross-project)" "$out"

[ "$fail" = 0 ] && echo "PASS: inject-global-memory-sh" || exit 1
