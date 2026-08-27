#!/usr/bin/env bash
# sync.sh runs unattended from launchd/systemd, so a git failure it swallows is
# a failure nobody ever sees: the repo silently stops syncing while every new
# session still believes it is current. It previously ran every git step as
# `... 2>/dev/null || true`, which made a rebase conflict between two machines
# indistinguishable from a clean no-op.
#
# These tests pin the contract: real failures exit non-zero, say why, and leave
# the repository mid-operation so it can be diagnosed — while the two states
# that are NOT failures (nothing to do, and being offline) stay quiet and exit 0.
set -u
REPO="$(cd "$(dirname "$0")/.." && pwd)"
fail=0

SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT

# sync.sh resolves its repo from its own location and writes its log to a
# per-OS state dir, so each case gets a throwaway HOME and a copied script.
export HOME="$SANDBOX/home"
mkdir -p "$HOME"

# ...and its own $TMPDIR. sync.sh puts its lock -- and the mail-dedupe stamp --
# under ${TMPDIR:-/tmp}, which is MACHINE-GLOBAL: any second sync on the box,
# another suite's or the real one's, makes the runs below exit 0 having done and
# logged nothing, and the assertions then fail for a reason that has nothing to
# do with the code under test. A sandbox TMPDIR gives this suite its own lock
# namespace -- and stops it deleting a lock a LIVE sync is holding.
export TMPDIR="$SANDBOX/tmp"
mkdir -p "$TMPDIR"
case "$(uname)" in
  Darwin) LOG_FILE="$HOME/Library/Logs/claude-config-sync.log" ;;
  *)      LOG_FILE="$HOME/.local/state/claude-config-sync.log" ;;
esac

git init -q --bare "$SANDBOX/remote.git"

# A clone that carries its own copy of the script under test.
make_clone() {
  git clone -q "$SANDBOX/remote.git" "$SANDBOX/$1"
  git -C "$SANDBOX/$1" config user.email "$1@test"
  git -C "$SANDBOX/$1" config user.name  "$1"
  cp "$REPO/sync.sh" "$SANDBOX/$1/sync.sh"
  # sync.sh refuses to push unless bin/remote-visibility.sh can tell it the remote is not
  # world-readable, and a missing helper is itself a refusal. A clone without bin/ would test a
  # broken install, not the script.
  mkdir -p "$SANDBOX/$1/bin"
  cp "$REPO/bin/remote-visibility.sh" "$SANDBOX/$1/bin/remote-visibility.sh"
}

# Each run needs its own lock dir, or the second call exits 0 as "another run
# holds the lock" and the assertion below would pass for the wrong reason.
run_sync() {
  rm -rf "${TMPDIR:-/tmp}/claude-config-sync.lock.d"
  ( cd "$SANDBOX/$1" && bash ./sync.sh >"$SANDBOX/out.$1" 2>&1 )
}

check() {
  if [ "$1" = "$2" ]; then echo "  ok: $3"; else
    echo "FAIL: $3 (expected '$2', got '$1')"; fail=1
  fi
}

make_clone a
printf 'one\n' > "$SANDBOX/a/CLAUDE.md"
git -C "$SANDBOX/a" add -A && git -C "$SANDBOX/a" commit -qm init
git -C "$SANDBOX/a" push -q origin HEAD:main
git -C "$SANDBOX/a" branch -q --set-upstream-to=origin/main 2>/dev/null

echo "case 1: a local edit commits and pushes, exit 0"
printf 'two\n' >> "$SANDBOX/a/CLAUDE.md"
run_sync a; check "$?" 0 "clean sync exits 0"
# Matches the log line `pushed <short-sha>`, not the bare word: the push-refusal message also
# contains "pushed", which made this assertion pass on a run that pushed nothing.
grep -qE 'pushed [0-9a-f]{7,}' "$LOG_FILE" 2>/dev/null \
  && echo "  ok: logged the push" || { echo "FAIL: no push logged"; fail=1; }

echo "case 2: nothing to do stays quiet, exit 0"
run_sync a; check "$?" 0 "no-op sync exits 0"

echo "case 3: a conflicting edit on another machine FAILS LOUDLY"
make_clone b
git -C "$SANDBOX/b" config user.email b@test
# Both machines change the same line; b pushes first, so a's sync must rebase
# onto a conflicting commit.
printf 'from-b\n' > "$SANDBOX/b/CLAUDE.md"
git -C "$SANDBOX/b" commit -qam "b edit"
git -C "$SANDBOX/b" push -q
printf 'from-a\n' > "$SANDBOX/a/CLAUDE.md"
run_sync a; rc=$?
check "$rc" 1 "conflicting sync exits non-zero"
grep -q 'FAILED' "$LOG_FILE" 2>/dev/null \
  && echo "  ok: logged FAILED" || { echo "FAIL: conflict not logged as FAILED"; fail=1; }
grep -qi 'conflict' "$SANDBOX/out.a" \
  && echo "  ok: told the user it was a conflict" \
  || { echo "FAIL: stderr did not name the conflict"; cat "$SANDBOX/out.a"; fail=1; }

echo "case 4: the conflicted state is LEFT IN PLACE, not auto-aborted"
gd="$(git -C "$SANDBOX/a" rev-parse --git-dir)"
if [ -e "$SANDBOX/a/$gd/rebase-merge" ] || [ -e "$SANDBOX/a/$gd/rebase-apply" ]; then
  echo "  ok: rebase left in progress for diagnosis"
else
  echo "FAIL: the interrupted rebase was discarded; the evidence is gone"; fail=1
fi

echo "case 5: a repo already mid-rebase is refused, not compounded"
run_sync a; rc=$?
check "$rc" 1 "sync on an unfinished rebase exits non-zero"
grep -qi 'unfinished' "$SANDBOX/out.a" \
  && echo "  ok: named the unfinished operation" \
  || { echo "FAIL: did not name the unfinished operation"; cat "$SANDBOX/out.a"; fail=1; }

echo "case 6: being offline is NOT a failure"
git -C "$SANDBOX/a" rebase --abort 2>/dev/null
git -C "$SANDBOX/a" remote set-url origin "$SANDBOX/does-not-exist.git"
run_sync a; check "$?" 0 "unreachable remote exits 0"
grep -q 'offline or remote unreachable' "$LOG_FILE" 2>/dev/null \
  && echo "  ok: logged the skip" || { echo "FAIL: offline skip not logged"; fail=1; }

[ "$fail" -eq 0 ] && echo "PASS: sync failures are visible and diagnosable"
exit "$fail"
