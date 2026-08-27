#!/usr/bin/env bash
set -u
REPO=~/dotfiles/claude
fail=0
# 1. Every global index pointer resolves to a body (or is a tombstone alias).
while IFS= read -r slug; do
  [ -f "$REPO/memories/global/$slug" ] || { echo "FAIL: dangling pointer $slug"; fail=1; }
done < <(grep -oE '\]\([a-z0-9-]+\.md\)' "$REPO/memories/global/MEMORY.md" | sed -E 's/\]\((.*)\)/\1/' | sort -u)

# 2. No slug appears in BOTH a project MEMORY.md and the global index.
for pm in "$HOME"/.claude*/projects/*/memory/MEMORY.md; do
  [ -f "$pm" ] || continue
  while IFS= read -r b; do
    grep -qF "$b" "$REPO/memories/global/MEMORY.md" && { echo "FAIL: double-listed $b"; fail=1; }
  done < <(grep -oE '\]\([a-z0-9-]+\.md\)' "$pm" | sed -E 's/\]\((.*)\)/\1/')
done
[ "$fail" = 0 ] && echo "PASS: migration-verify" || exit 1
