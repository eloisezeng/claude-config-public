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
# Compact the index entries: `- [slug](slug.md) — hook` -> `- slug — hook`.
# The slug appears TWICE in the markdown form, and the header line below already
# tells the reader that bodies live at <dir>/<name>.md — so the link is pure
# duplication, ~42 chars of it per entry. Dropping it is LOSSLESS (the slug, which
# is what a Read needs, survives) and buys entries that the budget below would
# otherwise truncate away. The rewrite only fires when the link text and the
# filename match, so any hand-written link pointing elsewhere is left alone.
# Measured 2026-09-02: 5,166 chars recovered across 123 entries.
# NOTE: done in awk, not sed. BSD sed's -E is POSIX ERE, which has no
# backreferences in the PATTERN, so the obvious `\[([a-z-]+)\]\(\1\.md\)` never
# matches on macOS and fails SILENTLY (measured: zero chars recovered, no error).
compact='
{
  if ($0 ~ /^- \[[A-Za-z0-9._-]+\]\([A-Za-z0-9._-]+\.md\)/) {
    t = substr($0, 4)
    slug = substr(t, 1, index(t, "]") - 1)
    rest = substr(t, index(t, "]") + 1)
    fn = substr(rest, 2, index(rest, ")") - 2)
    if (fn == slug ".md") $0 = "- " slug substr(rest, index(rest, ")") + 1)
  }
  print
}'
body="$(sed -E 's/<!--.*-->//g' "$idx" | sed '/<!--/,/-->/d' | sed '/^[[:space:]]*$/d' \
  | awk "$compact")"
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
# 2026-08-19 docs state no such limit.)
# 12000 -> 20000 on 2026-09-02, the recommendation in the budget report's own menu
# (bin/context-budget.py --report): the cap now abbreviates HOOKS rather than dropping
# memories, and 12000 squeezed each hook to ~50 chars — a label, not a usable summary.
# 20000 buys ~123-char hooks for +1,850 tokens/session. All 125 stay listed at any
# budget; the knob only buys hook length. Re-run the report before moving it again.
budget=20000
if [ "${#out}" -gt "$budget" ]; then
  # ABBREVIATE THE HOOKS, DO NOT DROP THE MEMORIES.
  #
  # The old behaviour sliced the index at the budget and threw away every entry
  # past the cut: 58 of 123 memories (47%) reached no session at all, and a
  # memory that is not listed can never be unfolded — its cost is unbounded,
  # because the mistake it exists to prevent gets made again. A memory whose hook
  # is cut short is still listed by SLUG (avg 37 chars, and the slugs are written
  # as whole rules), so it can still be Read. Truncating text is recoverable;
  # dropping a name is not.
  #
  # So: find the largest per-hook character cap H that makes the WHOLE index fit,
  # and cut only the hooks longer than H. Short hooks are untouched — the cost
  # falls entirely on the longest lines, which is also where the waste is.
  reserve=200
  avail=$(( budget - reserve - ${#header} - 3 ))

  prefixes=(); hooks=(); fixed=0; maxhook=0
  while IFS= read -r line; do
    case "$line" in
      *" — "*) p="${line%%" — "*} — "; h="${line#*" — "}" ;;
      *)       p="$line";             h="" ;;
    esac
    prefixes+=("$p"); hooks+=("$h")
    fixed=$(( fixed + ${#p} + 1 ))
    [ "${#h}" -gt "$maxhook" ] && maxhook=${#h}
  done <<< "$body"

  if [ "$fixed" -gt "$avail" ]; then
    # Even bare slugs overflow. Fall back to the old slice-and-drop, and say so
    # with a count — this is the only surface on which the loss is visible.
    out="${out:0:$((budget - reserve))}"
    out="${out%$'\n'*}"
    kept_n="$(grep -c '^- ' <<<"$out")"
    total_n="$(grep -c '^- ' <<<"$body")"
    notice="… (TRUNCATED: $((total_n - kept_n)) of $total_n memories are NOT loaded — read $idx in full; run bin/context-budget.py --report)"
    [ "${#notice}" -le "$reserve" ] || notice="… (TRUNCATED: $((total_n - kept_n)) of $total_n memories are NOT loaded)"
    out="$out"$'\n'"$notice"
  else
    # Largest cap that fits. Binary search, not a scan: the search runs on every
    # session start. ~8 passes over 123 entries.
    lo=0; hi=$maxhook
    while [ "$lo" -lt "$hi" ]; do
      mid=$(( (lo + hi + 1) / 2 ))
      tot=$fixed
      for h in "${hooks[@]}"; do
        n=${#h}; [ "$n" -gt "$mid" ] && n=$mid
        tot=$(( tot + n ))
      done
      if [ "$tot" -le "$avail" ]; then lo=$mid; else hi=$(( mid - 1 )); fi
    done
    cap=$lo

    nab=0; lost=0; body2=""; i=0
    while [ "$i" -lt "${#prefixes[@]}" ]; do
      p="${prefixes[$i]}"; h="${hooks[$i]}"
      if [ "${#h}" -gt "$cap" ]; then
        lost=$(( lost + ${#h} - cap ))
        nab=$(( nab + 1 ))
        if [ "$cap" -ge 1 ]; then
          h="${h:0:$(( cap - 1 ))}…"
        else
          h=""; p="${p%" — "}"
        fi
      fi
      body2="$body2$p$h"$'\n'
      i=$(( i + 1 ))
    done
    total_n="$(grep -c '^- ' <<<"$body")"
    # Both forms carry the same phrase "$nab hooks abbreviated to $cap chars", so a
    # test (and a reader) can key on one string whichever fired.
    notice="… (all $total_n memories above are listed; $nab hooks abbreviated to $cap chars, $lost chars cut — read $idx for the full line)"
    [ "${#notice}" -le "$reserve" ] || notice="… ($nab of $total_n hooks abbreviated to $cap chars)"
    # $body2 already ends in a newline and `printf '%s\n'` adds the final one.
    out="$header"$'\n\n'"$body2""$notice"
  fi
fi
printf '%s\n' "$out"
exit 0
