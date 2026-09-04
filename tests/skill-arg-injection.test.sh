#!/usr/bin/env bash
# Pins bin/skill-arg-injection-guard.py against the MEASURED expander behaviour.
#
# Oracle (probe skill, args "zero one two three four INJECTED"):
#   $5 -> INJECTED | \$5 -> $5 | \\$5 -> \\INJECTED | \\\$5 -> \\\INJECTED
#   $1 -> one      | $9, $10 stayed literal ONLY because they exceeded argc
# So: safe IFF the backslash run immediately before the token is EXACTLY ONE.
#
# Every fixture is a COPY under mktemp; the tracked tree is never mutated, and the
# final assertion proves that. The mutant control likewise mutates a copy of the
# guard, never bin/skill-arg-injection-guard.py itself.
set -u
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
GUARD="$REPO/bin/skill-arg-injection-guard.py"
TREE_HASH_BEFORE=$(git -C "$REPO" hash-object "$GUARD")
FAILED=0

pass() { printf 'ok   %s\n' "$1"; }
fail() { printf 'FAIL %s\n' "$1"; FAILED=1; }
check() { # check <label> <want-ec> <got-ec>
  if [ "$2" = "$3" ]; then pass "$1 (ec=$3)"; else fail "$1 (want ec=$2, got ec=$3)"; fi
}

# --- fixture helper: one skill file holding $BODY, scanned in isolation ---------
scan_body() { # scan_body <body> -> echoes exit code
  local d; d=$(mktemp -d); mkdir -p "$d/s"
  printf '%s\n' "$1" > "$d/s/SKILL.md"
  python3 "$GUARD" "$d" >/dev/null 2>&1; local ec=$?
  rm -rf "$d"; echo "$ec"
}

# --- 1. EVERY leading digit is caught independently ----------------------------
# Kills the "[0-9] -> 5" mutant: a position-specific regex passes $5 but not $0..$9.
for d in 0 1 2 3 4 5 6 7 8 9; do
  check "bare \$$d is caught" 1 "$(scan_body "price is \$$d here")"
done

# --- 2. multi-digit index -------------------------------------------------------
# $10 is parsed as ONE index (measured), and is injectable whenever argc > 10.
check 'bare $10 is caught' 1 "$(scan_body 'tier costs $10 monthly')"

# --- 3. backslash-run table: EXACTLY ONE escapes --------------------------------
check 'run=0  ($5)     interpolates -> caught' 1 "$(scan_body 'a $5 b')"
check 'run=1  (\$5)    is the escape -> passes' 0 "$(scan_body 'a \$5 b')"
check 'run=2  (\\$5)   interpolates -> caught' 1 "$(scan_body 'a \\$5 b')"
check 'run=3  (\\\$5)  interpolates -> caught' 1 "$(scan_body 'a \\\$5 b')"

# --- 4. forms measured INERT must not be flagged (no false positives) -----------
check '${5} is inert -> passes'  0 "$(scan_body 'a ${5} b')"
check '$@ $* $# $? -> passes'    0 "$(scan_body 'args $@ $* $# and $?')"

# --- 5. backticks do NOT protect (measured) -------------------------------------
check 'backticked `$5` still caught' 1 "$(scan_body 'inline `$5` code')"

# --- 6. FAIL-CLOSED: an incomplete scan is never a pass -------------------------
python3 "$GUARD" /nonexistent/path/xyz >/dev/null 2>&1
check 'missing root fails closed' 2 "$?"

EMPTY=$(mktemp -d)
python3 "$GUARD" "$EMPTY" >/dev/null 2>&1
check 'zero files read fails closed' 2 "$?"
rm -rf "$EMPTY"

UNREAD=$(mktemp -d); mkdir -p "$UNREAD/s"
printf 'cost $5\n' > "$UNREAD/s/SKILL.md"; chmod 000 "$UNREAD/s/SKILL.md"
python3 "$GUARD" "$UNREAD" >/dev/null 2>&1; UNREAD_EC=$?
chmod 644 "$UNREAD/s/SKILL.md"; rm -rf "$UNREAD"
check 'unreadable file fails closed' 2 "$UNREAD_EC"

# --- 7. directory symlinks are followed (~/.claude/skills is a symlink farm) ----
FARM=$(mktemp -d); REAL=$(mktemp -d)
mkdir -p "$REAL/bad"; printf 'cost is $5\n' > "$REAL/bad/SKILL.md"
ln -s "$REAL/bad" "$FARM/bad"
python3 "$GUARD" "$FARM" >/dev/null 2>&1
check 'symlinked skill dir is traversed' 1 "$?"
rm -rf "$FARM" "$REAL"

# --- 8. the live tree is clean --------------------------------------------------
# Print the guard's own report on failure. This leg reads the LIVE skill tree, so
# any session's throwaway probe skill reddens it for every other session -- and a
# bare "expected ec=0 got ec=1" gives the next reader nothing to act on. Measured
# 2026-09-02: a temporary `zz-parity` probe skill failed this leg and was deleted
# before the failure was read, leaving an unreproducible red suite.
LIVE_OUT="$(python3 "$GUARD" 2>&1)"; LIVE_EC=$?
check 'live skill tree is clean' 0 "$LIVE_EC"
[ "$LIVE_EC" = 0 ] || printf '%s\n' "$LIVE_OUT" | sed 's/^/     /' 

# --- 9. MUTANT CONTROL: prove the suite can kill a weakened guard ---------------
# Mutate a COPY, never the tracked file. The mutant narrows [0-9] to 5 -- exactly
# the weakening the old single-example suite survived.
MUT=$(mktemp -d)
sed 's/\\\$\[0-9\]/\\$5/' "$GUARD" > "$MUT/mutant.py"
if cmp -s "$GUARD" "$MUT/mutant.py"; then
  fail 'mutant control: sed did not change anything (control is vacuous)'
else
  d=$(mktemp -d); mkdir -p "$d/s"; printf 'use $1 now\n' > "$d/s/SKILL.md"
  python3 "$GUARD" "$d" >/dev/null 2>&1; REAL_EC=$?
  python3 "$MUT/mutant.py" "$d" >/dev/null 2>&1; MUT_EC=$?
  rm -rf "$d"
  # The suite kills the mutant iff the two disagree on a token the mutant ignores.
  check 'real guard catches $1' 1 "$REAL_EC"
  check 'digit-specific mutant MISSES $1 (so assertion #2 kills it)' 0 "$MUT_EC"
fi
rm -rf "$MUT"

# --- 10. the guard mutated nothing ---------------------------------------------
if [ "$(git -C "$REPO" hash-object "$GUARD")" = "$TREE_HASH_BEFORE" ]; then
  pass 'guard did not mutate the tracked tree'
else
  fail 'guard did not mutate the tracked tree'
fi

echo "SUITE EXIT=$FAILED"
exit "$FAILED"
