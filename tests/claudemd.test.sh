#!/usr/bin/env bash
set -u
MD="$(cd "$(dirname "$0")/.." && pwd)/CLAUDE.md"
fail=0
need() { grep -qF "$1" "$MD" || { echo "FAIL: CLAUDE.md missing: $1"; fail=1; }; }

need "## Working directives"
need "memories/global/"
need "Would this help me in an unrelated project next week"
need "[[execution-verification-prefs]]"
need "[[feedback-spec-stated-rules-exactly]]"
# the new routing must point at the flat global store, not a per-project silo
grep -qF 'memories/claude1/' "$MD" && { echo "FAIL: stale per-project silo path still present"; fail=1; }

[ "$fail" = 0 ] && echo "PASS: claudemd" || exit 1
