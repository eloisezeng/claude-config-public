#!/usr/bin/env bash
# SessionStart hook: print the global (cross-project) memory index to stdout so
# it loads into the model's context in EVERY project. Plain stdout; always exit 0.
#
# Implemented in bash (not node) on purpose: Claude Code runs hooks with a minimal
# PATH, where `node` (nvm) does NOT resolve but `bash` (in /bin) always does. A
# node-based hook silently produced no output. The .mjs sibling stays for Windows.
set -u

if [ -n "${CLAUDE_GLOBAL_MEMORY_DIR:-}" ]; then
  dir="$CLAUDE_GLOBAL_MEMORY_DIR"
else
  dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/memories/global"
fi
idx="$dir/MEMORY.md"
[ -f "$idx" ] || exit 0

# Strip HTML comments, then blank lines. Two passes: first single-line
# `<!-- ... -->` (sed ranges can't close on the same line), then multi-line blocks.
body="$(sed -E 's/<!--.*-->//g' "$idx" | sed '/<!--/,/-->/d' | sed '/^[[:space:]]*$/d')"
[ -n "$body" ] || exit 0

# Breadcrumb so firing is verifiable — the injected text itself is invisible to
# the user (it goes into the model's context, not the terminal). Overwrites.
{ echo "$(date '+%Y-%m-%d %H:%M:%S') inject-global-memory fired (${#body} body chars)"; } \
  > "${TMPDIR:-/tmp}/claude-global-memory-inject.log" 2>/dev/null || true

header="# Global memory (cross-project) — bodies at $dir/<name>.md, unfold with Read; project-local memory overrides these defaults"
out="$header"$'\n\n'"$body"$'\n'

# BUDGET: keep equal to `const BUDGET` in inject-global-memory.mjs — same knob, two
# runtimes (bash here, node on Windows); tests/inject-budget-parity.test.sh pins the
# equality. 8000 -> 12000 on the user's word (2026-08-19), matching the .mjs raise in
# ccc293a. (An older comment claimed the harness caps hook output at 10000; the
# 2026-08-19 docs state no such limit.) 100 chars reserved for the truncation notice.
budget=12000
if [ "${#out}" -gt "$budget" ]; then
  out="$(printf '%s' "$out" | head -c $((budget - 100)))"
  out="${out%$'\n'*}"$'\n'"… (truncated — read $idx in full)"
fi

printf '%s\n' "$out"
exit 0
