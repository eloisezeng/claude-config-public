#!/usr/bin/env bash
# Run a suite against a MUTATED COPY of the code under test.
#
#   ./mutate.sh fleet 's|exec "$CLAUDE" agents --cwd "$cwd"|exec /usr/bin/false|'
#   ./mutate.sh ext   's|isTransient: true|isTransient: false|'
#   ./mutate.sh watch '21s#, 60)#, 600)#'   # fleet-watch.mjs, the WATCH pane's viewer
#   ./mutate.sh tail  '17s#|| 12#|| 2#'     # fleet-tail.mjs,  the READ pane's viewer
#
# The copy is the whole point. This repo auto-commits AND pushes on every Stop, so a
# mutant armed in the tracked tree gets published: on 2026-08-21 commit 63e1448 shipped
# `exec /usr/bin/false` to origin/main because a sync fired inside a mutation window.
# Both suites already take the code under test as a PATH -- $FLEET_BIN and $EXT -- so
# nothing has to be armed in place; this script is those parameters used correctly.
set -euo pipefail
[ $# -ge 2 ] || { echo "usage: $0 fleet|ext|watch|tail '<sed expression>' [more...]" >&2; exit 2; }
target="$1"; shift
here="$(cd "$(dirname "$0")" && pwd)"
ext="$(dirname "$here")"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT

case "$target" in
  fleet) src="$(cd "$here/../../../bin" && pwd)/fleet"; cp "$src" "$tmp/fleet"; mut="$tmp/fleet" ;;
  ext)   src="$ext/extension.js"; cp "$src" "$tmp/extension.js"; cp "$ext/package.json" "$tmp/"
         mut="$tmp/extension.js" ;;
  # The two read-only viewers. `fleet` resolves them as "$HOME/.claude/bin/<name>", so
  # mutating one means giving the fixture a whole bin DIRECTORY to point $HOME/.claude/bin
  # at -- copying the single file would leave the pane running the real one. Without this
  # the READ and WATCH panes were unmutable, i.e. unverifiable.
  watch|tail)
         bindir="$(cd "$here/../../../bin" && pwd)"
         cp -R "$bindir" "$tmp/bin"
         case "$target" in watch) f=fleet-watch.mjs ;; tail) f=fleet-tail.mjs ;; esac
         src="$bindir/$f"; mut="$tmp/bin/$f" ;;
  *)     echo "unknown target '$target' (want: fleet | ext | watch | tail)" >&2; exit 2 ;;
esac
# Digest the tracked file BEFORE arming, so the "unchanged" line below is an assertion
# and not a tautology.
before="$(/usr/bin/shasum -a 256 "$src" | awk '{print $1}')"

for e in "$@"; do sed -i '' "$e" "$mut"; done
if cmp -s "$src" "$mut"; then
  echo "mutate: the expression changed NOTHING -- a mutant that is not armed always survives." >&2
  exit 2
fi
echo "--- mutant armed in $mut (tracked copy untouched) ---"
case "$target" in
  fleet) FLEET_BIN="$mut" /usr/bin/python3 "$here/fleet-open-pty.py" || true ;;
  watch|tail)
    FLEET_BIN="$tmp/bin/fleet" FLEET_BIN_DIR="$tmp/bin" \
      /usr/bin/python3 "$here/fleet-open-pty.py" || true ;;
  ext)   EXT="$tmp" NODE_PATH="$here/node_modules" node "$here/run.js" || true ;;
esac
# Prove the tracked file was never in play, so a green run cannot be a false negative.
# This used to read `cmp -s "$src" "$src"` -- a file compared with itself, which is equal
# by construction: the marker every ledger quotes as [tracked-unchanged=1] could not have
# failed. Digest before, digest after, and say so loudly if they differ.
after="$(/usr/bin/shasum -a 256 "$src" | awk '{print $1}')"
if [ "$before" != "$after" ]; then
  echo "!!! TRACKED $target CHANGED: $before -> $after" >&2
  exit 3
elif [ -e "$src.orig" ]; then
  echo "!!! sed left a backup beside the tracked file: $src.orig" >&2
  exit 3
else
  echo "--- tracked $target unchanged ---"
fi
