#!/usr/bin/env bash
# Run every test in this repo and report one scoreboard.
#
# WHY THIS EXISTS. Measured 2026-09-01: the repo had 16 `*.test.sh` files, no CI workflow, and no
# runner -- so nothing ran them together and nothing noticed that one had been RED since 2026-08-30
# (tests/codex-profile-preflight.test.sh, refused by a policy gate added that day). A test nobody
# runs is not coverage; it is a file that looks like coverage.
#
#   tests/run-all.sh              # run everything
#   tests/run-all.sh -v           # ...and stream each suite's own output
#   tests/run-all.sh handoff      # run only suites whose path contains "handoff"
#
# Exit 0 iff every selected suite exited 0.
#
# The suite list is DERIVED from `git ls-files`, never hand-maintained, so a new test file is
# picked up by existing. The bound that leaves: a test file that is not tracked is not run --
# which is the intended reading of "the repo's tests", and is reported explicitly below so an
# untracked suite cannot hide as a silent pass.
set -u

REPO="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO" || exit 2

VERBOSE=0
FILTER=""
for a in "$@"; do
  case "$a" in
    -v|--verbose) VERBOSE=1 ;;
    -h|--help) sed -n '2,14p' "$0"; exit 0 ;;
    *) FILTER="$a" ;;
  esac
done

# Per-suite wall-clock ceiling. macOS has no timeout(1), so this is perl's alarm. It is generous
# on purpose: it exists to stop a hung suite pinning the runner forever, not to measure speed.
#
# Two details that are easy to get wrong and both fail toward a FALSE GREEN:
#  - After waitpid, `$?` is the raw wait status -- exit code in the high byte, terminating signal in
#    the low 7. `$? >> 8` is therefore 0 for ANY signal-killed child, so a suite an operator kills,
#    or the OOM killer takes, would print `ok`. Map a signal to 128+n the way a shell does.
#  - `kill 9, $p` reaps only `bash <suite>`. tests/handoff.test.sh backgrounds ~20 long-lived
#    `handoff.sh --watch` pollers; killing the leader alone orphans them to ppid 1, still armed and
#    still polling. Put the child in its own process group and signal the GROUP.
# 900s, not 600. Measured 2026-09-01 on an idle-ish Mac with ~13 sibling Claude sessions live:
# tests/handoff.test.sh takes 436s, which is 73% of a 600s cap -- and it is the suite that
# backgrounds ~20 pollers, so it is exactly the one that stretches under load. A ceiling here is
# a hang-stopper, not an assertion about speed, so buy the headroom; a TIMEOUT that means "the
# machine was busy" trains people to ignore the word.
SUITE_TIMEOUT="${RUN_ALL_TIMEOUT:-900}"
run_capped() {
  perl -e '
    use POSIX ();
    my $t = shift @ARGV;
    my $p = fork; if (!$p) { POSIX::setpgid(0, 0); exec @ARGV; exit 127 }
    POSIX::setpgid($p, $p);   # again in the parent, so neither side races the other
    $SIG{ALRM} = sub { kill(-9, $p) or kill(9, $p); exit 124 };
    alarm $t; waitpid($p, 0); my $st = $?;
    exit($st & 127 ? 128 + ($st & 127) : $st >> 8)
  ' "$SUITE_TIMEOUT" "$@"
}

# `mapfile` is bash 4+; macOS ships bash 3.2 as /bin/bash, so read the list the portable way.
SUITES=()
while IFS= read -r line; do SUITES+=("$line"); done < <(git ls-files '*.test.sh' | sort)
if [ "${#SUITES[@]}" -eq 0 ]; then
  echo "run-all: found no tracked *.test.sh -- refusing to report a green run over an empty set" >&2
  exit 2
fi

# Say out loud what the derived set does NOT cover, rather than letting it pass silently.
UNTRACKED="$(git ls-files --others --exclude-standard '*.test.sh' | sort)"
[ -n "$UNTRACKED" ] && {
  echo "note: not run (untracked, so not part of the repo's tests):"
  printf '%s\n' "$UNTRACKED" | sed 's/^/  /' 
  echo
}

PASS=0; FAIL=0; SKIP=0
FAILED=()
for s in "${SUITES[@]}"; do
  if [ -n "$FILTER" ] && [[ "$s" != *"$FILTER"* ]]; then SKIP=$((SKIP+1)); continue; fi
  start=$SECONDS
  if [ "$VERBOSE" -eq 1 ]; then
    echo "==== $s"
    run_capped bash "$s"; rc=$?
  else
    out="$(run_capped bash "$s" 2>&1)"; rc=$?
  fi
  el=$((SECONDS-start))
  if [ "$rc" -eq 0 ]; then
    PASS=$((PASS+1)); printf 'ok    %-46s %3ss\n' "$s" "$el"
  else
    FAIL=$((FAIL+1)); FAILED+=("$s")
    if [ "$rc" -eq 124 ]; then
      printf 'TIMEOUT %-44s %3ss (capped at %ss)\n' "$s" "$el" "$SUITE_TIMEOUT"
    else
      printf 'FAIL  %-46s %3ss (exit %s)\n' "$s" "$el" "$rc"
    fi
    [ "$VERBOSE" -eq 0 ] && printf '%s\n' "$out" | tail -20 | sed 's/^/      /'
  fi
done

echo "----"
echo "$PASS passed, $FAIL failed$([ "$SKIP" -gt 0 ] && echo ", $SKIP not selected") of ${#SUITES[@]} tracked suites"
if [ "$FAIL" -gt 0 ]; then
  printf 'failed: %s\n' "${FAILED[*]}"
  exit 1
fi
exit 0
