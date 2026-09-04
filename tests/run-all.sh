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

# A test process is NOT one of loop.py's ledgered jobs. When this runner is itself launched
# under `loop.py run` -- which is how a convergence arc runs its suites -- CC_LOOP_JOB and
# CC_LOOP_ARC are exported into every descendant, and run-codex.sh verifies that handshake
# against the ledger's recorded parent pid. Inside a test that pid is the runner's, never the
# test's, so every run-codex.sh invocation refuses with "unverified inner handshake" and the
# suite reddens with five failures about nothing it tests. Measured 2026-09-03. The refusal is
# correct; inheriting somebody else's job identity is the defect. Scrub it once, here, so the
# scoreboard measures the repo rather than the harness that ran it.
unset CC_LOOP_JOB CC_LOOP_ARC CC_ARC CC_TRACK CC_ROUND

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

# The selected set is derived BEFORE anything runs, and an empty one is refused.
#
# The filter used to be applied inside the loop, so a filter matching nothing simply skipped every
# suite and fell through to the scoreboard with PASS=0 FAIL=0 -- and the only failure test is
# `[ "$FAIL" -gt 0 ]`, so `tests/run-all.sh __no_such_suite__` printed "0 passed, 0 failed, 24 not
# selected" and exited 0. That is the zero-match false green this repo exists to prevent, one level
# up: a typo'd filter in a wrapper or a CI line reports a green run over nothing at all. There is no
# reading of "run the suites matching X" under which matching none is success.
SELECTED=()
for s in "${SUITES[@]}"; do
  if [ -n "$FILTER" ] && [[ "$s" != *"$FILTER"* ]]; then continue; fi
  SELECTED+=("$s")
done
SKIP=$(( ${#SUITES[@]} - ${#SELECTED[@]} ))
if [ "${#SELECTED[@]}" -eq 0 ]; then
  echo "run-all: filter '$FILTER' selected 0 of ${#SUITES[@]} tracked suites -- refusing to report a green run over an empty selection" >&2
  echo "run-all: tracked suites are:" >&2
  printf '%s\n' "${SUITES[@]}" | sed 's/^/  /' >&2
  exit 2
fi

PASS=0; FAIL=0
FAILED=()
for s in "${SELECTED[@]}"; do
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
    # A bare tail is not a diagnosis. tests/handoff.test.sh tears down ~20 seat
    # processes, and each shell job-control notice ("Terminated: 15") reprints the
    # seat's whole inline script -- about 12 lines apiece. Measured 2026-09-02: a
    # real FAIL line sat far above a 20-line tail window, so the runner reported a
    # failure while showing none of its cause, and the suite passed when re-run by
    # hand. Print the assertion markers FIRST -- they are the only lines a reader
    # can act on -- and keep the tail after them for context.
    if [ "$VERBOSE" -eq 0 ]; then
      marks="$(printf '%s\n' "$out" | grep -nE '^[[:space:]]*(FAIL|not ok|ERROR|Assertion)' | head -15)"
      if [ -n "$marks" ]; then
        printf '%s\n' "$marks" | sed 's/^/      /'
        printf '      -- (line numbers are into the suite'"'"'s own output; tail follows)\n'
      else
        printf '      -- (no FAIL/ERROR marker in the output; the suite exited %s on its own)\n' "$rc"
      fi
      printf '%s\n' "$out" | tail -20 | sed 's/^/      /'
    fi
  fi
done

echo "----"
echo "$PASS passed, $FAIL failed$([ "$SKIP" -gt 0 ] && echo ", $SKIP not selected") of ${#SUITES[@]} tracked suites"
# A selected suite that neither passed nor failed means the loop did not run it -- report
# that rather than letting the FAIL test below decide the exit status over a short count.
if [ $((PASS + FAIL)) -ne "${#SELECTED[@]}" ]; then
  echo "run-all: only $((PASS + FAIL)) of ${#SELECTED[@]} selected suites reported a result" >&2
  exit 2
fi
if [ "$FAIL" -gt 0 ]; then
  printf 'failed: %s\n' "${FAILED[*]}"
  exit 1
fi
exit 0
