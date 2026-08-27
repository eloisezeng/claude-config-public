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

[ "$fail" = 0 ] && echo "PASS: inject-budget-parity" || exit 1
