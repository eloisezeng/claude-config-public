#!/usr/bin/env bash
# The injection budget is ONE knob in TWO runtimes: `budget=` in inject-global-memory.sh
# (mac/linux, wired in settings.json) and `const BUDGET` in inject-global-memory.mjs
# (Windows, wired in settings.windows.json). In 2026-08 a raise landed on the .mjs only,
# so the LIVE mac hook kept the old cap for days — this test turns that drift into a red
# suite instead of a silent divergence.
set -u
root="$(cd "$(dirname "$0")/.." && pwd)"
fail=0

sh_budget="$(grep -E '^budget=[0-9]+$' "$root/inject-global-memory.sh" | head -1 | cut -d= -f2)"
mjs_budget="$(grep -E '^const BUDGET = [0-9]+;$' "$root/inject-global-memory.mjs" | head -1 | grep -Eo '[0-9]+')"

[ -n "$sh_budget" ]  || { echo "FAIL: no ^budget=N line in inject-global-memory.sh (anchor moved?)"; fail=1; }
[ -n "$mjs_budget" ] || { echo "FAIL: no ^const BUDGET = N; line in inject-global-memory.mjs (anchor moved?)"; fail=1; }
if [ "$fail" = 0 ] && [ "$sh_budget" != "$mjs_budget" ]; then
  echo "FAIL: budget drift — sh=$sh_budget mjs=$mjs_budget (raise BOTH or neither)"; fail=1
fi

# The budget number is only half the contract. In 2026-09 the two runtimes had the
# SAME budget but produced different output: the bash hook sliced with `head -c`
# (BYTES) against a cap it tested with ${#out} (CHARACTERS), so ~166 chars of
# multi-byte em-dash made it truncate an entry early. A number-only parity test saw
# nothing. Assert the OUTPUT, which is what actually reaches the model.
if command -v node >/dev/null 2>&1; then
  export CLAUDE_GLOBAL_MEMORY_DIR="$root/memories/global"
  sh_out="$(bash "$root/inject-global-memory.sh")"
  mjs_out="$(node "$root/inject-global-memory.mjs")"
  sh_n="$(printf '%s\n' "$sh_out" | grep -c '^- ')"
  mjs_n="$(printf '%s\n' "$mjs_out" | grep -c '^- ')"
  if [ "$sh_out" != "$mjs_out" ]; then
    echo "FAIL: injection OUTPUT drift — sh keeps $sh_n entries, mjs keeps $mjs_n"
    echo "      (same budget, different result: check byte-vs-char slicing and the"
    echo "       index-compaction rewrite in both runtimes)"
    fail=1
  else
    echo "  ok: both runtimes emit identical output ($sh_n entries)"
  fi
else
  echo "  SKIP: node not on PATH — output parity unchecked (budget parity still asserted)"
fi

[ "$fail" = 0 ] && echo "PASS: inject-budget-parity" || exit 1
