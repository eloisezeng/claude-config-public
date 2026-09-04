#!/usr/bin/env bash
# codex-loop.test.sh — the scheduler behind run-codex.sh.
#
# Measured 2026-09-01 (job c5092014, `profile-arc.txt`): 7h34m of a 23h arc was review /
# `--write` waiting with NOTHING else in flight, two full vitest suites and a tsc fought each
# other for the CPU, and a 1h14m gap had no artifact at all.  The profiler saw all of it and
# printed advice.  loop.py turns that advice into mechanism: every launch is attributed
# (arc → track → round), CPU-heavy jobs serialise on a lock, readers and writers of one tree
# serialise, a verdict whose tree moved under it is quarantined, and a new round cannot start
# until the previous one is closed and its TRIGGERED levers dispositioned.
#
# These tests drive the REAL launcher with a stub `codex` (no spend) and then arm mutants on
# loop.py — on a COPY under mktemp, never in this tree, which auto-commits on any change.
set -u
REPO="$(cd "$(dirname "$0")/.." && pwd)"
SKILL="$REPO/skills/codex-converge"
RUN="$SKILL/run-codex.sh"
fail=0

SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT
export CODEX_HOME="$SANDBOX/codex"
mkdir -p "$CODEX_HOME" "$SANDBOX/art" "$SANDBOX/bin" "$SANDBOX/arc" "$SANDBOX/plain"
printf 'model = "gpt-5.6-sol"\nmodel_reasoning_effort = "high"\n' > "$CODEX_HOME/sol.config.toml"
printf 'prompt\n' > "$SANDBOX/prompt.txt"
cat > "$SANDBOX/bin/codex" <<'STUB'
#!/bin/sh
: > "$CODEX_STUB_MARKER"
out=""; prev=""
for a in "$@"; do
  [ "$prev" = "-o" ] && out="$a"
  prev="$a"
done
# The banner is what the tier check reads. It is suppressible so a run with NO banner -- codex
# writing JSONL, or a build that stops printing it -- is reachable from a test; without that, the
# fail-closed branch of the tier check has no probe and only its happy path is ever exercised.
if [ -z "${CODEX_STUB_NO_BANNER:-}" ]; then
  echo "model: ${CODEX_STUB_MODEL:-gpt-5.6-sol}"
  echo "reasoning effort: ${CODEX_STUB_EFFORT:-high}"
fi
echo 1 >> "$CODEX_STUB_MARKER.count"
case "${CODEX_STUB_MODE:-}" in
  quote-fail)
    # a reviewer quoting this launcher's own classifier into its transcript (2026-09-02, lifecycle lens)
    printf '   290\t  grep -qi '"'"'^error: unexpected argument\\|unrecognized subcommand'"'"' "$LOG"\n'
    i=0; while [ $i -lt 120 ]; do echo "reasoning line $i"; i=$((i+1)); done
    echo "error: unrecognized subcommand 'quoted-late-in-the-log'"
    exit 1 ;;
  cli-error)
    echo "error: unrecognized subcommand 'exec'"
    exit 2 ;;
  # The three off-diagonal quadrants of run-codex.sh's verdict-promotion test (section 34). Each
  # is a real shape codex produces: a run that answered and then failed, a run that exited clean
  # having written nothing, and a run that exited clean leaving a zero-byte file behind.
  fail-with-output)
    [ -n "$out" ] && printf '{"ok":true}\n' > "$out"
    exit 3 ;;
  no-output)
    exit 0 ;;
  empty-output)
    [ -n "$out" ] && : > "$out"
    exit 0 ;;
  # The two watchdog shapes (section 49). `silent` writes the banner and then nothing at all, which
  # is what a wedged `codex exec` looks like from outside. `chatty` keeps writing for longer than
  # the stall budget, which is what a healthy long run looks like -- and is the control that stops
  # the watchdog test passing under a detector that kills EVERYTHING.
  silent)
    sleep "${CODEX_STUB_SLEEP:-30}"
    [ -n "$out" ] && printf '{"ok":true}\n' > "$out"
    exit 0 ;;
  chatty)
    i=0
    while [ $i -lt "${CODEX_STUB_TICKS:-8}" ]; do echo "tick $i"; sleep 1; i=$((i+1)); done
    [ -n "$out" ] && printf '{"ok":true}\n' > "$out"
    exit 0 ;;
esac
[ -n "${CODEX_STUB_TOUCH:-}" ] && : > "$CODEX_STUB_TOUCH"
[ -n "$out" ] && printf '{"ok":true}\n' > "$out"
exit 0
STUB
chmod +x "$SANDBOX/bin/codex"
export PATH="$SANDBOX/bin:$PATH"
export CODEX_STUB_MARKER="$SANDBOX/codex-was-invoked"
export CC_LOCK_DIR="$SANDBOX/locks"
unset CC_ARC CC_TRACK CC_ROUND CLAUDE_JOB_DIR CODEX_STUB_TOUCH CODEX_STUB_MODE CC_LOOP_JOB CC_LOOP_ARC CODEX_STUB_EFFORT
unset CODEX_STUB_NO_BANNER CODEX_STUB_MODEL CODEX_STUB_SLEEP CODEX_STUB_TICKS CC_ONEOFF_ARC
unset RUN_CODEX_POLL RUN_CODEX_IDLE_WINDOW RUN_CODEX_STALL_LIMIT
POLICY="$(sed -n 's/^POLICY_VERSION="\(.*\)"$/\1/p' "$RUN")"
ARC="$SANDBOX/arc"
LEDGER="$ARC/jobs.jsonl"

WORK="$SANDBOX/work"
git init -q "$WORK"
git -C "$WORK" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init

ok()  { echo "ok   - $1"; }
bad() { echo "FAIL - $1"; fail=1; }
check() { local what="$1"; shift; if "$@"; then ok "$what"; else bad "$what"; fi; }
ledger_has() { [ -f "$LEDGER" ] && grep -q -- "$1" "$LEDGER"; }

# Round 1 of a real arc is GATED on an efficiency preflight: loop.py refuses a round-1 review or
# write in an arc that has none, because a boundary profiler cannot fire until a round is paid for.
# Every fixture arc here that launches such a job records one, so the suite exercises the scheduler
# rather than the gate. Guarded on the subcommand existing so this harness still runs green against
# a loop.py predating it.
preflight_arc() {
  python3 "$SKILL/loop.py" preflight --help >/dev/null 2>&1 || return 0
  python3 "$SKILL/loop.py" preflight --arc="$1" \
    --critical-path='the stub codex run itself; nothing else is in flight in this harness' \
    --parallel='the three lens tracks launch together against one frozen sha' \
    --batch='all checks in one process; the mutation batches run one interpreter per mutant' \
    --scope='only run-codex.sh, loop.py and mutate.py -- this suite reviews nothing else' \
    --stop='at most 1 full pass of this file; the FAILURES line is the bound' \
    --drivers='interpreter start-up and the deliberate sleeps; no model spend (codex is a stub)' \
    --codex-unavailable='a test fixture never calls a model' >/dev/null || {
    # Loud on purpose. A refused preflight leaves every round-1 review in this suite gated at rc 6,
    # which reads as a dozen unrelated scheduler failures with no cause printed anywhere -- the
    # fail-open reporting shape. Print the refusal and stop instead of debugging the symptom.
    echo "FATAL - the harness's own preflight was REFUSED for arc $1; every gated check below would" >&2
    echo "        fail at rc 6 with no cause. loop.py's refusal:" >&2
    python3 "$SKILL/loop.py" preflight --arc="$1" \
      --critical-path='the stub codex run itself; nothing else is in flight in this harness' \
      --parallel='the three lens tracks launch together against one frozen sha' \
      --batch='all checks in one process; the mutation batches run one interpreter per mutant' \
      --scope='only run-codex.sh, loop.py and mutate.py -- this suite reviews nothing else' \
      --stop='at most 1 full pass of this file; the FAILURES line is the bound' \
      --drivers='interpreter start-up and the deliberate sleeps; no model spend (codex is a stub)' \
      --codex-unavailable='a test fixture never calls a model' >&2
    exit 1
  }
}
preflight_arc "$ARC"

ledger_untouched() { cmp -s "$SANDBOX/ledger.before" "$LEDGER" 2>/dev/null || [ ! -e "$LEDGER" ]; }

# launch [launcher flags...] -- [codex-args...]; positionals are fixed so a case reads as its flags
launch() {
  local flags=()
  while [ "$#" -gt 0 ] && [ "$1" != "--" ]; do flags+=("$1"); shift; done
  [ "$#" -gt 0 ] && shift
  rm -f "$CODEX_STUB_MARKER" "$CODEX_STUB_MARKER.count" "$SANDBOX/art/out.json" "$SANDBOX/art/out.json.tree-moved"
  # "recorded nothing" cannot mean "the ledger file is absent" any more: the arc's preflight is a
  # ledger record, and it is written before the first launch by design (round 1 is gated on it).
  # Snapshot instead, so ledger_untouched below asserts the launch added no event of its own.
  cp "$LEDGER" "$SANDBOX/ledger.before" 2>/dev/null || : > "$SANDBOX/ledger.before"
  bash "$RUN" --policy-version "$POLICY" ${flags[@]+"${flags[@]}"} \
       "$SANDBOX/prompt.txt" "$SANDBOX/art/out.json" "$SANDBOX/art/run.log" "${WORKDIR:-$WORK}" "$@" \
       >"$SANDBOX/stdout" 2>"$SANDBOX/stderr"
}

# --- 1. an unattributed launch is refused before codex is spent
launch -- -p sol; rc=$?
check "unattributed launch refused (rc 2, got $rc)" [ "$rc" -eq 2 ]
check "unattributed launch never invoked codex" [ ! -e "$CODEX_STUB_MARKER" ]
check "refusal names the way out (--one-off)" grep -q -- '--one-off' "$SANDBOX/stderr"
check "unattributed launch added no ledger event" ledger_untouched

# --- 2. --one-off is the explicit unscheduled path: runs, records nothing
launch --one-off -- -p sol; rc=$?
check "--one-off runs (rc 0, got $rc)" [ "$rc" -eq 0 ]
check "--one-off invoked codex and landed the verdict" [ -e "$CODEX_STUB_MARKER" ] && [ -s "$SANDBOX/art/out.json" ]
check "--one-off added no ledger event" ledger_untouched

# --- 3. an attributed launch runs through loop.py and is ledgered
launch --arc "$ARC" --track A --round 1 -- -p sol; rc=$?
check "attributed launch runs (rc 0, got $rc)" [ "$rc" -eq 0 ]
check "attributed launch landed the verdict" [ -s "$SANDBOX/art/out.json" ]
check "ledger has the start event as a review" ledger_has '"ev": "start".*"kind": "review"'
check "ledger names the job after the verdict file" ledger_has '"name": "out"'
check "ledger has the end event with rc 0" ledger_has '"ev": "end".*"rc": 0'
check "ledger records the tree did not move" ledger_has '"tree_moved": false'
check "ledger attributes track A round 1" ledger_has '"round": 1.*"track": "A"'

# --- 4. attribution may come from the environment
CC_ARC="$ARC" CC_TRACK=B CC_ROUND=1 launch -- -p sol; rc=$?
check "env-attributed launch runs (rc 0, got $rc)" [ "$rc" -eq 0 ]
check "env attribution reached the ledger" ledger_has '"track": "B"'

# --- 5. a bad round number is a usage error, not a launch
launch --arc "$ARC" --track A --round r1 -- -p sol; rc=$?
check "non-numeric --round refused (rc 2, got $rc)" [ "$rc" -eq 2 ]
check "non-numeric --round never invoked codex" [ ! -e "$CODEX_STUB_MARKER" ]

# --- 6. the round gate: round 2 cannot launch while round 1 is open
launch --arc "$ARC" --track A --round 2 -- -p sol; rc=$?
check "round 2 refused while round 1 is open (rc 6, got $rc)" [ "$rc" -eq 6 ]
check "gate refusal never invoked codex" [ ! -e "$CODEX_STUB_MARKER" ]
check "gate refusal names the owed close-round" grep -q 'close-round' "$SANDBOX/stderr"

python3 "$SKILL/loop.py" close-round --arc "$ARC" --track A --round 1 >"$SANDBOX/close.out" 2>&1; rc=$?
check "close-round on a ledgered round succeeds (rc 0, got $rc)" [ "$rc" -eq 0 ]
check "close-round wrote the round profile" [ -s "$ARC/rounds/A/r1/profile.txt" ] && [ -s "$ARC/rounds/A/r1/levers.json" ]
# disposition whatever was TRIGGERED (a tiny arc usually triggers nothing; the gate must hold either way)
for lid in $(python3 -c "import json,sys;print(' '.join(l['id'] for l in json.load(open(sys.argv[1])) if l['triggered']))" "$ARC/rounds/A/r1/levers.json"); do
  python3 "$SKILL/loop.py" lever --arc "$ARC" --track A --round 1 --id "$lid" --state declined --note "test arc: nothing to land" >/dev/null 2>&1 || bad "lever disposition $lid"
done
launch --arc "$ARC" --track A --round 2 -- -p sol; rc=$?
check "round 2 runs once round 1 is closed and dispositioned (rc 0, got $rc)" [ "$rc" -eq 0 ]
check "track B stays gated independently (rc 6)" bash -c "python3 '$SKILL/loop.py' gate --arc '$ARC' --track B --round 2 >/dev/null 2>&1; [ \$? -eq 6 ]"

# --- 7. a verdict whose tree moved while it was read is quarantined, through the real launcher
CODEX_STUB_TOUCH="$WORK/stray-write" launch --arc "$ARC" --track A --round 2 -- -p sol; rc=$?
check "tree moved under the review → rc 5 (got $rc)" [ "$rc" -eq 5 ]
check "moved-tree verdict is not left at its promised path" [ ! -e "$SANDBOX/art/out.json" ]
check "moved-tree verdict is quarantined as .tree-moved" [ -e "$SANDBOX/art/out.json.tree-moved" ]
check "ledger records tree_moved true" ledger_has '"tree_moved": true'
rm -f "$WORK/stray-write"

# --- 8. a non-git workdir is still scheduled (attributed, CPU-classed), just without a tree lock
WORKDIR="$SANDBOX/plain" launch --arc "$ARC" --track C --round 1 -- -p sol; rc=$?
check "non-git workdir launches attributed without a tree (rc 0, got $rc)" [ "$rc" -eq 0 ]
check "non-git launch reached the ledger" ledger_has '"track": "C"'

# --- 9. --write is ledgered as a write (the inner launcher's own worktree guards still apply)
launch --write --arc "$ARC" --track D --round 1 -- -p sol; rc=$?
check "--write launch is ledgered as kind write" ledger_has '"kind": "write".*"track": "D"'

# --- 10. profile-loop.sh delegates to the same profiler
bash "$SKILL/profile-loop.sh" "$ARC" >"$SANDBOX/profile.out" 2>&1; rc=$?
check "profile-loop.sh delegates (rc 0, got $rc)" [ "$rc" -eq 0 ]
check "profile reports the lever table" grep -q '== levers' "$SANDBOX/profile.out"
check "profile reports every ledgered track" bash -c "grep -q 'track A round 1' '$SANDBOX/profile.out' && grep -q 'track C round 1' '$SANDBOX/profile.out'"

# --- 13. the inner handshake cannot be forged: not by a flag, not by the environment
launch --scheduled --arc "$ARC" --track A --round 2 -- -p sol; rc=$?
check "external --scheduled is refused (rc 2, got $rc)" [ "$rc" -eq 2 ]
check "external --scheduled never invoked codex" [ ! -e "$CODEX_STUB_MARKER" ]
CC_LOOP_JOB=forged CC_LOOP_ARC="$ARC" launch --arc "$ARC" --track A --round 2 -- -p sol; rc=$?
check "forged CC_LOOP_JOB with no ledger start event is refused (rc 2, got $rc)" [ "$rc" -eq 2 ]
check "forged handshake never invoked codex" [ ! -e "$CODEX_STUB_MARKER" ]
check "forged handshake names the unverified handshake" grep -q 'unverified inner handshake' "$SANDBOX/stderr"
realjob="$(python3 -c "import json,sys;print([json.loads(l)['job'] for l in open(sys.argv[1]) if json.loads(l).get('ev')=='start'][-1])" "$LEDGER")"
CC_LOOP_JOB="$realjob" CC_LOOP_ARC="$ARC" launch --arc "$ARC" --track A --round 2 -- -p sol; rc=$?
check "a REAL ledgered job id replayed from another parent is refused (rc 2, got $rc)" [ "$rc" -eq 2 ]
check "replayed handshake never invoked codex" [ ! -e "$CODEX_STUB_MARKER" ]
check "the genuine inner handshake is in the ledger (pid recorded on start)" ledger_has '"ev": "start".*"pid": [0-9]'

# --- 14. the non-retryable classifier: anchored CLI errors from the log HEAD only
CODEX_STUB_MODE=quote-fail launch --one-off -- -p sol; rc=$?
check "a quoted 'unrecognized subcommand' is NOT non-retryable (rc non-zero after retries, got $rc)" [ "$rc" -ne 0 ]
check "quoted phrase: all 3 attempts were made ($(wc -l < "$CODEX_STUB_MARKER.count" 2>/dev/null) invocations)" [ "$(wc -l < "$CODEX_STUB_MARKER.count")" -eq 3 ]
check "quoted phrase: never classified non-retryable" bash -c "! grep -q 'non-retryable' '$SANDBOX/stderr' '$SANDBOX/art/run.log'"
CODEX_STUB_MODE=cli-error launch --one-off -- -p sol; rc=$?
check "control: a real CLI usage error at line 1 IS non-retryable (rc $rc)" [ "$rc" -ne 0 ]
check "control: exactly 1 attempt ($(wc -l < "$CODEX_STUB_MARKER.count" 2>/dev/null) invocations)" [ "$(wc -l < "$CODEX_STUB_MARKER.count")" -eq 1 ]
check "control: classified non-retryable" grep -q 'non-retryable' "$SANDBOX/stderr" "$SANDBOX/art/run.log"

# --- 11. loop.py's own suite
python3 "$SKILL/loop_test.py" >"$SANDBOX/unit.out" 2>&1; rc=$?
check "loop_test.py green (rc 0, got $rc)" [ "$rc" -eq 0 ]
check "loop_test.py prints a vitest-shaped summary (so mutate.py's zero-match guard applies to it)" grep -q '^Tests  [0-9]* passed' "$SANDBOX/unit.out"

# --- 12. mutation: every fail-closed rule dies under its NAMED test, armed on a COPY
before="$(shasum -a 256 "$SKILL/loop.py" "$SKILL/loop_test.py" | shasum -a 256)"
# Pinned ONCE, here, before any probe runs. The section-16 assertion below used to compute this
# hash and then compare it against the same expression evaluated a second time — a comparison of
# a value with itself, which passes however badly the probes corrupt the skill directory.
before_all="$(shasum -a 256 "$SKILL/loop.py" "$SKILL/loop_test.py" "$SKILL/mutate.py" | shasum -a 256)"
suite_started="$(date +%H:%M:%S)"
# A --test-cmd standing in for a real suite. It must reach the COPY ({test}) AND report a
# vitest-shaped summary: mutate.py now refuses a run that executed zero tests, and demands a
# green baseline before arming anything, so a bare `true` is (correctly) no longer accepted.
GREEN_CMD='printf "Tests  1 passed (1)\n"; true {test}'
MUT="$SANDBOX/mut"; mkdir -p "$MUT"
cp "$SKILL/loop.py" "$SKILL/loop_test.py" "$SKILL/mutate.py" "$MUT/"
python3 "$MUT/mutate.py" --root "$MUT" --src loop.py --test loop_test.py --copy-dir copy \
  --mutants "$SKILL/loop.mutants.json" --test-cmd 'python3 {test} {filter}' --filter-flag=-k --no-lock \
  >"$SANDBOX/mutants.out" 2>&1; rc=$?
check "every loop.py mutant matched its expectation (rc 0, got $rc)" [ "$rc" -eq 0 ]
after="$(shasum -a 256 "$SKILL/loop.py" "$SKILL/loop_test.py" | shasum -a 256)"
check "the tracked loop.py / loop_test.py are byte-identical after mutation" [ "$before" = "$after" ]
check "no mutant survived unexpectedly" bash -c "! grep -q '^SURVIVED .*expect killed' '$SANDBOX/mutants.out'"
check "no mutant was MISARMED" bash -c "! grep -q '^MISARMED' '$SANDBOX/mutants.out'"
if [ "$rc" -ne 0 ]; then sed -n '1,60p' "$SANDBOX/mutants.out"; fi

# --- 12a. the anchor guard must actually RUN in a checkout, not take its skip branch.
# loop.py's stranded_mutant_anchors is what turns "a rewrite stranded a mutant" from a MISARMED
# discovered forty minutes into a battery into a red unit test. Its real-battery leg skips when no
# batteries sit beside the source, which is correct inside a mutation copy and would be a silent
# fail-open here: a skip and a pass are both green to anyone reading the exit code. So pin that an
# in-repo run reports these as PASSED, and control it against a run with the batteries hidden.
ARM="$SANDBOX/arm"; mkdir -p "$ARM"
( cd "$SKILL" && python3 loop_test.py -k TestEveryMutantIsStillArmable ) >"$ARM/inrepo.out" 2>&1
rc=$?
check "the mutant-anchor guard passes in the checkout (rc 0, got $rc)" [ "$rc" -eq 0 ]
check "it ran its tests rather than skipping them" \
  bash -c "! grep -qE '\\(skipped=|skipped [0-9]' '$ARM/inrepo.out'"
check "every one of its tests reported as passed" \
  bash -c "grep -qE '^Tests  [0-9]+ passed \\([0-9]+\\)\$' '$ARM/inrepo.out'"
# CONTROL: with the batteries out of reach the real-battery legs must SKIP (visible), never pass
# silently -- that is what makes the skip branch safe to have.
cp "$SKILL/loop.py" "$SKILL/loop_test.py" "$ARM/"
( cd "$ARM" && python3 loop_test.py -k TestEveryMutantIsStillArmable ) >"$ARM/nobattery.out" 2>&1
check "control: with no batteries beside it the guard SKIPS loudly instead of passing" \
  grep -qE "skipped=|skipped [0-9]" "$ARM/nobattery.out"
check "control: the synthetic legs still ran, so the rule itself is never skipped" \
  bash -c "! grep -q 'Ran 0 tests' '$ARM/nobattery.out'"

# --- 12b. the harness's OWN liveness helpers are mutated too, with the test file as its own source.
# wait_path/deadline/reduce_samples live in loop_test.py, so nothing in the loop.py batch can pin
# them; --src == --test is how a helper that lives beside its tests gets mutated at all.
python3 "$MUT/mutate.py" --root "$MUT" --src loop_test.py --test loop_test.py --copy-dir copy \
  --also-copy loop.py --mutants "$SKILL/loop_test.mutants.json" \
  --test-cmd 'python3 {test} {filter}' --filter-flag=-k --no-lock \
  >"$SANDBOX/harness-mutants.out" 2>&1; rc=$?
check "every loop_test.py harness mutant matched its expectation (rc 0, got $rc)" [ "$rc" -eq 0 ]
check "no harness mutant survived unexpectedly" bash -c "! grep -q '^SURVIVED .*expect killed' '$SANDBOX/harness-mutants.out'"
check "no harness mutant was MISARMED" bash -c "! grep -q '^MISARMED' '$SANDBOX/harness-mutants.out'"
if [ "$rc" -ne 0 ]; then sed -n '1,40p' "$SANDBOX/harness-mutants.out"; fi
# CONTROL for the same-file write ordering. The copy dir holds the source under its basename and the
# test under ITS basename, test written second: with same_file forced False the test copy lands on
# top of the armed source, every mutant runs unmutated, and the whole batch reads SURVIVED. That is a
# silent fail-open — this control is what says the green run above is not that.
# Break ONLY the two write branches, not the usage guard beside them: forcing `same_file` itself
# False makes the basename check refuse the run (rc 4) and the clobber never happens, so that
# version of the control tests the guard rather than the ordering it protects.
sed 's/^\( *\)if same_file:$/\1if False:  # control/' "$MUT/mutate.py" > "$MUT/mutate-samefile-broken.py"
[ "$(grep -c 'if False:  # control' "$MUT/mutate-samefile-broken.py")" -eq 2 ] \
  || bad "same-file control mutant did not arm at both write sites"
python3 "$MUT/mutate-samefile-broken.py" --root "$MUT" --src loop_test.py --test loop_test.py --copy-dir copy \
  --also-copy loop.py --mutants "$SKILL/loop_test.mutants.json" \
  --test-cmd 'python3 {test} {filter}' --filter-flag=-k --no-lock \
  >"$SANDBOX/harness-ctrl.out" 2>&1; rc=$?
check "control: with same-file handling broken the SAME batch reads SURVIVED (rc $rc)" \
  bash -c "grep -q '^SURVIVED' '$SANDBOX/harness-ctrl.out'"
# --- 12c. two DIFFERENT files sharing a basename is the same clobber and is refused outright
mkdir -p "$MUT/other"; cp "$MUT/loop.py" "$MUT/other/loop_test.py"
python3 "$MUT/mutate.py" --root "$MUT" --src loop_test.py --test other/loop_test.py --copy-dir copy \
  --mutants "$SKILL/loop_test.mutants.json" --test-cmd 'python3 {test} {filter}' --no-lock \
  >"$SANDBOX/basename.out" 2>&1; rc=$?
check "a basename collision between --src and --test is refused as usage (rc 4, got $rc)" [ "$rc" -eq 4 ]
check "the refusal names the shared basename" grep -q "share the basename" "$SANDBOX/basename.out"

# --- 15. mutate.py refuses the root (or anything outside it) as the copy dir — with a live control
SENT="$MUT/sentinel.txt"; echo keep > "$SENT"
python3 "$MUT/mutate.py" --root "$MUT" --src loop.py --test loop_test.py --copy-dir . \
  --mutants "$SKILL/loop.mutants.json" --test-cmd "$GREEN_CMD" --no-lock >"$SANDBOX/guard1.out" 2>&1; rc=$?
check "--copy-dir . is refused as usage (rc 4, got $rc)" [ "$rc" -eq 4 ]
check "root survives the refused run" bash -c "[ -f '$SENT' ] && [ -f '$MUT/loop.py' ]"
python3 "$MUT/mutate.py" --root "$MUT" --src loop.py --test loop_test.py --copy-dir ../outside \
  --mutants "$SKILL/loop.mutants.json" --test-cmd "$GREEN_CMD" --no-lock >"$SANDBOX/guard2.out" 2>&1; rc=$?
check "--copy-dir outside root is refused as usage (rc 4, got $rc)" [ "$rc" -eq 4 ]
check "nothing was created outside root" [ ! -e "$SANDBOX/outside" ]
# control on a THROWAWAY root: with the guard's `or` turned into `and`, `.` is accepted and the root is destroyed
CTRL="$SANDBOX/ctrl"; mkdir -p "$CTRL"; cp "$MUT/loop.py" "$MUT/loop_test.py" "$CTRL/"; echo keep > "$CTRL/sentinel.txt"
sed 's/ != root or copy_dir == root:/ != root and copy_dir == root:/' "$MUT/mutate.py" > "$CTRL/mutate.py"
grep -q 'and copy_dir == root' "$CTRL/mutate.py" || bad "control guard mutant did not arm"
printf '[{"label":"C1","old":"SCOPED_MAX_FILES = 8\\n","new":"SCOPED_MAX_FILES = 100\\n","expect":"survived"}]\n' > "$SANDBOX/one.json"
python3 "$CTRL/mutate.py" --root "$CTRL" --src loop.py --test loop_test.py --copy-dir . \
  --mutants "$SANDBOX/one.json" --test-cmd "$GREEN_CMD" --no-lock >"$SANDBOX/guard-ctrl.out" 2>&1; rc=$?
check "control: with the guard broken, --copy-dir . is NOT refused (rc $rc)" [ "$rc" -ne 4 ]
check "control: the broken guard destroyed the root's sentinel (what the guard prevents)" [ ! -f "$CTRL/sentinel.txt" ]

# --- 16. a mutant whose named test selects NOTHING is MISARMED, never SURVIVED — with a broken-detector control
printf '[{"label":"P1 misspelled selector","old":"SCOPED_MAX_FILES = 8\\n","new":"SCOPED_MAX_FILES = 100\\n","expect":"survived","test":"test_this_name_does_not_exist"}]\n' > "$SANDBOX/misarmed.json"
python3 "$MUT/mutate.py" --root "$MUT" --src loop.py --test loop_test.py --copy-dir copy \
  --mutants "$SANDBOX/misarmed.json" --test-cmd 'python3 {test} {filter}' --filter-flag=-k --no-lock >"$SANDBOX/misarmed.out" 2>&1; rc=$?
check "zero-match selector is MISARMED and the run fails (rc $rc)" bash -c "[ $rc -ne 0 ] && grep -q '^MISARMED' '$SANDBOX/misarmed.out'"
check "zero-match selector is never reported SURVIVED" bash -c "! grep -q '^SURVIVED' '$SANDBOX/misarmed.out'"
# Two INDEPENDENT guards refuse a zero-match selector: the MISARMED check on `tests_ran(out) == 0`
# and the MULTI-SELECT check on `selected_tests(summary) != 1`. Breaking either one alone leaves the
# other holding, which is why the single-guard control below reads MISARMED/MULTI-SELECT rather than
# SURVIVED -- an earlier version of this control asserted SURVIVED against one broken guard and was
# itself the false probe. Enumerate all three: each guard alone still refuses, and only with BOTH
# broken does the probe reach the shape they exist to prevent.
sed 's/if tests_ran(out) == 0:/if tests_ran(out) < 0:/' "$MUT/mutate.py" > "$MUT/mutate-nomisarmed.py"
grep -q 'if tests_ran(out) < 0:' "$MUT/mutate-nomisarmed.py" || bad "control detector mutant did not arm"
python3 "$MUT/mutate-nomisarmed.py" --root "$MUT" --src loop.py --test loop_test.py --copy-dir copy \
  --mutants "$SANDBOX/misarmed.json" --test-cmd 'python3 {test} {filter}' --filter-flag=-k --no-lock >"$SANDBOX/ctrl-a.out" 2>&1; rc=$?
check "control A: with only the MISARMED check broken, MULTI-SELECT still refuses (rc $rc)" \
  bash -c "[ $rc -ne 0 ] && grep -q '^MULTI-SELECT' '$SANDBOX/ctrl-a.out' && ! grep -q '^SURVIVED' '$SANDBOX/ctrl-a.out'"
sed 's/                    if n_sel != 1:/                    if False:/' "$MUT/mutate.py" > "$MUT/mutate-nomulti.py"
grep -q '                    if False:' "$MUT/mutate-nomulti.py" || bad "control multi-select mutant did not arm"
python3 "$MUT/mutate-nomulti.py" --root "$MUT" --src loop.py --test loop_test.py --copy-dir copy \
  --mutants "$SANDBOX/misarmed.json" --test-cmd 'python3 {test} {filter}' --filter-flag=-k --no-lock >"$SANDBOX/ctrl-b.out" 2>&1; rc=$?
check "control B: with only the MULTI-SELECT check broken, MISARMED still refuses (rc $rc)" \
  bash -c "[ $rc -ne 0 ] && grep -q '^MISARMED' '$SANDBOX/ctrl-b.out' && ! grep -q '^SURVIVED' '$SANDBOX/ctrl-b.out'"
sed -e 's/if tests_ran(out) == 0:/if tests_ran(out) < 0:/' -e 's/                    if n_sel != 1:/                    if False:/' \
  "$MUT/mutate.py" > "$MUT/mutate-broken.py"
grep -q 'if tests_ran(out) < 0:' "$MUT/mutate-broken.py" || bad "control detector mutant did not arm (both)"
grep -q '                    if False:' "$MUT/mutate-broken.py" || bad "control multi-select mutant did not arm (both)"
python3 "$MUT/mutate-broken.py" --root "$MUT" --src loop.py --test loop_test.py --copy-dir copy \
  --mutants "$SANDBOX/misarmed.json" --test-cmd 'python3 {test} {filter}' --filter-flag=-k --no-lock >"$SANDBOX/misarmed-ctrl.out" 2>&1; rc=$?
check "control C: with BOTH guards broken the same probe reads SURVIVED and exits 0 (rc $rc)" bash -c "[ $rc -eq 0 ] && grep -q '^SURVIVED' '$SANDBOX/misarmed-ctrl.out'"
after2="$(shasum -a 256 "$SKILL/loop.py" "$SKILL/loop_test.py" "$SKILL/mutate.py" | shasum -a 256)"
# The assertion stands; only its REPORT is widened. This skill lives in a tree several sessions edit
# at once, so a bare "they differ" is two very different facts wearing one message: a probe armed a
# mutant in the tracked tree (the thing this guard exists to catch), or a sibling session saved a
# file while the suite ran. Name the changed file and when it changed so the reader can tell which.
if [ "$after2" != "$before_all" ]; then
  bad "tracked loop.py / loop_test.py / mutate.py untouched by every probe"
  for f in loop.py loop_test.py mutate.py; do
    echo "       $f last written $(stat -f '%Sm' -t '%H:%M:%S' "$SKILL/$f") (suite started $suite_started)"
  done
  echo "       a time AFTER the suite start with no armed mutant in the file is another session writing, not a probe"
else
  ok "tracked loop.py / loop_test.py / mutate.py untouched by every probe"
fi

# --- 17. mutate.py refuses to arm a mutant inside a git worktree that does not ignore the copy dir
#     (a tree that auto-commits — like ~/dotfiles/claude itself — would COMMIT the armed mutant)
GITMUT="$SANDBOX/gitmut"; mkdir -p "$GITMUT"
cp "$SKILL/loop.py" "$SKILL/loop_test.py" "$SKILL/mutate.py" "$GITMUT/"
( cd "$GITMUT" && git init -q . && git config user.email t@t && git config user.name t \
  && git add loop.py loop_test.py mutate.py && git commit -qm base )
python3 "$GITMUT/mutate.py" --root "$GITMUT" --src loop.py --test loop_test.py --copy-dir copy \
  --mutants "$SANDBOX/one.json" --test-cmd "$GREEN_CMD" --no-lock >"$SANDBOX/git1.out" 2>&1; rc=$?
check "a copy dir inside a git worktree, not ignored, is refused (rc 4, got $rc)" [ "$rc" -eq 4 ]
check "the refusal names why (a commit would carry the armed mutant)" grep -q 'NOT git-ignored' "$SANDBOX/git1.out"
check "nothing was armed in the worktree" [ ! -e "$GITMUT/copy" ]
# BOTH ignore forms must be accepted: `copy/` is what a human writes, and it reads "not ignored"
# on a dir that does not exist yet unless the check probes INSIDE it.
for pat in 'copy/' 'copy'; do
  printf '%s\n' "$pat" > "$GITMUT/.gitignore"
  rm -rf "$GITMUT/copy"
  python3 "$GITMUT/mutate.py" --root "$GITMUT" --src loop.py --test loop_test.py --copy-dir copy \
    --mutants "$SANDBOX/one.json" --test-cmd "$GREEN_CMD" --no-lock >"$SANDBOX/git2.out" 2>&1; rc=$?
  check "gitignore pattern '$pat' lets the run proceed (rc 0, got $rc)" [ "$rc" -eq 0 ]
done
printf 'unrelated/\n' > "$GITMUT/.gitignore"
python3 "$GITMUT/mutate.py" --root "$GITMUT" --src loop.py --test loop_test.py --copy-dir copy \
  --mutants "$SANDBOX/one.json" --test-cmd "$GREEN_CMD" --no-lock >"$SANDBOX/git3.out" 2>&1; rc=$?
check "an ignore rule that does NOT cover the copy dir is still refused (rc 4, got $rc)" [ "$rc" -eq 4 ]
# live control: with the worktree guard disabled, the same unignored run is accepted
sed 's/if top and not git_ignored(top, copy_dir):/if False and not git_ignored(top, copy_dir):/' \
  "$GITMUT/mutate.py" > "$GITMUT/mutate-noguard.py"
grep -q 'if False and not git_ignored' "$GITMUT/mutate-noguard.py" || bad "worktree-guard control did not arm"
python3 "$GITMUT/mutate-noguard.py" --root "$GITMUT" --src loop.py --test loop_test.py --copy-dir copy \
  --mutants "$SANDBOX/one.json" --test-cmd "$GREEN_CMD" --no-lock >"$SANDBOX/git4.out" 2>&1; rc=$?
check "control: with the guard disabled the unignored run is NOT refused (rc $rc)" [ "$rc" -ne 4 ]

# --- 18. mutate.py refuses a --test-cmd that would run the UNMUTATED original
#     Measured while writing this: a template naming the test by literal path instead of {test}
#     ran the original file and reported a genuinely-killed mutant as SURVIVED. Every mutant would
#     have. That is a total fail-open of the harness, and it looks exactly like a weak test suite.
MC="$SANDBOX/mutcmd"; mkdir -p "$MC"
cp "$SKILL/loop.py" "$SKILL/loop_test.py" "$SKILL/mutate.py" "$MC/"
python3 "$MC/mutate.py" --root="$MC" --src=loop.py --test=loop_test.py --copy-dir=copy \
  --mutants="$SANDBOX/one.json" --test-cmd='python3 loop_test.py {filter}' --no-lock >"$SANDBOX/tc1.out" 2>&1; rc=$?
check "a --test-cmd naming the original by literal path is refused (rc 4, got $rc)" [ "$rc" -eq 4 ]
check "the refusal says why (it would report every mutant SURVIVED)" grep -q 'SURVIVED' "$SANDBOX/tc1.out"
for tmpl in "$GREEN_CMD" 'printf "Tests  1 passed (1)\n"; true copy/loop_test.py'; do
  python3 "$MC/mutate.py" --root="$MC" --src=loop.py --test=loop_test.py --copy-dir=copy \
    --mutants="$SANDBOX/one.json" --test-cmd="$tmpl" --no-lock >"$SANDBOX/tc2.out" 2>&1; rc=$?
  check "a --test-cmd reaching the copy via '$tmpl' is accepted (rc 0, got $rc)" [ "$rc" -eq 0 ]
done
# live control: with the guard disabled, the literal-path template IS accepted — which is the
# false-SURVIVED this guard exists to prevent.
sed "s/if '{test}' not in args.test_cmd and args.copy_dir not in args.test_cmd:/if False:/" \
  "$MC/mutate.py" > "$MC/mutate-nocmd.py"
grep -q '^    if False:' "$MC/mutate-nocmd.py" || bad "test-cmd control did not arm"
python3 "$MC/mutate-nocmd.py" --root="$MC" --src=loop.py --test=loop_test.py --copy-dir=copy \
  --mutants="$SANDBOX/one.json" --test-cmd='python3 loop_test.py {filter}' --no-lock >"$SANDBOX/tc3.out" 2>&1; rc=$?
check "control: with the guard disabled the same template is NOT refused (rc $rc)" [ "$rc" -ne 4 ]

# --- 19. a run the launcher itself identifies as VOID must not exit 0
#     `reasoning effort: none` is what a silent profile fall-through resolves to. The launcher
#     already detected it and printed a warning — then exited 0, so the caller consumed a verdict
#     from a tier nobody chose as a completed review. A warning inside a long log is not a gate.
CODEX_STUB_EFFORT=none launch --one-off -- -p sol; rc=$?
check "a run that resolved to effort 'none' is quarantined (rc 8, got $rc)" [ "$rc" -eq 8 ]
check "the void verdict is NOT left where a caller would read it" [ ! -e "$SANDBOX/art/out.json" ]
check "the void verdict is kept for inspection" [ -s "$SANDBOX/art/out.json.void" ]
check "the refusal names the effort it actually resolved to" \
  grep -q "resolved to reasoning effort 'none'" "$SANDBOX/stderr"
rm -f "$SANDBOX/art/out.json.void"
# control: the SAME launch at the effort the profile asks for still returns a verdict
launch --one-off -- -p sol; rc=$?
check "control: at effort 'high' the identical launch exits 0 and lands the verdict (rc $rc)" \
  bash -c "[ $rc -eq 0 ] && [ -s '$SANDBOX/art/out.json' ] && [ ! -e '$SANDBOX/art/out.json.void' ]"

# --- 20. the profile name is compared LITERALLY, never as a regex
#     `-p '.*'` used to match `[profiles.sol]` through grep -E and be waved through, after which
#     codex silently falls back to the base config — the exact silent-tier-fallback this refuses.
launch --one-off -- -p '.*'; rc=$?
check "a regex-shaped profile name is refused (rc 2, got $rc)" [ "$rc" -eq 2 ]
check "the regex-shaped name never reached codex" [ ! -e "$CODEX_STUB_MARKER" ]
printf 'model = "x"\n' > "$CODEX_HOME/so.config.toml"
launch --one-off -- -p 's.'; rc=$?
check "a single-char wildcard matching a real profile name is refused (rc 2, got $rc)" [ "$rc" -eq 2 ]
rm -f "$CODEX_HOME/so.config.toml"
launch --one-off -- -p sol; rc=$?
check "control: the real profile 'sol' is still accepted (rc $rc)" [ "$rc" -eq 0 ]

# --- 21. one lock per WORKTREE, keyed on its toplevel — not on the path the caller passed
#     A reader given /repo and a --write job given /repo/sub each took "the tree lock" and ran at
#     the same time on one tree. Measured before the fix: tree-5c1a7c92... vs tree-189ab888....
mkdir -p "$WORK/sub"
LOCKPROBE="$(python3 - "$SKILL" "$WORK" <<'EOF'
import sys, os
sys.path.insert(0, sys.argv[1])
import loop
r = sys.argv[2]
print(loop.tree_lock_name(os.path.join(r, 'sub')) == loop.tree_lock_name(r))
EOF
)"
check "a subdirectory of a worktree takes the SAME lock as its root ($LOCKPROBE)" [ "$LOCKPROBE" = True ]
# control: two DISTINCT worktrees must NOT collapse onto one lock
git -C "$WORK" worktree add -q --detach "$SANDBOX/wt2" >/dev/null 2>&1
DISTINCT="$(python3 - "$SKILL" "$WORK" "$SANDBOX/wt2" <<'EOF'
import sys
sys.path.insert(0, sys.argv[1])
import loop
print(loop.tree_lock_name(sys.argv[2]) != loop.tree_lock_name(sys.argv[3]))
EOF
)"
check "control: two distinct worktrees keep distinct locks ($DISTINCT)" [ "$DISTINCT" = True ]

# --- 22. a REUSED snapshot must still BE the sha it is named after
#     The reuse path compared only the HEAD sha and ignored the working tree, so a snapshot
#     somebody had edited was handed back as the pinned revision and every lens read the edit
#     while citing the sha. Measured before the fix: a reviewer read 'MUTATED BY SOMEONE'.
SNAPARC="$SANDBOX/snaparc"; mkdir -p "$SNAPARC"
echo original > "$WORK/file.txt"
git -C "$WORK" add file.txt && git -C "$WORK" -c user.email=t@t -c user.name=t commit -qm f
SNAPSHA="$(git -C "$WORK" rev-parse HEAD)"
SNAP="$(python3 "$SKILL/loop.py" snapshot --arc="$SNAPARC" --track=A --round=1 --repo="$WORK" --sha="$SNAPSHA")"
check "the snapshot is created at the pinned sha" bash -c "[ -d '$SNAP' ] && [ \"\$(cat '$SNAP/file.txt')\" = original ]"
SNAP2="$(python3 "$SKILL/loop.py" snapshot --arc="$SNAPARC" --track=A --round=2 --repo="$WORK" --sha="$SNAPSHA")"; rc=$?
check "a CLEAN snapshot is reused (rc 0, got $rc, same path)" bash -c "[ $rc -eq 0 ] && [ '$SNAP2' = '$SNAP' ]"
echo 'MUTATED BY SOMEONE' > "$SNAP/file.txt"
python3 "$SKILL/loop.py" snapshot --arc="$SNAPARC" --track=A --round=3 --repo="$WORK" --sha="$SNAPSHA" \
  >"$SANDBOX/snap3.out" 2>&1; rc=$?
check "reuse of a snapshot with tracked edits is REFUSED (rc 5, got $rc)" [ "$rc" -eq 5 ]
check "the refusal says the sha does not name that code" grep -q 'UNCOMMITTED TRACKED CHANGES' "$SANDBOX/snap3.out"
check "the refusal printed no path a caller could hand to a lens" bash -c "! grep -qx '$SNAP' '$SANDBOX/snap3.out'"
# An UNTRACKED entry is pollution too: an untracked importable module or an AGENTS.md changes what
# every lens READS while HEAD is unchanged. The one carve-out is the node_modules install link this
# command makes itself, and it is gated on a LIVE predicate (still a symlink, still resolving to the
# source repo's own copy) rather than on the name -- a real directory by that name is pollution.
git -C "$SNAP" checkout -- file.txt
: > "$SNAP/scratch-note.txt"
python3 "$SKILL/loop.py" snapshot --arc="$SNAPARC" --track=A --round=4 --repo="$WORK" --sha="$SNAPSHA" \
  >"$SANDBOX/snap4.out" 2>&1; rc=$?
check "reuse of a snapshot carrying an untracked scratch file is REFUSED (rc 5, got $rc)" [ "$rc" -eq 5 ]
check "the refusal NAMES the untracked entry" grep -q 'scratch-note.txt' "$SANDBOX/snap4.out"
check "the refusal printed no path a caller could hand to a lens" bash -c "! grep -qx '$SNAP' '$SANDBOX/snap4.out'"
rm -f "$SNAP/scratch-note.txt"
SNAP5="$(python3 "$SKILL/loop.py" snapshot --arc="$SNAPARC" --track=A --round=5 --repo="$WORK" --sha="$SNAPSHA")"; rc=$?
check "removing it restores reuse (rc 0, got $rc, same path)" bash -c "[ $rc -eq 0 ] && [ '$SNAP5' = '$SNAP' ]"
# the carve-out is satisfiable: the install LINK is tolerated ...
mkdir -p "$WORK/node_modules"
rm -rf "$SNAP/node_modules"; ln -s "$WORK/node_modules" "$SNAP/node_modules"
SNAP6="$(python3 "$SKILL/loop.py" snapshot --arc="$SNAPARC" --track=A --round=6 --repo="$WORK" --sha="$SNAPSHA")"; rc=$?
check "the node_modules install LINK is tolerated (rc 0, got $rc, same path)" bash -c "[ $rc -eq 0 ] && [ '$SNAP6' = '$SNAP' ]"
# ... and only while the live predicate holds: a real directory by that name is pollution.
rm -f "$SNAP/node_modules"; mkdir -p "$SNAP/node_modules"; : > "$SNAP/node_modules/real.js"
python3 "$SKILL/loop.py" snapshot --arc="$SNAPARC" --track=A --round=7 --repo="$WORK" --sha="$SNAPSHA" \
  >"$SANDBOX/snap7.out" 2>&1; rc=$?
check "a REAL node_modules directory is NOT carved out (rc 5, got $rc)" [ "$rc" -eq 5 ]
check "the refusal names the entry inside it" grep -q 'node_modules/real.js' "$SANDBOX/snap7.out"
rm -rf "$SNAP/node_modules" "$WORK/node_modules"

# --- 23. rounds are 1-based; round 0 and negative rounds are refused, not waved through
GATEPROBE="$(python3 - "$SKILL" "$SANDBOX/arc" <<'EOF'
import sys
sys.path.insert(0, sys.argv[1])
import loop
arc = sys.argv[2]
print(loop.gate(arc, 'Z', 0)[0], loop.gate(arc, 'Z', -3)[0], loop.gate(arc, 'Z', 1)[0])
EOF
)"
check "round 0 and negative rounds do NOT pass the gate, round 1 still does ($GATEPROBE)" \
  [ "$GATEPROBE" = "False False True" ]

# --- 24. mutate.py refuses to run against a suite that is not GREEN before anything is armed
#     A pre-existing red test reports EVERY mutant as KILLED, so every `expect: killed` matches and
#     the harness certifies itself green on zero evidence. Measured before this guard, on a file
#     asserting 1 + 2 == 999: `KILLED OK M1 ... 1/1 mutants matched expectation` and exit 0.
BASE="$SANDBOX/baseline"; mkdir -p "$BASE"
cp "$SKILL/mutate.py" "$SKILL/loop.py" "$BASE/"
printf 'def f(a, b):\n    return a + b\n' > "$BASE/src.py"
cat > "$BASE/mk_test.sh" <<'MK'
want="$1"; out="$2"
cat > "$out" <<EOF
import unittest, src
class T(unittest.TestCase):
    def test_sum(self):
        self.assertEqual(src.f(1, 2), $want)
if __name__ == '__main__':
    import sys
    r = unittest.main(exit=False, argv=sys.argv).result
    n = r.testsRun; bad = len(r.failures) + len(r.errors)
    print("Tests  %d passed | %d failed (%d)" % (n - bad, bad, n))
    sys.exit(0 if r.wasSuccessful() else 1)
EOF
MK
printf '[{"label":"M1 plus becomes minus","old":"    return a + b\\n","new":"    return a - b\\n","expect":"killed","test":"test_sum"}]\n' > "$BASE/m.json"
bash "$BASE/mk_test.sh" 999 "$BASE/src_test.py"     # RED before any mutant is armed
python3 "$BASE/mutate.py" --root="$BASE" --src=src.py --test=src_test.py --copy-dir=copy \
  --mutants="$BASE/m.json" --test-cmd='python3 {test} {filter}' --filter-flag=-k --no-lock \
  >"$SANDBOX/base-red.out" 2>&1; rc=$?
check "a red baseline is refused before arming (rc 5, got $rc)" [ "$rc" -eq 5 ]
check "the refusal says every mutant would have read as KILLED" grep -q 'read as KILLED' "$SANDBOX/base-red.out"
check "no mutant was classified at all" bash -c "! grep -qE '^(KILLED|SURVIVED)' '$SANDBOX/base-red.out'"
bash "$BASE/mk_test.sh" 3 "$BASE/src_test.py"       # GREEN
python3 "$BASE/mutate.py" --root="$BASE" --src=src.py --test=src_test.py --copy-dir=copy \
  --mutants="$BASE/m.json" --test-cmd='python3 {test} {filter}' --filter-flag=-k --no-lock \
  >"$SANDBOX/base-green.out" 2>&1; rc=$?
check "control: with the same test GREEN the identical mutant run proceeds and kills it (rc $rc)" \
  bash -c "[ $rc -eq 0 ] && grep -q '^KILLED' '$SANDBOX/base-green.out'"
check "the baseline is reported, not silent" grep -q '^baseline OK' "$SANDBOX/base-green.out"
# live control: with the baseline guard removed, the RED suite reports 1/1 matched and exits 0
sed 's/if base_proc.returncode != 0 or base_ran == 0:/if False:/' "$BASE/mutate.py" > "$BASE/mutate-nobase.py"
grep -qE '^ +if False:' "$BASE/mutate-nobase.py" || bad "baseline control did not arm"
bash "$BASE/mk_test.sh" 999 "$BASE/src_test.py"
python3 "$BASE/mutate-nobase.py" --root="$BASE" --src=src.py --test=src_test.py --copy-dir=copy \
  --mutants="$BASE/m.json" --test-cmd='python3 {test} {filter}' --filter-flag=-k --no-lock \
  >"$SANDBOX/base-ctrl.out" 2>&1; rc=$?
check "control: without the guard the RED suite reports every mutant killed and exits 0 (rc $rc)" \
  bash -c "[ $rc -eq 0 ] && grep -q '1/1 mutants matched expectation' '$SANDBOX/base-ctrl.out'"

# --- 25. the completeness (--census) and unique-anchor guards, exercised in both directions
bash "$BASE/mk_test.sh" 3 "$BASE/src_test.py"
python3 "$BASE/mutate.py" --root="$BASE" --src=src.py --test=src_test.py --copy-dir=copy \
  --mutants="$BASE/m.json" --census 'return a=1' --test-cmd='python3 {test} {filter}' --filter-flag=-k \
  --no-lock >"$SANDBOX/census-ok.out" 2>&1; rc=$?
check "a census whose count MATCHES the source lets the run proceed (rc 0, got $rc)" [ "$rc" -eq 0 ]
check "the passing census is reported" grep -q "^census OK" "$SANDBOX/census-ok.out"
python3 "$BASE/mutate.py" --root="$BASE" --src=src.py --test=src_test.py --copy-dir=copy \
  --mutants="$BASE/m.json" --census 'return a=2' --test-cmd='python3 {test} {filter}' --filter-flag=-k \
  --no-lock >"$SANDBOX/census-bad.out" 2>&1; rc=$?
check "a census whose count is WRONG fails the run (rc 3, got $rc)" [ "$rc" -eq 3 ]
check "the failing census names the count it saw" grep -q "^census FAIL" "$SANDBOX/census-bad.out"
check "a failed census arms no mutant" bash -c "! grep -qE '^(KILLED|SURVIVED)' '$SANDBOX/census-bad.out'"
# unique-anchor: an `old` that occurs at MORE THAN ONE site is MISARMED, never silently applied
printf 'def f(a, b):\n    return a + b\n\n\ndef g(a, b):\n    return a + b\n' > "$BASE/src2.py"
printf '[{"label":"A1 two-site anchor","old":"    return a + b\\n","new":"    return a - b\\n","expect":"killed","test":"test_sum"}]\n' > "$BASE/m2.json"
cat > "$BASE/src2_test.py" <<'T2'
import unittest, src2
class T(unittest.TestCase):
    def test_sum(self):
        self.assertEqual(src2.f(1, 2), 3)
        self.assertEqual(src2.g(1, 2), 3)
if __name__ == '__main__':
    import sys
    r = unittest.main(exit=False, argv=sys.argv).result
    n = r.testsRun; bad = len(r.failures) + len(r.errors)
    print("Tests  %d passed | %d failed (%d)" % (n - bad, bad, n))
    sys.exit(0 if r.wasSuccessful() else 1)
T2
python3 "$BASE/mutate.py" --root="$BASE" --src=src2.py --test=src2_test.py --copy-dir=copy \
  --mutants="$BASE/m2.json" --test-cmd='python3 {test} {filter}' --filter-flag=-k --no-lock \
  >"$SANDBOX/anchor2.out" 2>&1; rc=$?
check "an anchor matching TWO sites is MISARMED, not applied (rc $rc)" \
  bash -c "[ $rc -ne 0 ] && grep -q '^MISARMED' '$SANDBOX/anchor2.out' && grep -q 'occurs 2 times' '$SANDBOX/anchor2.out'"
check "a two-site anchor is never reported as a classified mutant" \
  bash -c "! grep -qE '^(KILLED|SURVIVED)' '$SANDBOX/anchor2.out'"
# control: the SAME mutant against a one-site source is armed and killed
python3 "$BASE/mutate.py" --root="$BASE" --src=src.py --test=src_test.py --copy-dir=copy \
  --mutants="$BASE/m.json" --test-cmd='python3 {test} {filter}' --filter-flag=-k --no-lock \
  >"$SANDBOX/anchor1.out" 2>&1; rc=$?
check "control: the same anchor at ONE site arms and kills (rc $rc)" \
  bash -c "[ $rc -eq 0 ] && grep -q '^KILLED' '$SANDBOX/anchor1.out'"

# --- 26. a run that executes ZERO tests is MISARMED even when it was never filtered
#     The guard used to be conditional on a `test` name, leaving the whole-file case open: a
#     command that runs nothing exits 0, reads as SURVIVED, and turns every `expect: survived`
#     mutant green without executing a line of the code under test.
printf '[{"label":"Z1 unfiltered","old":"    return a + b\\n","new":"    return a - b\\n","expect":"survived"}]\n' > "$BASE/m3.json"
python3 "$BASE/mutate.py" --root="$BASE" --src=src.py --test=src_test.py --copy-dir=copy \
  --mutants="$BASE/m3.json" --test-cmd='printf "Tests  1 passed (1)\n"; python3 -c "import sys; sys.exit(0)" {test}' \
  --no-lock >"$SANDBOX/zero1.out" 2>&1; rc=$?
check "control: a command that DOES report tests classifies normally (rc $rc)" \
  bash -c "[ $rc -eq 0 ] && grep -q '^SURVIVED' '$SANDBOX/zero1.out'"
python3 "$BASE/mutate.py" --root="$BASE" --src=src.py --test=src_test.py --copy-dir=copy \
  --mutants="$BASE/m3.json" \
  --test-cmd='if [ -f .baseline-done ]; then :; else printf "Tests  1 passed (1)\n"; touch .baseline-done; fi; true {test}' \
  --no-lock >"$SANDBOX/zero2.out" 2>&1; rc=$?
rm -f "$BASE/.baseline-done"
check "an unfiltered run that executed 0 tests is MISARMED, never SURVIVED (rc $rc)" \
  bash -c "[ $rc -ne 0 ] && grep -q '^MISARMED' '$SANDBOX/zero2.out' && grep -q 'unfiltered run executed 0 tests' '$SANDBOX/zero2.out'"
check "the zero-test run is never reported SURVIVED" bash -c "! grep -q '^SURVIVED' '$SANDBOX/zero2.out'"

# --- 27. a mutant must never read as SURVIVED because the interpreter reused stale bytecode
#     CPython validates cached bytecode against the source's SIZE and its mtime IN WHOLE SECONDS,
#     so a same-size edit inside the same second leaves the PREVIOUS mutant's bytecode looking
#     valid. Measured here before the fix: five identical runs of one same-size mutant gave
#     KILLED, SURVIVED, KILLED, SURVIVED, SURVIVED — a false negative for `expect: killed`, and a
#     false GREEN for any `expect: survived` mutant.
#     Deleting __pycache__ is NOT the fix: the macOS system Python sets sys.pycache_prefix, so the
#     cache lives outside the tree keyed by absolute source path. Forcing a never-repeated mtime is.
PYC="$SANDBOX/pyc"; mkdir -p "$PYC"
printf 'def f():\n    return 1\n' > "$PYC/m.py"
cat > "$PYC/t.py" <<'PT'
import m, sys
sys.stdout.write('f=%d\n' % m.f())
PT
python3 "$PYC/t.py" > "$PYC/first.out" 2>&1
python3 - "$PYC" <<'PS'
import os, sys
d = sys.argv[1]; src = os.path.join(d, 'm.py'); st = os.stat(src)
open(src, 'w').write('def f():\n    return 2\n')     # same size, different answer
os.utime(src, (st.st_atime, st.st_mtime))             # and the same mtime second
PS
check "control: a same-size same-mtime edit is invisible behind cached bytecode (read f=1)" \
  bash -c "grep -q 'f=1' '$PYC/first.out' && python3 '$PYC/t.py' | grep -q 'f=1'"
# the cache is NOT necessarily in the tree — show where this interpreter actually put it
python3 -c "import sys; print('pycache_prefix=%r' % sys.pycache_prefix)"
rm -rf "$PYC/__pycache__"
check "purging __pycache__ alone does NOT make it visible on this interpreter (still f=1)" \
  bash -c "python3 '$PYC/t.py' | grep -q 'f=1'"
python3 - "$PYC" <<'PS'
import os, sys, time
src = os.path.join(sys.argv[1], 'm.py')
t = time.time() + 60
os.utime(src, (t, t))                                 # a never-before-compiled mtime
PS
check "forcing a distinct mtime is what makes the edit visible (read f=2)" \
  bash -c "python3 '$PYC/t.py' | grep -q 'f=2'"
# the property mutate.py relies on: consecutive writes NEVER share an mtime, whatever the clock does
check "write_source gives every write a strictly increasing, never-repeated mtime" \
  python3 - "$SKILL" "$SANDBOX" <<'PW'
import os, sys
sys.path.insert(0, os.path.join(sys.argv[1]))
import mutate
d = os.path.join(sys.argv[2], 'ws'); os.makedirs(d, exist_ok=True)
p = os.path.join(d, 'x.py')
seen = []
for i in range(5):
    mutate.write_source(p, 'V = %d\n' % (i % 2))      # same size every time
    seen.append(os.stat(p).st_mtime)
assert len(set(seen)) == 5, seen
assert seen == sorted(seen), seen
PW
# and mutate.py is stable across repeats of a same-size mutant
bash "$BASE/mk_test.sh" 3 "$BASE/src_test.py"
pyc_green=0
for _i in 1 2 3 4 5; do
  python3 "$BASE/mutate.py" --root="$BASE" --src=src.py --test=src_test.py --copy-dir=copy \
    --mutants="$BASE/m.json" --test-cmd='python3 {test} {filter}' --filter-flag=-k --no-lock \
    >/dev/null 2>&1 && pyc_green=$((pyc_green + 1))
done
check "5 identical runs of a same-size mutant all KILL it (green $pyc_green/5)" [ "$pyc_green" -eq 5 ]

# --- 28. an INTERRUPTED mutation run kills its test as a GROUP and still attributes its wall-clock
#     Two defects, one shape. `subprocess.run` left a terminated run's suite executing unsupervised
#     (a vitest worker pool competing with whatever ran next), and the ledger row was written only
#     on the success path — so the time that run spent landed in the profiler's unexplained-gap
#     bucket rather than against the job that spent it. The interrupt lands during the BASELINE,
#     which is the harder case: zero mutants completed, and the row must exist anyway.
INT="$SANDBOX/interrupt"; mkdir -p "$INT"
cp "$SKILL/mutate.py" "$SKILL/loop.py" "$INT/"
printf 'def f(a, b):\n    return a + b\n' > "$INT/src.py"
cat > "$INT/src_test.py" <<'EOF'
import os, sys, time, unittest
class T(unittest.TestCase):
    def test_slow(self):
        with open(os.environ['PIDFILE'], 'w') as fh:
            fh.write(str(os.getpid()))
        time.sleep(120)
if __name__ == '__main__':
    r = unittest.main(exit=False, argv=sys.argv).result
    n = r.testsRun; bad = len(r.failures) + len(r.errors)
    print("Tests  %d passed | %d failed (%d)" % (n - bad, bad, n))
    sys.exit(0 if r.wasSuccessful() else 1)
EOF
printf '[{"label":"M1 plus becomes minus","old":"    return a + b\\n","new":"    return a - b\\n","expect":"killed","test":"test_slow"}]\n' > "$INT/m.json"
export PIDFILE="$INT/child.pid"
# `mutant` is a gated kind, so this attributed batch cannot be admitted into round 1 until the arc
# has paid for the loop -- the same transaction `loop.py run` takes. Before the gate reached
# mutate.py the tuple was decorative and this fixture needed no preflight.
mkdir -p "$INT/arc"; preflight_arc "$INT/arc"
# `:;` before the interpreter defeats sh's exec optimisation, so the test is a GRANDchild — killing
# the shell alone would leave it running, which is exactly the difference this asserts.
python3 "$INT/mutate.py" --root="$INT" --src=src.py --test=src_test.py --copy-dir=copy \
  --mutants="$INT/m.json" --test-cmd=':; python3 {test} {filter}' --filter-flag=-k --no-lock \
  --arc="$INT/arc" --track=A --round=1 >"$SANDBOX/int.out" 2>&1 &
mpid=$!
i=0; while [ ! -s "$INT/child.pid" ] && [ "$i" -lt 400 ]; do sleep 0.05; i=$((i + 1)); done
check "the interrupt fixture's test really started" [ -s "$INT/child.pid" ]
kid="$(cat "$INT/child.pid" 2>/dev/null || echo 0)"
# the parent lookup must be made on a LIVE pid: `ps -o ppid= -p 0` prints nothing, which compares
# unequal to $mpid and passed this check without observing anything at all.
kidppid="$(ps -o ppid= -p "$kid" 2>/dev/null | tr -d ' ')"
check "the test is a GRANDchild of the run (so a direct-child kill would miss it)" \
  bash -c "[ -n '$kidppid' ] && [ '$kidppid' != '$mpid' ]"
kill -TERM "$mpid"
wait "$mpid"; irc=$?
check "an interrupted mutate.py exits 128+SIGTERM (143, got $irc)" [ "$irc" -eq 143 ]
i=0; while kill -0 "$kid" 2>/dev/null && [ "$i" -lt 200 ]; do sleep 0.05; i=$((i + 1)); done
check "the running test was killed with the run, not orphaned" bash -c "! kill -0 $kid 2>/dev/null"
check "the interrupted batch still wrote a ledger row" bash -c "grep -q 'INTERRUPTED by signal 15' '$INT/arc/jobs.jsonl'"
check "that row is a complete job (start AND end), not a dangling start" bash -c "grep -c '\"ev\": \"end\"' '$INT/arc/jobs.jsonl' | grep -qx 1"
check "the mutated copy dir was cleaned up on the way out" [ ! -d "$INT/copy" ]
unset PIDFILE

# --- 29. CORR1: `--write --one-off` is refused, and the property that refusal protects is real
#     A one-off is "not attributed to an arc", never "not synchronized". Two one-off WRITERS could
#     otherwise enter one worktree at once, because the exclusive tree lock is taken by the
#     scheduler a one-off used to skip. The refusal is only worth anything if a scheduled one-off
#     really does queue behind that lock, so this section asserts both halves.
ONEOFF="$SANDBOX/oneoff-arc"; mkdir -p "$ONEOFF"; preflight_arc "$ONEOFF"
launch --write --one-off -- -p sol; rc=$?
check "--write --one-off is refused (rc 2, got $rc)" [ "$rc" -eq 2 ]
check "the refused writer never invoked codex" [ ! -e "$CODEX_STUB_MARKER" ]
check "the refusal names the exclusive tree lock it would not have taken" \
  grep -q 'exclusive tree lock' "$SANDBOX/stderr"
# live control A: the same one-off WITHOUT --write is scheduled, not refused -- so the refusal is
# about the writer, not about --one-off being unsupported in this fixture.
CC_ONEOFF_ARC="$ONEOFF" launch --one-off -- -p sol; rc=$?
check "control: a read-only --one-off in the same tree runs (rc 0, got $rc)" [ "$rc" -eq 0 ]
check "control: and it is scheduled onto the reserved one-off track at round 1" \
  bash -c "grep -q '\"round\": 1' '$ONEOFF/jobs.jsonl' && grep -q '\"track\": \"one-off\"' '$ONEOFF/jobs.jsonl'"
# live control B: the git predicate is live -- outside a git tree there is no toplevel to lock and
# no movement to prove, so a one-off there stays genuinely unscheduled.
CC_ONEOFF_ARC="$SANDBOX/oneoff-arc2" WORKDIR="$SANDBOX/plain" launch --one-off -- -p sol; rc=$?
check "control: a one-off outside a git tree runs unscheduled (rc 0, got $rc)" [ "$rc" -eq 0 ]
check "control: and writes no ledger, because there is no tree to serialize on" \
  [ ! -e "$SANDBOX/oneoff-arc2/jobs.jsonl" ]
# the property: with an exclusive tree lock held, a scheduled one-off WAITS instead of entering.
# `--track W` and not `A`, because $ARC's track A round 1 is closed above and a closed round admits
# nothing -- the job would be refused before it ever reached a lock.
LOCKARC="$SANDBOX/oneoff-lock-arc"; mkdir -p "$LOCKARC"; preflight_arc "$LOCKARC"
CC_ONEOFF_ARC="$LOCKARC" launch --one-off -- -p sol
# Every threshold below is derived from HOLD_S -- the one number this probe controls -- and the
# verdict is a RATIO between the two measurements the same run produced. A bare `< 0.5s` ceiling
# measured this machine's python start-up under whatever else was running, so it reddened under
# load and would have gone green on a fast machine even with the queueing removed entirely.
HOLD_S=3
q_free="$(python3 -c 'import json,sys; print(max([e.get("queued_s",0.0) for e in map(json.loads,open(sys.argv[1])) if e.get("ev")=="start"]+[0.0]))' "$LOCKARC/jobs.jsonl")"
check "baseline: with nothing holding the tree, a one-off waits far less than the hold (${q_free}s of ${HOLD_S}s)" \
  python3 -c "import sys; sys.exit(0 if float(sys.argv[1]) < float(sys.argv[2]) / 4 else 1)" "$q_free" "$HOLD_S"
python3 "$SKILL/loop.py" run --arc="$ARC" --track=W --round=1 --kind=write --name=holder \
  --tree="$WORK" -- sleep "$HOLD_S" >/dev/null 2>&1 &
hpid=$!
i=0
while ! grep -q '"ev": "start".*"name": "holder"' "$LEDGER" 2>/dev/null && [ "$i" -lt 300 ]; do
  sleep 0.05; i=$((i + 1))
done
check "the exclusive tree-lock holder really started (else the wait below proves nothing)" \
  grep -q '"ev": "start".*"name": "holder"' "$LEDGER"
CC_ONEOFF_ARC="$LOCKARC" launch --one-off -- -p sol; rc=$?
wait "$hpid" 2>/dev/null || true
q_held="$(python3 -c 'import json,sys; print(max([e.get("queued_s",0.0) for e in map(json.loads,open(sys.argv[1])) if e.get("ev")=="start"]+[0.0]))' "$LOCKARC/jobs.jsonl")"
check "the one-off ran, but only after the writer released the tree (rc $rc)" [ "$rc" -eq 0 ]
check "it QUEUED for the writer's exclusive tree lock rather than entering the worktree (${q_held}s of ${HOLD_S}s)" \
  python3 -c "import sys; sys.exit(0 if float(sys.argv[1]) >= float(sys.argv[2]) / 4 else 1)" "$q_held" "$HOLD_S"
# The RATIO is the assertion the machine cannot move: whatever this box's start-up costs, it is
# charged to both measurements, so a held wait many times the free one can only be the lock.
check "and the held wait is dominated by the holder, not by start-up (free ${q_free}s vs held ${q_held}s)" \
  python3 -c "import sys; f, h = float(sys.argv[1]), float(sys.argv[2]); sys.exit(0 if f < h / 4 else 1)" "$q_free" "$q_held"

# --- 30. CORR3: an empty or non-list mutant manifest is a REFUSAL, not a green run
#     The verdict is `0 if n_ok == len(results)`, and `0 == 0` holds for `[]` -- so a generator that
#     produced nothing, or a path typo answering with an empty array, used to earn
#     "0/0 mutants matched expectation" and exit 0 with no mutant ever armed. Every caller gates on
#     that status. The refusal must also land BEFORE the baseline, so a no-evidence run does not
#     even spend the suite.
bash "$BASE/mk_test.sh" 3 "$BASE/src_test.py"        # green, so only the manifest can refuse
printf '[]\n' > "$SANDBOX/empty.json"
python3 "$BASE/mutate.py" --root="$BASE" --src=src.py --test=src_test.py --copy-dir=copy \
  --mutants="$SANDBOX/empty.json" --test-cmd='python3 {test} {filter}' --filter-flag=-k --no-lock \
  >"$SANDBOX/empty.out" 2>&1; rc=$?
check "an EMPTY manifest is refused as usage (rc 4, got $rc)" [ "$rc" -eq 4 ]
check "the empty manifest never claims a matched expectation" \
  bash -c "! grep -q 'matched expectation' '$SANDBOX/empty.out'"
check "and it is refused before the baseline suite is spent" \
  bash -c "! grep -q '^baseline OK' '$SANDBOX/empty.out'"
printf '{"label":"M1","old":"a","new":"b","expect":"killed"}\n' > "$SANDBOX/dict.json"
python3 "$BASE/mutate.py" --root="$BASE" --src=src.py --test=src_test.py --copy-dir=copy \
  --mutants="$SANDBOX/dict.json" --test-cmd='python3 {test} {filter}' --filter-flag=-k --no-lock \
  >"$SANDBOX/dict.out" 2>&1; rc=$?
check "a manifest that is a JSON object, not an array, is refused (rc 4, got $rc)" [ "$rc" -eq 4 ]
check "the refusal names the shape it wanted, so a typo is fixable from the message" \
  grep -q 'JSON ARRAY' "$SANDBOX/dict.out"
check "iterating a dict's KEYS never reached the arming code" \
  bash -c "! grep -qE '^(KILLED|SURVIVED|MISARMED)' '$SANDBOX/dict.out'"
# control: the identical command with a one-entry ARRAY proceeds, spends the baseline, and kills it
python3 "$BASE/mutate.py" --root="$BASE" --src=src.py --test=src_test.py --copy-dir=copy \
  --mutants="$BASE/m.json" --test-cmd='python3 {test} {filter}' --filter-flag=-k --no-lock \
  >"$SANDBOX/nonempty.out" 2>&1; rc=$?
check "control: a one-entry manifest on the same fixture runs and kills its mutant (rc $rc)" \
  bash -c "[ $rc -eq 0 ] && grep -q '^baseline OK' '$SANDBOX/nonempty.out' && grep -q '^KILLED' '$SANDBOX/nonempty.out'"

# --- 31. CORR4: a mutant whose edits cancel is MISARMED, never SURVIVED
#     Unique anchors are not enough: the arming code applied every edit and never asked whether the
#     RESULT differed. `expect: survived` is the expectation a no-op satisfies for free, so a
#     manifest entry with old == new -- or a multi-edit sequence that cancels -- reported
#     "SURVIVED OK, 1/1 matched" while running the ORIGINAL source.
printf '[{"label":"N1 old == new","old":"    return a + b\\n","new":"    return a + b\\n","expect":"survived"}]\n' > "$SANDBOX/noop.json"
python3 "$BASE/mutate.py" --root="$BASE" --src=src.py --test=src_test.py --copy-dir=copy \
  --mutants="$SANDBOX/noop.json" --test-cmd='python3 {test} {filter}' --filter-flag=-k --no-lock \
  >"$SANDBOX/noop.out" 2>&1; rc=$?
check "an old == new mutant is MISARMED and the run fails (rc 2, got $rc)" \
  bash -c "[ $rc -eq 2 ] && grep -q '^MISARMED' '$SANDBOX/noop.out'"
check "it is never reported SURVIVED, which is the reading that would have passed" \
  bash -c "! grep -q '^SURVIVED' '$SANDBOX/noop.out'"
printf '[{"label":"N2 two edits that cancel","old":["    return a + b\\n","    return a - b\\n"],"new":["    return a - b\\n","    return a + b\\n"],"expect":"survived"}]\n' > "$SANDBOX/cancel.json"
python3 "$BASE/mutate.py" --root="$BASE" --src=src.py --test=src_test.py --copy-dir=copy \
  --mutants="$SANDBOX/cancel.json" --test-cmd='python3 {test} {filter}' --filter-flag=-k --no-lock \
  >"$SANDBOX/cancel.out" 2>&1; rc=$?
check "a multi-edit mutant whose edits cancel is MISARMED too (rc 2, got $rc)" \
  bash -c "[ $rc -eq 2 ] && grep -q '^MISARMED' '$SANDBOX/cancel.out'"
check "each edit's anchor was unique, so only the byte-identical RESULT could have caught it" \
  grep -q 'BYTE-IDENTICAL' "$SANDBOX/cancel.out"
# control: a real edit on the SAME fixture with the SAME `expect: survived` is armed and survives,
# so the refusal above is about emptiness and not about survived-expectations being unsupported.
printf '[{"label":"N3 a real edit the test cannot see","old":"    return a + b\\n","new":"    return b + a\\n","expect":"survived"}]\n' > "$SANDBOX/real-survivor.json"
python3 "$BASE/mutate.py" --root="$BASE" --src=src.py --test=src_test.py --copy-dir=copy \
  --mutants="$SANDBOX/real-survivor.json" --test-cmd='python3 {test} {filter}' --filter-flag=-k --no-lock \
  >"$SANDBOX/real-survivor.out" 2>&1; rc=$?
check "control: an armed mutant the test cannot see is SURVIVED, not MISARMED (rc $rc)" \
  bash -c "[ $rc -eq 0 ] && grep -q '^SURVIVED' '$SANDBOX/real-survivor.out' && ! grep -q '^MISARMED' '$SANDBOX/real-survivor.out'"

# --- 32. LIFE1: a SIGKILLed job ledgers no end, and the round must then refuse to close
#     Section 28 covers SIGTERM, where the handler still writes a terminal row. SIGKILL runs no
#     handler at all, which is the case that leaves a `start` with nothing after it. Closing such a
#     round would profile over a hole: the job's whole wall-clock is unaccounted, and the boundary
#     levers would read a round that was never measured as if it had been.
KARC="$SANDBOX/killarc"; mkdir -p "$KARC"; preflight_arc "$KARC"
python3 "$SKILL/loop.py" run --arc="$KARC" --track=K --round=1 --kind=other --name=doomed \
  --tree="$WORK" -- sleep 31.5 >/dev/null 2>&1 &
kpid=$!
i=0
while ! grep -q '"ev": "start".*"name": "doomed"' "$KARC/jobs.jsonl" 2>/dev/null && [ "$i" -lt 300 ]; do
  sleep 0.05; i=$((i + 1))
done
check "the doomed job really started" grep -q '"ev": "start".*"name": "doomed"' "$KARC/jobs.jsonl"
kill -KILL "$kpid" 2>/dev/null; wait "$kpid" 2>/dev/null || true
pkill -f 'sleep 31.5' 2>/dev/null || true          # reap the orphan so it holds no tree lock
i=0; while pgrep -f 'sleep 31.5' >/dev/null 2>&1 && [ "$i" -lt 100 ]; do sleep 0.05; i=$((i + 1)); done
check "SIGKILL left a start with no terminal event (this is the hole)" \
  bash -c "grep -q '\"name\": \"doomed\"' '$KARC/jobs.jsonl' && ! grep -q '\"ev\": \"end\"' '$KARC/jobs.jsonl'"
python3 "$SKILL/loop.py" close-round --arc="$KARC" --track=K --round=1 >"$SANDBOX/killclose.out" 2>&1; rc=$?
check "close-round refuses to close over the hole (rc 5, got $rc)" [ "$rc" -eq 5 ]
check "and it names the job it cannot account for, rather than a bare count" \
  grep -q 'doomed' "$SANDBOX/killclose.out"
# control: a round on the same arc whose job DID end closes cleanly, so the refusal is about the
# missing terminal event and not about this arc, this tree, or close-round being broken.
python3 "$SKILL/loop.py" run --arc="$KARC" --track=K2 --round=1 --kind=other --name=clean \
  --tree="$WORK" -- true >/dev/null 2>&1
python3 "$SKILL/loop.py" close-round --arc="$KARC" --track=K2 --round=1 >"$SANDBOX/cleanclose.out" 2>&1; rc=$?
check "control: a round whose every job ended DOES close (rc 0, got $rc)" [ "$rc" -eq 0 ]

# --- 33. LIFE7: a measured duration is never negative, whatever the clock does
#     Every consumer of span_s and queued_s treats them as DURATIONS: L5 sums queued time to decide
#     the queue lever, L6 subtracts busy time from wall to find unexplained gaps. A negative one does
#     not fail -- it silently subtracts from the arc's measured wait, so the profiler under-reports
#     exactly the contention it exists to find. The clamps are the invariant; this pins them.
CLK="$SANDBOX/clock"; mkdir -p "$CLK/arc-clamped" "$CLK/arc-unclamped" "$CLK/locks"
sed -e "s/end_ev\['span_s'\] = max(0.0, float(span_s))/end_ev['span_s'] = float(span_s)/" \
    -e 's/self.queued_s = max(0.0, time.monotonic() - t0)/self.queued_s = time.monotonic() - t0/' \
    -e 's/span_s = max(0.0, time.monotonic() - m_start)/span_s = time.monotonic() - m_start/' \
    "$SKILL/loop.py" > "$CLK/loop-unclamped.py"
check "the unclamped control really armed (all three clamps removed)" \
  bash -c "! grep -q \"end_ev\\['span_s'\\] = max(0.0\" '$CLK/loop-unclamped.py' && ! grep -q 'queued_s = max(0.0' '$CLK/loop-unclamped.py' && ! grep -q 'span_s = max(0.0, time.monotonic' '$CLK/loop-unclamped.py'"
cat > "$CLK/drive.py" <<'CLKPY'
import importlib.util, json, os, sys
path, arc = sys.argv[1], sys.argv[2]
spec = importlib.util.spec_from_file_location('lp_under_test', path)
lp = importlib.util.module_from_spec(spec)
spec.loader.exec_module(lp)
# A clock that steps BACKWARDS between the two reads any duration here is made of. monotonic() is
# monotonic in production, so this is not a reachable input -- it is the only way to ask whether the
# clamp is load-bearing, which is the question a future edit removing it needs answered.
seq = iter([100.0, 40.0])
lp.time.monotonic = lambda: next(seq, 40.0)
locks = lp.Locks(None, None, 'sh', holder='clock-probe')
queued = locks.acquire()
locks.release()
lp.record_job(arc, 'C', 1, 'other', 'probe', 1.0, 2.0, 0, span_s=-5.0)
evs = [json.loads(l) for l in open(os.path.join(arc, 'jobs.jsonl'))]
span = [e['span_s'] for e in evs if e.get('ev') == 'end'][-1]
print('queued=%.1f span=%.1f' % (queued, span))
CLKPY
CC_LOCK_DIR="$CLK/locks" python3 "$CLK/drive.py" "$SKILL/loop.py" "$CLK/arc-clamped" \
  >"$SANDBOX/clock.out" 2>&1
check "a backwards clock still yields a non-negative queue and span ($(cat "$SANDBOX/clock.out"))" \
  grep -qx 'queued=0.0 span=0.0' "$SANDBOX/clock.out"
CC_LOCK_DIR="$CLK/locks" python3 "$CLK/drive.py" "$CLK/loop-unclamped.py" "$CLK/arc-unclamped" \
  >"$SANDBOX/clock-ctrl.out" 2>&1
check "control: without the clamps the same clock writes NEGATIVE durations ($(cat "$SANDBOX/clock-ctrl.out"))" \
  grep -qx 'queued=-60.0 span=-5.0' "$SANDBOX/clock-ctrl.out"

# Round 4 (TEST3): the leg above hands `record_job` a negative span directly, which pins the clamp
# at the WRITE site and never executes the one a real run's number comes from -- `span_s = max(0.0,
# time.monotonic() - m_start)` inside cmd_run. Measured while writing this: removing only the two
# clamps above leaves a real run reporting span 0.0, i.e. the existing control could not tell the
# cmd_run clamp from its absence. This leg drives the whole `loop.py run` path instead, so both
# numbers are produced by the code that produces them in production.
cat > "$CLK/drive-real.py" <<'CLKPY2'
import importlib.util, itertools, json, os, sys
path, arc, tree = sys.argv[1], sys.argv[2], sys.argv[3]
spec = importlib.util.spec_from_file_location('lp_under_test', path)
lp = importlib.util.module_from_spec(spec)
spec.loader.exec_module(lp)
# Strictly DECREASING in fixed 100 s steps, so every delta cmd_run measures is a large negative
# number rather than a rounding artefact -- a control that reads -0.0 proves nothing.
step = itertools.count()
lp.time.monotonic = lambda: 10000.0 - 100.0 * next(step)
rc = lp.main(['run', '--arc', arc, '--track', 'R', '--round', '1', '--kind', 'other',
              '--name', 'realrun', '--tree', tree, '--', 'true'])
evs = [json.loads(l) for l in open(os.path.join(arc, 'jobs.jsonl'))]
span = [e['span_s'] for e in evs if e.get('ev') == 'end'][-1]
queued = [e['queued_s'] for e in evs if e.get('ev') == 'start'][-1]
print('rc=%d queued=%.1f span=%.1f' % (rc, queued, span))
CLKPY2
mkdir -p "$CLK/arc-real" "$CLK/arc-real-ctrl"
CC_LOCK_DIR="$CLK/locks" python3 "$CLK/drive-real.py" "$SKILL/loop.py" "$CLK/arc-real" "$WORK" \
  >"$SANDBOX/clock-real.out" 2>&1
check "a real loop.py run under a backwards clock ledgers non-negative durations ($(tail -1 "$SANDBOX/clock-real.out"))" \
  grep -qx 'rc=0 queued=0.0 span=0.0' "$SANDBOX/clock-real.out"
CC_LOCK_DIR="$CLK/locks" python3 "$CLK/drive-real.py" "$CLK/loop-unclamped.py" "$CLK/arc-real-ctrl" "$WORK" \
  >"$SANDBOX/clock-real-ctrl.out" 2>&1
check "control: the same run with the clamps gone ledgers a negative queue AND a negative span ($(tail -1 "$SANDBOX/clock-real-ctrl.out"))" \
  grep -qx 'rc=0 queued=-100.0 span=-300.0' "$SANDBOX/clock-real-ctrl.out"


# ============================ round-3 test-quality findings (TEST1..TEST9) ===================
# Each section below closes one finding from round 3's test-quality lens, and each carries the
# SURVIVING MUTATION the lens named -- armed on a COPY of the skill under $SANDBOX, never in this
# tree, which auto-commits.  A control that merely fails differently proves nothing, so every
# control here is the ONE operator the finding named, and it must read GREEN while the property
# is gone.
broken_skill() {   # broken_skill <dest>  -- a pristine, writable copy of the whole skill dir
  rm -rf "$1"; mkdir -p "$1"
  cp -R "$SKILL"/. "$1"/
}

# --- 34. TEST1: the verdict-promotion truth table, all four quadrants
# `if [ "$RC" -eq 0 ] && [ -f "$TMP_OUT" ] && [ -s "$TMP_OUT" ]` decides whether a run counts as a
# verdict.  Only the all-true quadrant was exercised, so two operators in it were free: the first
# `&&` (a FAILED run's leftover output would be promoted) and the `-s` (a zero-byte file would be
# promoted as a verdict).  Both fail OPEN -- the caller sees exit 0 and a file.
# The workdir is the non-repo $SANDBOX/plain so `--one-off` stays unscheduled and this exercises the
# promotion path itself rather than the scheduler.
echo "== 34. verdict promotion: all four quadrants of rc/-f/-s"
PROMO="$SANDBOX/promo"
mkdir -p "$PROMO"
promoted() { [ -f "$SANDBOX/art/out.json" ]; }

WORKDIR="$SANDBOX/plain" launch --one-off -- -p sol
check "quadrant rc=0,present,non-empty: promoted (rc 0, got $?)" test -s "$SANDBOX/art/out.json"

CODEX_STUB_MODE=fail-with-output WORKDIR="$SANDBOX/plain" launch --one-off -- -p sol
rc_b=$?
check "quadrant rc!=0,present,non-empty: launcher fails (rc $rc_b)" test "$rc_b" -ne 0
if promoted; then bad "quadrant rc!=0: a failed run's output must NOT be promoted"
else ok "quadrant rc!=0: a failed run's output is not promoted"; fi

CODEX_STUB_MODE=no-output WORKDIR="$SANDBOX/plain" launch --one-off -- -p sol
rc_c=$?
check "quadrant rc=0,absent: launcher fails (rc $rc_c)" test "$rc_c" -ne 0
if promoted; then bad "quadrant rc=0,absent: nothing may be promoted when codex wrote no file"
else ok "quadrant rc=0,absent: nothing is promoted"; fi

CODEX_STUB_MODE=empty-output WORKDIR="$SANDBOX/plain" launch --one-off -- -p sol
rc_d=$?
check "quadrant rc=0,present,EMPTY: launcher fails (rc $rc_d)" test "$rc_d" -ne 0
if promoted; then bad "quadrant rc=0,EMPTY: a zero-byte verdict must NOT be promoted"
else ok "quadrant rc=0,EMPTY: a zero-byte verdict is not promoted"; fi

# control 1 -- the named mutant on the first `&&`
BRK="$SANDBOX/skill-promo-and"
broken_skill "$BRK"
python3 - "$BRK/run-codex.sh" <<'PY'
import sys
p = sys.argv[1]; s = open(p).read()
old = 'if [ "$RC" -eq 0 ] && [ -f "$TMP_OUT" ] && [ -s "$TMP_OUT" ]; then'
new = 'if [ "$RC" -eq 0 ] || [ -f "$TMP_OUT" ] && [ -s "$TMP_OUT" ]; then'
assert s.count(old) == 1, f'anchor occurs {s.count(old)} times'
open(p, 'w').write(s.replace(old, new))
PY
check "control 1 armed (the first && became ||)" grep -q 'RC" -eq 0 \] || \[ -f' "$BRK/run-codex.sh"
CODEX_STUB_MODE=fail-with-output WORKDIR="$SANDBOX/plain" RUN="$BRK/run-codex.sh" launch --one-off -- -p sol
if promoted; then ok "control 1: with && broken, a FAILED run's output IS promoted (what the check prevents)"
else bad "control 1 did not reproduce -- the && quadrant is not what this test pins"; fi

# control 2 -- the named mutant on `-s`
BRK2="$SANDBOX/skill-promo-s"
broken_skill "$BRK2"
python3 - "$BRK2/run-codex.sh" <<'PY'
import sys
p = sys.argv[1]; s = open(p).read()
old = '[ -s "$TMP_OUT" ]; then'
new = '[ -e "$TMP_OUT" ]; then'
assert s.count(old) == 1, f'anchor occurs {s.count(old)} times'
open(p, 'w').write(s.replace(old, new))
PY
CODEX_STUB_MODE=empty-output WORKDIR="$SANDBOX/plain" RUN="$BRK2/run-codex.sh" launch --one-off -- -p sol
rc_ctl=$?
if [ -f "$SANDBOX/art/out.json" ] && [ ! -s "$SANDBOX/art/out.json" ]; then
  ok "control 2: with -s weakened to -e, a ZERO-BYTE file is promoted as the verdict (rc $rc_ctl)"
else
  bad "control 2 did not reproduce -- the -s quadrant is not what this test pins"
fi

# --- 35. TEST2: --census asserts an EXACT count, not "at least"
# `ok = len(hits) == int(n)` is the arming census: it is how a run proves it enumerated every site
# before trusting itself.  Weakened to `>=` it still refuses an under-count while silently
# accepting a source that grew a new unarmed site -- exactly the direction that matters.
echo "== 35. --census is exact, not a lower bound"
CEN="$SANDBOX/census"
mkdir -p "$CEN"
printf 'def f(a, b):\n    return a + b\n\n\ndef g(a, b):\n    return a + b\n' > "$CEN/src.py"
printf '#!/bin/sh\n[ -f "$1" ] || { echo "test-cmd never reached the copy: $1" >&2; exit 1; }\nprintf "Tests  1 passed (1)\\n"\nexit 0\n' > "$CEN/mk_test.sh"; chmod +x "$CEN/mk_test.sh"
printf 'x\n' > "$CEN/t.py"
printf '[{"label":"C1 plus->minus","old":"def f(a, b):\\n    return a + b\\n","new":"def f(a, b):\\n    return a - b\\n","expect":"survived"}]\n' > "$CEN/m.json"
census_run() {   # census_run <mutate.py> <expected-count>
  python3 "$1" --root="$CEN" --src=src.py --test=t.py --copy-dir=copy \
    --mutants="$CEN/m.json" --test-cmd="$CEN/mk_test.sh {test}" --no-lock \
    --census="return a \+ b=$2" > "$CEN/out.txt" 2>&1
}
census_run "$SKILL/mutate.py" 2; rc_exact=$?
check "census with the true count (2) passes (rc 0, got $rc_exact)" test "$rc_exact" -eq 0
census_run "$SKILL/mutate.py" 1; rc_under=$?
check "census under-count (1) is refused (rc 3, got $rc_under)" test "$rc_under" -eq 3
census_run "$SKILL/mutate.py" 3; rc_over=$?
check "census over-count (3) is refused (rc 3, got $rc_over)" test "$rc_over" -eq 3
check "the refusal names the enumeration it is asking for" grep -q 'enumerate the new sites' "$CEN/out.txt"

BRK3="$SANDBOX/skill-census"
broken_skill "$BRK3"
python3 - "$BRK3/mutate.py" <<'PY'
import sys
p = sys.argv[1]; s = open(p).read()
old = '        ok = len(hits) == int(n)\n'
new = '        ok = len(hits) >= int(n)\n'
assert s.count(old) == 1, f'anchor occurs {s.count(old)} times'
open(p, 'w').write(s.replace(old, new))
PY
census_run "$BRK3/mutate.py" 1; rc_brk=$?
if [ "$rc_brk" -eq 0 ]; then
  ok "control: with == weakened to >=, a source that GREW an unarmed site still reads green (rc 0)"
else
  bad "control did not reproduce -- the >= direction is not what this test pins (rc $rc_brk)"
fi

# --- 36. TEST3: "exactly one anchor" refuses ZERO matches, not only many
# `if count != 1` is the arming precondition.  Only the many-matches side was tested, so `> 1`
# survived -- and `> 1` is the fail-OPEN half: an `old` string that matches NOTHING arms nothing,
# runs the pristine source, and a `survived` expectation is then satisfied by a no-op.
echo "== 36. a zero-match anchor is MISARMED"
ZER="$SANDBOX/zeroanchor"
mkdir -p "$ZER"
printf 'def f(a, b):\n    return a + b\n' > "$ZER/src.py"
printf '#!/bin/sh\n[ -f "$1" ] || { echo "test-cmd never reached the copy: $1" >&2; exit 1; }\nprintf "Tests  1 passed (1)\\n"\nexit 0\n' > "$ZER/mk_test.sh"; chmod +x "$ZER/mk_test.sh"
printf 'x\n' > "$ZER/t.py"
printf '[{"label":"Z1 anchor that is not in the source","old":"    return a * b\\n","new":"    return a %% b\\n","expect":"survived"}]\n' > "$ZER/m.json"
zero_run() {
  python3 "$1" --root="$ZER" --src=src.py --test=t.py --copy-dir=copy \
    --mutants="$ZER/m.json" --test-cmd="$ZER/mk_test.sh {test}" --no-lock > "$ZER/out.txt" 2>&1
}
zero_run "$SKILL/mutate.py"; rc_zero=$?
check "a zero-match anchor fails the run (rc 2, got $rc_zero)" test "$rc_zero" -eq 2
check "it is reported MISARMED" grep -q '^MISARMED' "$ZER/out.txt"
check "the diagnostic says it occurred 0 times" grep -q 'occurs 0 times' "$ZER/out.txt"
if grep -q '^SURVIVED' "$ZER/out.txt"; then bad "a zero-match anchor was reported SURVIVED"
else ok "a zero-match anchor is never reported SURVIVED"; fi

# The control has to defeat BOTH owners of this property, because round 3 gave it a second one.
# `count != 1` refuses to ARM a zero-match anchor; CORR4's byte-identity check then refuses to
# REPORT any batch whose armed result equals the source, which closes the same hole from the far
# end. Breaking only the first leaves the second holding, so a one-guard control reads rc 2 and
# proves nothing about either -- it looks like a failing test and is really a stale control.
# Breaking both is what shows the hole is real and names exactly who closes it.
BRK4="$SANDBOX/skill-anchor"
broken_skill "$BRK4"
python3 - "$BRK4/mutate.py" <<'PY'
import sys
p = sys.argv[1]; s = open(p).read()
for old, new in ((
        '                    if count != 1:\n',
        '                    if count > 1:\n'), (
        '                if misarmed is None and mutated == src_text:\n',
        '                if False:\n')):
    assert s.count(old) == 1, f'anchor occurs {s.count(old)} times: {old!r}'
    s = s.replace(old, new)
open(p, 'w').write(s)
PY
zero_run "$BRK4/mutate.py"; rc_zbrk=$?
if [ "$rc_zbrk" -eq 0 ] && grep -q '^SURVIVED' "$ZER/out.txt"; then
  ok "control: with BOTH the anchor count and the byte-identity check defeated, an anchor matching NOTHING reads SURVIVED and exits 0"
else
  bad "control did not reproduce -- the zero side is not what this test pins (rc $rc_zbrk)"
fi

# ...and the half-broken case is its own assertion: defeating only the arming precondition must
# still refuse, because the second owner is real rather than decorative.
BRK4B="$SANDBOX/skill-anchor-half"
broken_skill "$BRK4B"
python3 - "$BRK4B/mutate.py" <<'PY'
import sys
p = sys.argv[1]; s = open(p).read()
old = '                    if count != 1:\n'
new = '                    if count > 1:\n'
assert s.count(old) == 1, f'anchor occurs {s.count(old)} times'
open(p, 'w').write(s.replace(old, new))
PY
zero_run "$BRK4B/mutate.py"; rc_zhalf=$?
check "with only the anchor count weakened, byte-identity still refuses (rc 2, got $rc_zhalf)" \
  test "$rc_zhalf" -eq 2
check "and it says the armed result was byte-identical" grep -q 'BYTE-IDENTICAL' "$ZER/out.txt"

# --- 37. TEST9: --only refuses a selector that names no mutant
# The same zero-match hazard one level up, on the tool's OWN selector.  `if unmatched:` had no test
# at all, so `False` was free -- and with it, `--only M99` (a typo, a renamed label, a mutant
# deleted from the manifest) runs whatever else matched and reports itself green.
echo "== 37. --only names a mutant that exists, or the run is refused"
ONL="$SANDBOX/only"
mkdir -p "$ONL"
printf 'def f(a, b):\n    return a + b\n' > "$ONL/src.py"
printf '#!/bin/sh\n[ -f "$1" ] || { echo "test-cmd never reached the copy: $1" >&2; exit 1; }\nprintf "Tests  1 passed (1)\\n"\nexit 0\n' > "$ONL/mk_test.sh"; chmod +x "$ONL/mk_test.sh"
printf 'x\n' > "$ONL/t.py"
printf '[{"label":"O1 plus->minus","old":"    return a + b\\n","new":"    return a - b\\n","expect":"survived"}]\n' > "$ONL/m.json"
only_run() {   # only_run <mutate.py> [--only ...]
  local m="$1"; shift
  python3 "$m" --root="$ONL" --src=src.py --test=t.py --copy-dir=copy \
    --mutants="$ONL/m.json" --test-cmd="$ONL/mk_test.sh {test}" --no-lock "$@" > "$ONL/out.txt" 2>&1
}
only_run "$SKILL/mutate.py" --only=O1; rc_o1=$?
check "a selector that names a real mutant runs it (rc 0, got $rc_o1)" test "$rc_o1" -eq 0
only_run "$SKILL/mutate.py" --only=O99; rc_o99=$?
check "a selector matching nothing is refused (rc 4, got $rc_o99)" test "$rc_o99" -eq 4
check "the refusal names the unmatched selector" grep -q "O99" "$ONL/out.txt"
only_run "$SKILL/mutate.py" --only=O1 --only=O99; rc_mix=$?
check "one good + one unknown selector is still refused (rc 4, got $rc_mix)" test "$rc_mix" -eq 4
if grep -qE '^(KILLED|SURVIVED|MISARMED)' "$ONL/out.txt"; then
  bad "the mixed case classified a mutant before refusing -- it must refuse FIRST"
else
  ok "the mixed case refuses before classifying any mutant"
fi

BRK5="$SANDBOX/skill-only"
broken_skill "$BRK5"
python3 - "$BRK5/mutate.py" <<'PY'
import sys
p = sys.argv[1]; s = open(p).read()
old = '        if unmatched:\n'
new = '        if False:\n'
assert s.count(old) == 1, f'anchor occurs {s.count(old)} times'
open(p, 'w').write(s.replace(old, new))
PY
only_run "$BRK5/mutate.py" --only=O1 --only=O99; rc_obrk=$?
if [ "$rc_obrk" -eq 0 ]; then
  ok "control: with the completeness guard off, a typo'd selector is silently dropped and the run is green"
else
  bad "control did not reproduce -- the unmatched guard is not what this test pins (rc $rc_obrk)"
fi

# --- 38. TEST7: a tracked file that MOVES during a run fails the run
# The tracked-file integrity check only ever ran on the happy path, where nothing moved -- so
# `rc = 3 if changed else ...` could be `if False` and every assertion still passed.  That is the
# guard whose whole job is to notice a mutant left armed in a tree that auto-commits.
echo "== 38. a tracked file changed during a run is rc 3, named"
TRK="$SANDBOX/tracked"
mkdir -p "$TRK"
printf 'def f(a, b):\n    return a + b\n' > "$TRK/src.py"
printf 'x\n' > "$TRK/t.py"
printf 'watched\n' > "$TRK/companion.txt"
# The test command is what moves the companion -- i.e. the change happens DURING the run, which is
# the only moment the before/after hashes can see it.
printf '#!/bin/sh\n[ -f "$1" ] || { echo "test-cmd never reached the copy: $1" >&2; exit 1; }\nprintf "moved by the test run\\n" >> "%s/companion.txt"\nprintf "Tests  1 passed (1)\\n"\nexit 0\n' "$TRK" > "$TRK/mk_test.sh"
chmod +x "$TRK/mk_test.sh"
printf '[{"label":"T1 plus->minus","old":"    return a + b\\n","new":"    return a - b\\n","expect":"survived"}]\n' > "$TRK/m.json"
tracked_run() {
  printf 'watched\n' > "$TRK/companion.txt"
  python3 "$1" --root="$TRK" --src=src.py --test=t.py --copy-dir=copy \
    --mutants="$TRK/m.json" --test-cmd="$TRK/mk_test.sh {test}" --no-lock \
    --tracked=companion.txt > "$TRK/out.txt" 2>&1
}
tracked_run "$SKILL/mutate.py"; rc_trk=$?
check "a tracked file moving mid-run fails the run (rc 3, got $rc_trk)" test "$rc_trk" -eq 3
check "the failure NAMES the file that moved" grep -q 'TRACKED FILE CHANGED DURING RUN: companion.txt' "$TRK/out.txt"
check "the summary line says the tracked files did not stay put" grep -q 'tracked files unchanged: False' "$TRK/out.txt"

BRK6="$SANDBOX/skill-tracked"
broken_skill "$BRK6"
python3 - "$BRK6/mutate.py" <<'PY'
import sys
p = sys.argv[1]; s = open(p).read()
old = '        rc = 3 if changed else (0 if n_ok == len(results) else 2)\n'
new = '        rc = 3 if False else (0 if n_ok == len(results) else 2)\n'
assert s.count(old) == 1, f'anchor occurs {s.count(old)} times'
open(p, 'w').write(s.replace(old, new))
PY
tracked_run "$BRK6/mutate.py"; rc_tbrk=$?
if [ "$rc_tbrk" -eq 0 ]; then
  ok "control: with the tracked-file verdict off, a file that MOVED mid-run still exits 0"
else
  bad "control did not reproduce -- the changed->rc3 wiring is not what this test pins (rc $rc_tbrk)"
fi

# --- 39. TEST5: an UNDISPOSITIONED finding is refused, never quietly dropped
# facts-from-verdict.py builds the next round's do-not-re-report block.  A finding with no
# disposition is skipped by `continue`, so without the `if missing: return 2` the command exits 0
# having silently deleted an unresolved finding from the next round's scope -- the whole suite
# stays green while the finding disappears.
echo "== 39. facts-from-verdict refuses an undispositioned finding"
FV="$SANDBOX/facts"
mkdir -p "$FV"
cat > "$FV/verdict.json" <<'JSON'
{"summary": "reproduced both findings against the frozen sha",
 "verdict": "needs-attention",
 "findings": [
   {"severity":"high","confidence":0.9,"title":"first finding","file":"a.py","line_start":1,"line_end":2},
   {"severity":"low","confidence":0.4,"title":"second finding","file":"b.py","line_start":3,"line_end":4}]}
JSON
python3 "$SKILL/facts-from-verdict.py" "$FV/verdict.json" --fixed=0 > "$FV/out.txt" 2> "$FV/err.txt"
rc_fv=$?
check "one of two findings dispositioned is refused (rc 2, got $rc_fv)" test "$rc_fv" -eq 2
check "the refusal names the finding index left undispositioned" grep -q '\[1\]' "$FV/err.txt"
check "it says why an undispositioned finding is not a fact" grep -q 'not a settled fact' "$FV/err.txt"
if [ -s "$FV/out.txt" ]; then bad "a refused run still emitted a facts block"
else ok "a refused run emits no facts block at all"; fi
python3 "$SKILL/facts-from-verdict.py" "$FV/verdict.json" --fixed=0,1 > "$FV/out.txt" 2> "$FV/err.txt"
rc_fv2=$?
check "with every finding dispositioned it succeeds (rc 0, got $rc_fv2)" test "$rc_fv2" -eq 0
check "and emits both blocks" grep -q 'do_not_re_report' "$FV/out.txt"

BRK7="$SANDBOX/skill-facts"
broken_skill "$BRK7"
python3 - "$BRK7/facts-from-verdict.py" <<'PY'
import sys
p = sys.argv[1]; s = open(p).read()
old = '    if missing:\n'
new = '    if False:\n'
assert s.count(old) == 1, f'anchor occurs {s.count(old)} times'
open(p, 'w').write(s.replace(old, new))
PY
python3 "$BRK7/facts-from-verdict.py" "$FV/verdict.json" --fixed=0 > "$FV/out.txt" 2> "$FV/err.txt"
rc_fbrk=$?
if [ "$rc_fbrk" -eq 0 ] && ! grep -q 'second finding' "$FV/out.txt"; then
  ok "control: with the guard off, the undispositioned finding VANISHES from the next round and rc is 0"
else
  bad "control did not reproduce -- the missing-disposition guard is not what this test pins (rc $rc_fbrk)"
fi

# --- 40. TEST6: run-all.sh maps a KILLED suite to 128+n, never to success
# `exit($st & 127 ? 128 + ($st & 127) : $st >> 8)` is the whole reason a SIGKILLed suite -- the OOM
# killer, the 900s cap, a `kill -9` -- cannot be reported as a pass.  For a killed child `$st >> 8`
# is 0, so dropping the signal test turns every kill into `ok`.  Nothing exercised it.
# The perl program is READ OUT OF run-all.sh rather than restated here, so a change to the file
# changes what this test runs.
echo "== 40. run-all.sh reports a signalled suite as 128+n"
RA="$REPO/tests/run-all.sh"
if [ ! -f "$RA" ]; then
  bad "tests/run-all.sh is missing -- cannot pin its signal mapping"
else
  CAP="$SANDBOX/run_capped.sh"
  sed -n '/^run_capped() {/,/^}/p' "$RA" > "$CAP"
  check "extracted run_capped from the live run-all.sh" test -s "$CAP"
  ( SUITE_TIMEOUT=30; . "$CAP"; run_capped sh -c 'kill -9 $$' ) ; rc_sig=$?
  check "a SIGKILLed suite exits 137, not 0 (got $rc_sig)" test "$rc_sig" -eq 137
  ( SUITE_TIMEOUT=30; . "$CAP"; run_capped sh -c 'exit 3' ) ; rc_norm=$?
  check "an ordinary non-zero exit passes through unchanged (3, got $rc_norm)" test "$rc_norm" -eq 3
  ( SUITE_TIMEOUT=30; . "$CAP"; run_capped sh -c 'exit 0' ) ; rc_zero2=$?
  check "a clean suite still exits 0 (got $rc_zero2)" test "$rc_zero2" -eq 0

  CAPB="$SANDBOX/run_capped_broken.sh"
  sed 's/exit($st & 127 ? 128 + ($st & 127) : $st >> 8)/exit($st \& 0 ? 128 + ($st \& 127) : $st >> 8)/' "$CAP" > "$CAPB"
  check "control armed (the signal test masked to 0)" grep -q '\$st & 0 ?' "$CAPB"
  ( SUITE_TIMEOUT=30; . "$CAPB"; run_capped sh -c 'kill -9 $$' ) ; rc_sbrk=$?
  if [ "$rc_sbrk" -eq 0 ]; then
    ok "control: with the signal test masked off, a SIGKILLed suite reports SUCCESS (rc 0)"
  else
    bad "control did not reproduce -- the signal mapping is not what this test pins (rc $rc_sbrk)"
  fi
fi

# --- 41. TEST4: close-round refuses over a job that is STILL RUNNING
# Section 32 covers the dead-but-unterminated job.  This is the other branch: `if live:` had no
# test, so `False` was free -- and with it a round closes while its writer is mid-write, which is
# precisely the state the next round's launch must not be allowed to overlap.
echo "== 41. close-round refuses while a job is still alive"
LARC="$SANDBOX/livearc"
mkdir -p "$LARC"; preflight_arc "$LARC"
python3 "$SKILL/loop.py" run --arc="$LARC" --track=L --round=1 --kind=other --name=stillgoing \
  --tree="$WORK" -- sleep 25 > "$SANDBOX/live.out" 2>&1 &
live_pid=$!
for _ in $(seq 1 100); do grep -q '"ev": "start"' "$LARC/jobs.jsonl" 2>/dev/null && break; sleep 0.2; done
check "the long job started" grep -q '"name": "stillgoing"' "$LARC/jobs.jsonl"
python3 "$SKILL/loop.py" close-round --arc="$LARC" --track=L --round=1 > "$SANDBOX/live-close.txt" 2>&1
rc_live=$?
check "close-round refuses over a live job (rc 5, got $rc_live)" test "$rc_live" -eq 5
check "the refusal NAMES the job still running" grep -q 'stillgoing' "$SANDBOX/live-close.txt"

BRK8="$SANDBOX/skill-live"
broken_skill "$BRK8"
python3 - "$BRK8/loop.py" <<'PY'
import sys
p = sys.argv[1]; s = open(p).read()
old = '        if live:\n'
new = '        if False:\n'
assert s.count(old) == 1, f'anchor occurs {s.count(old)} times'
open(p, 'w').write(s.replace(old, new))
PY
python3 "$BRK8/loop.py" close-round --arc="$LARC" --track=L --round=1 > "$SANDBOX/live-close-brk.txt" 2>&1
rc_lbrk=$?
if [ "$rc_lbrk" -eq 0 ]; then
  ok "control: with the liveness branch off, the round CLOSES over a running writer (rc 0)"
else
  bad "control did not reproduce -- the live branch is not what this test pins (rc $rc_lbrk)"
fi
kill -KILL "$live_pid" 2>/dev/null || true
pkill -f 'sleep 25' 2>/dev/null || true
wait "$live_pid" 2>/dev/null || true

# --- 42. TEST8: a child that never launches still gets a TERMINAL event
# `except OSError` around the spawn is the reason a no-such-binary launch does not leave the job
# reading "still running" forever.  Nothing exercised it, so `except ValueError` was free: the
# OSError then escapes as a traceback AFTER `queued`/`start` are on the ledger, and close-round
# refuses that round for the rest of the arc's life over a job that never existed.
echo "== 42. a launch that never starts is terminalized, not left open"
FARC="$SANDBOX/failarc"
mkdir -p "$FARC"; preflight_arc "$FARC"
python3 "$SKILL/loop.py" run --arc="$FARC" --track=F --round=1 --kind=other --name=nosuchbin \
  --tree="$WORK" -- "$SANDBOX/definitely-not-a-binary" > "$SANDBOX/fail.out" 2>&1
rc_fail=$?
check "a launch failure fails CLOSED (rc 5, got $rc_fail)" test "$rc_fail" -eq 5
check "the ledger carries exactly one terminal event" \
  test "$(grep -c '"ev": "end"\|"ev": "refused"' "$FARC/jobs.jsonl")" -eq 1
check "the terminal event says the launch itself failed" grep -q 'launch failed' "$FARC/jobs.jsonl"
python3 "$SKILL/loop.py" close-round --arc="$FARC" --track=F --round=1 > "$SANDBOX/fail-close.txt" 2>&1
rc_fclose=$?
check "and the round can therefore still be closed (rc 0, got $rc_fclose)" test "$rc_fclose" -eq 0

BRK9="$SANDBOX/skill-launch"
broken_skill "$BRK9"
python3 - "$BRK9/loop.py" <<'PY'
import sys
p = sys.argv[1]; s = open(p).read()
old = ("        except OSError as e:\n"
       "            # A launch that never starts")
new = ("        except ValueError as e:\n"
       "            # A launch that never starts")
assert s.count(old) == 1, f'anchor occurs {s.count(old)} times'
open(p, 'w').write(s.replace(old, new))
PY
FARC2="$SANDBOX/failarc2"
mkdir -p "$FARC2"
python3 "$BRK9/loop.py" preflight --arc="$FARC2" \
  --critical-path='the stub codex run itself; nothing else is in flight in this harness' \
  --parallel='the three lens tracks launch together against one frozen sha' \
  --batch='all checks in one process; the mutation batches run one interpreter per mutant' \
  --scope='only run-codex.sh, loop.py and mutate.py -- this suite reviews nothing else' \
  --stop='at most 1 full pass of this file; the FAILURES line is the bound' \
  --drivers='interpreter start-up and the deliberate sleeps; no model spend (codex is a stub)' \
  --codex-unavailable='a test fixture never calls a model' >/dev/null 2>&1
python3 "$BRK9/loop.py" run --arc="$FARC2" --track=F --round=1 --kind=other --name=nosuchbin \
  --tree="$WORK" -- "$SANDBOX/definitely-not-a-binary" > "$SANDBOX/fail-brk.out" 2>&1
rc_fbrk2=$?
# `grep -c` PRINTS 0 and EXITS 1 when it matches nothing, so `|| echo 0` fires on top of grep's own
# zero and the variable holds the two-line string "0\n0" -- which `[ "$n_term" -eq 0 ]` then rejects
# with "integer expression expected", turning the control's own bookkeeping into the failure. The
# guard belongs on the value (empty -> 0), never on the exit status.
n_term="$(grep -c '"ev": "end"\|"ev": "refused"' "$FARC2/jobs.jsonl" 2>/dev/null | head -1)"
[ -n "$n_term" ] || n_term=0
python3 "$BRK9/loop.py" close-round --arc="$FARC2" --track=F --round=1 > "$SANDBOX/fail-close-brk.txt" 2>&1
rc_fcbrk=$?
if [ "$n_term" -eq 0 ] && [ "$rc_fcbrk" -ne 0 ]; then
  ok "control: with the wrong exception named, the job has NO terminal event and the round can never close (rc $rc_fcbrk)"
else
  bad "control did not reproduce -- terminals=$n_term close-rc=$rc_fcbrk (launch rc $rc_fbrk2)"
fi

# --- 43. a direct mutate.py run goes through the SAME round gate as loop.py run
# mutate.py opened its ledger row with two bare `ledger_append` calls: no admission check, no round
# lock.  So `mutate.py --arc A --track T --round 1` against an ALREADY CLOSED round appended and
# executed, and racing a close-round let the closure snapshot the ledger before the events appeared
# -- a round whose authoritative profile omits a job that ran inside it.
echo "== 43. mutate.py is admitted through the round gate, or not at all"
GAT="$SANDBOX/mutgate"
mkdir -p "$GAT"
printf 'def f(a, b):\n    return a + b\n' > "$GAT/src.py"
printf '#!/bin/sh\n[ -f "$1" ] || { echo "test-cmd never reached the copy: $1" >&2; exit 1; }\nprintf "Tests  1 passed (1)\\n"\nexit 0\n' > "$GAT/mk_test.sh"; chmod +x "$GAT/mk_test.sh"
printf 'x\n' > "$GAT/t.py"
printf '[{"label":"G1 plus->minus","old":"    return a + b\\n","new":"    return a - b\\n","expect":"survived"}]\n' > "$GAT/m.json"
GARC="$SANDBOX/gatearc"
mkdir -p "$GARC"
# Through the harness's own helper, never a second hand-rolled preflight. The hand-rolled one this
# replaces answered `--stop='one pass'`, which loop.py refuses as too short to be an answer -- and
# it swallowed that refusal with `2>/dev/null`, so round 1 stayed gated-because-unpaid and every
# check below read rc 6 with no cause printed anywhere. preflight_arc fails LOUD for that reason.
preflight_arc "$GARC"
gate_run() {   # gate_run <mutate.py> [attribution flags...]
  _m="$1"; shift
  python3 "$_m" --root="$GAT" --src=src.py --test=t.py --copy-dir=copy \
    --mutants="$GAT/m.json" --test-cmd="$GAT/mk_test.sh {test}" --no-lock \
    "$@" > "$GAT/out.txt" 2>&1
}
gate_run "$SKILL/mutate.py" --arc="$GARC" --track=G --round=1; rc_open=$?
check "an OPEN round admits the batch (rc 0, got $rc_open)" test "$rc_open" -eq 0
check "the batch is ledgered as a mutant job" grep -q '"kind": "mutant"' "$GARC/jobs.jsonl"
python3 "$SKILL/loop.py" close-round --arc="$GARC" --track=G --round=1 > "$GAT/close.txt" 2>&1
rc_close=$?
check "the round closes over the ledgered batch (rc 0, got $rc_close)" test "$rc_close" -eq 0
n_before="$(grep -c '"ev": "queued"' "$GARC/jobs.jsonl" | head -1)"
gate_run "$SKILL/mutate.py" --arc="$GARC" --track=G --round=1; rc_closed=$?
check "a CLOSED round refuses the batch (rc 6, got $rc_closed)" test "$rc_closed" -eq 6
check "the refusal says the round is closed" grep -q 'already CLOSED' "$GAT/out.txt"
n_after="$(grep -c '"ev": "queued"' "$GARC/jobs.jsonl" | head -1)"
check "the refused batch appended NOTHING to the sealed round ($n_before -> $n_after)" \
  test "$n_before" = "$n_after"

# An INCOMPLETE attribution tuple used to disable ledgering silently, which is the same hole
# reached by omission instead of by timing: the batch ran unattributed and ungated.
gate_run "$SKILL/mutate.py" --arc="$GARC" --track=G; rc_part=$?
check "arc+track with no round is a USAGE refusal (rc 4, got $rc_part)" test "$rc_part" -eq 4
check "the refusal names the missing half of the tuple" grep -q 'attribution tuple' "$GAT/out.txt"
gate_run "$SKILL/mutate.py" --arc="$GARC" --round=1; rc_part2=$?
check "arc+round with no track is refused too (rc 4, got $rc_part2)" test "$rc_part2" -eq 4
gate_run "$SKILL/mutate.py"; rc_none=$?
check "naming NONE of the three still runs unledgered (rc 0, got $rc_none)" test "$rc_none" -eq 0

BRK10="$SANDBOX/skill-mutgate"
broken_skill "$BRK10"
python3 - "$BRK10/mutate.py" <<'MUTGATE_PY'
import sys
p = sys.argv[1]; s = open(p).read()
old = "            ok, msg = admission_decision(round_status(events, args.track, args.round)['closed'],\n"
new = "            ok, msg = admission_decision(False,\n"
assert s.count(old) == 1, f'anchor occurs {s.count(old)} times'
open(p, 'w').write(s.replace(old, new))
MUTGATE_PY
gate_run "$BRK10/mutate.py" --arc="$GARC" --track=G --round=1; rc_brk10=$?
if [ "$rc_brk10" -eq 0 ]; then
  ok "control: with the closed-round check defeated, the sealed round accepts new work (rc 0)"
else
  bad "control did not reproduce -- the closed-round branch is not what this test pins (rc $rc_brk10)"
fi

# ======================= round-4 findings: the fixes landed this round ==========================
# Everything below pins a behaviour that changed in round 4.  Each one had NO coverage before, and
# each is a fail-OPEN shape: a green report over nothing run, a verdict from a tier nobody chose, a
# second run silently eating the first one's evidence, a mutation batch letting a writer in.

# --- 44. run-all.sh: a filter that selects NOTHING is a refusal, never a green run
# `tests/run-all.sh __typo__` applied the filter INSIDE the loop, so a filter matching no suite ran
# nothing, fell through to `[ "$FAIL" -gt 0 ]` with PASS=0 FAIL=0, printed "0 passed, 0 failed" and
# exited 0.  A typo in a CI line or a wrapper therefore reports a green run over an empty set --
# the same zero-match false green this repo's mutation harness exists to prevent, one level up.
echo "== 44. run-all.sh refuses a zero-match filter"
RA="$SANDBOX/runall"
mkdir -p "$RA/tests"
git init -q "$RA"
printf '#!/usr/bin/env bash\nexit 0\n' > "$RA/tests/alpha.test.sh"
printf '#!/usr/bin/env bash\nexit 0\n' > "$RA/tests/beta.test.sh"
cp "$REPO/tests/run-all.sh" "$RA/tests/run-all.sh"
git -C "$RA" add tests >/dev/null
git -C "$RA" -c user.email=t@t -c user.name=t commit -q -m init

bash "$RA/tests/run-all.sh" __no_suite_has_this__ > "$RA/zero.out" 2> "$RA/zero.err"; rc_zero=$?
check "a zero-match filter is refused (rc 2, got $rc_zero)" test "$rc_zero" -eq 2
check "the refusal counts what it selected against what exists" \
  grep -q "selected 0 of 2 tracked suites" "$RA/zero.err"
check "the refusal lists the tracked suites, so a typo is self-diagnosing" \
  grep -q 'tests/alpha.test.sh' "$RA/zero.err"
check "nothing was reported as passing" bash -c "! grep -q 'passed,' '$RA/zero.out'"

# The guard must be SATISFIABLE, not merely failable: a filter that matches one suite still runs.
bash "$RA/tests/run-all.sh" alpha > "$RA/one.out" 2>&1; rc_one=$?
check "control: a filter matching one suite runs it and exits 0 (rc $rc_one)" test "$rc_one" -eq 0
check "control: exactly one of the two suites was selected" \
  grep -q '1 passed, 0 failed, 1 not selected of 2 tracked suites' "$RA/one.out"

# Broken control, same shape: with the empty-selection refusal defeated, the identical probe reads
# green.  Testing the pieces separately would not settle which operator this section pins.
cp "$REPO/tests/run-all.sh" "$RA/tests/run-all.broken.sh"
# TWO edits, and only the first is a break: this bash (GNU 3.2.57 on macOS) treats the expansion
# of an EMPTY array under `set -u` as a fatal "unbound variable", so a copy with only the guard
# defeated dies at rc 1 -- a refusal, but not the one this section pins, and not one a bash >= 4.4
# CI runner would ever produce. The second edit is the standard `${a[@]+"${a[@]}"}` portability
# shim, which defeats nothing: it makes the same script reach the branch it would reach anywhere
# else, so what the control then measures is the guard and not the interpreter.
python3 - "$RA/tests/run-all.broken.sh" <<'RUNALL_PY'
import sys
p = sys.argv[1]; s = open(p).read()
for old, new in (('if [ "${#SELECTED[@]}" -eq 0 ]; then\n', 'if false; then\n'),
                 ('for s in "${SELECTED[@]}"; do\n', 'for s in ${SELECTED[@]+"${SELECTED[@]}"}; do\n')):
    assert s.count(old) == 1, f'anchor {old!r} occurs {s.count(old)} times'
    s = s.replace(old, new)
open(p, 'w').write(s)
RUNALL_PY
bash "$RA/tests/run-all.broken.sh" __no_suite_has_this__ > "$RA/brk.out" 2>&1; rc_brk=$?
if [ "$rc_brk" -eq 0 ] && grep -q '0 passed, 0 failed' "$RA/brk.out"; then
  ok "control: with the empty-selection refusal removed, the same filter reports a green run (rc 0)"
else
  bad "control did not reproduce -- the empty-selection branch is not what section 44 pins (rc $rc_brk)"
fi

# ...and the same question asked of the REAL tracked artifact, not only of a copy. Selecting zero
# suites runs zero suites, so this costs nothing.
bash "$REPO/tests/run-all.sh" __no_suite_has_this__ > /dev/null 2> "$RA/real.err"; rc_real=$?
check "the tracked run-all.sh itself refuses a zero-match filter (rc 2, got $rc_real)" \
  test "$rc_real" -eq 2

# --- 45. one run per artifact path: <out-file> and <log-file> are owned for the run's duration
# `: > "$LOG"` truncates and the verdict is renamed over <out-file>, so two runs aimed at one pair
# of paths destroy each other's evidence: the second truncates the first's log mid-run (the
# watchdog reads that as freshness, the tier check then reads it as an absent banner) and the loser
# still has a verdict about a range nobody asked about sitting where a caller will read it.
# SKILL.md's own examples used a fixed /tmp/cc-verdict.json for years, so the collision was the
# DEFAULT shape rather than the exotic one.
echo "== 45. artifact paths are locked for the run, and OUT may not be LOG"
# The non-git workdir keeps --one-off unscheduled, so these checks exercise the launcher itself
# rather than the scheduler re-exec.
bash "$RUN" --policy-version "$POLICY" --one-off \
  "$SANDBOX/prompt.txt" "$SANDBOX/art/same.json" "$SANDBOX/art/same.json" "$SANDBOX/plain" -p sol \
  > "$SANDBOX/stdout" 2> "$SANDBOX/stderr"; rc_same=$?
check "<out-file> == <log-file> is refused (rc 2, got $rc_same)" test "$rc_same" -eq 2
check "the refusal says why the two would destroy each other" \
  grep -q 'truncate the verdict' "$SANDBOX/stderr"

# A live holder is refused. Held by THIS shell's pid, which is unambiguously alive -- racing two
# real launchers would make the case depend on scheduling.
rm -rf "$SANDBOX/art/out.json.runlock"
mkdir "$SANDBOX/art/out.json.runlock"
printf '%s\n' "$$" > "$SANDBOX/art/out.json.runlock/pid"
WORKDIR="$SANDBOX/plain" launch --one-off -- -p sol; rc_busy=$?
check "a second run aimed at a live run's <out-file> is refused (rc 2, got $rc_busy)" \
  test "$rc_busy" -eq 2
check "the refusal names the holder" grep -q "already in use by run-codex pid $$" "$SANDBOX/stderr"
check "the refused run never spent a codex call" test ! -e "$CODEX_STUB_MARKER"
check "the refused run did not truncate the holder's lock" test -s "$SANDBOX/art/out.json.runlock/pid"
rm -rf "$SANDBOX/art/out.json.runlock"

# A DEAD holder's lock is reclaimed once, rather than wedging the path forever.
sh -c 'exit 0' & dead=$!; wait "$dead" 2>/dev/null
mkdir "$SANDBOX/art/out.json.runlock"
printf '%s\n' "$dead" > "$SANDBOX/art/out.json.runlock/pid"
WORKDIR="$SANDBOX/plain" launch --one-off -- -p sol; rc_stale=$?
check "control: a stale lock from a dead run is reclaimed, not wedged (rc 0, got $rc_stale)" \
  test "$rc_stale" -eq 0
check "control: the reclaimed run produced its verdict" test -s "$SANDBOX/art/out.json"
check "a finished run leaves no lock behind" test ! -e "$SANDBOX/art/out.json.runlock"
check "a finished run leaves no lock on its log either" test ! -e "$SANDBOX/art/run.log.runlock"

# --- 46. the tier check may not ABSTAIN: an unread banner is not a verdict about the tier
# The check read codex's own banner and, when it could not, printed `tier actually used:
# model=unknown effort=unknown` and exited 0 -- so a run whose banner never appeared was promoted
# exactly like a verified one. "unknown" in a log is the ABSENCE of a verification, not a passing
# one, and the whole point of the check is that a silent profile fall-through is invisible
# otherwise. There are only two honest outcomes: the banner names the tier, or the run is void.
echo "== 46. an unverifiable tier voids the verdict"
CODEX_STUB_NO_BANNER=1 launch --one-off -- -p sol; rc_nb=$?
check "a run that printed no banner is quarantined (rc 8, got $rc_nb)" test "$rc_nb" -eq 8
check "the void verdict is not where a caller would read it" test ! -e "$SANDBOX/art/out.json"
check "the void verdict is kept for inspection" test -s "$SANDBOX/art/out.json.void"
check "the refusal says the tier could not be established" \
  grep -q 'no model/reasoning-effort banner' "$SANDBOX/stderr"
rm -f "$SANDBOX/art/out.json.void"

# The banner is also the only thing that can catch an -m/-c landing somewhere unintended, so what
# was REQUESTED is now compared against what RAN.
CODEX_STUB_MODEL=gpt-5.6-sol launch --one-off -- -m gpt-5.6-terra -c model_reasoning_effort=high
rc_mm=$?
check "a run on a different model than requested is quarantined (rc 8, got $rc_mm)" test "$rc_mm" -eq 8
check "the refusal names both models" grep -q "used model 'gpt-5.6-sol' but 'gpt-5.6-terra'" "$SANDBOX/stderr"
rm -f "$SANDBOX/art/out.json.void"
CODEX_STUB_EFFORT=high launch --one-off -- -m gpt-5.6-sol -c model_reasoning_effort=xhigh; rc_me=$?
check "a run at a different effort than requested is quarantined (rc 8, got $rc_me)" test "$rc_me" -eq 8
check "the refusal names both efforts" grep -q "effort 'high' but 'xhigh'" "$SANDBOX/stderr"
rm -f "$SANDBOX/art/out.json.void"
# Satisfiable in both directions: the identical launch, asking for what the run actually used.
launch --one-off -- -m gpt-5.6-sol -c model_reasoning_effort=high; rc_ok=$?
check "control: request and banner agreeing promotes the verdict (rc 0, got $rc_ok)" \
  bash -c "[ $rc_ok -eq 0 ] && [ -s '$SANDBOX/art/out.json' ] && [ ! -e '$SANDBOX/art/out.json.void' ]"

# --json is refused outright rather than left silently unverified: it replaces the plain banner
# with JSONL, so the tier check would abstain on EVERY run and this whole section would be dead.
launch --one-off -- -p sol --json; rc_js=$?
check "--json is refused (rc 2, got $rc_js)" test "$rc_js" -eq 2
check "the refusal explains that it blinds the tier check" grep -q 'replaces codex' "$SANDBOX/stderr"
check "--json never reached codex" test ! -e "$CODEX_STUB_MARKER"
launch --one-off -- -p sol --experimental-json; rc_js2=$?
check "--experimental-json is refused too (rc 2, got $rc_js2)" test "$rc_js2" -eq 2

# --- 47. a one-off in a FRESH arc is not blocked by a preflight it can never write
# Round 1 of a real arc is gated on an efficiency preflight, and a one-off is scheduled into a
# throwaway arc at round 1 -- so the moment the arc directory is new, every one-off was refused at
# rc 6 for want of a record describing what a REPEATING workflow puts on its critical path. A
# single call is not a loop, so the exemption belongs to the reserved track, decided by the GATE.
# It is NOT the launcher writing itself a passing preflight to get past its own gate.
echo "== 47. the reserved one-off track is exempt from the round-1 preflight"
FRESH="$SANDBOX/fresh-oneoff"
CC_ONEOFF_ARC="$FRESH" launch --one-off -- -p sol; rc_fresh=$?
check "a one-off into a brand-new arc runs (rc 0, got $rc_fresh)" test "$rc_fresh" -eq 0
check "it is ledgered on the reserved track" grep -q '"track": "one-off"' "$FRESH/jobs.jsonl"
check "it was admitted with NO preflight record in the arc" \
  bash -c "! grep -q '\"ev\": \"preflight\"' '$FRESH/jobs.jsonl'"

# The exemption must be narrow. The same fresh-arc shape on an ordinary track is still gated -- if
# this reads 0, the fix disabled the preflight gate rather than exempting one reserved track.
FRESH2="$SANDBOX/fresh-track"
mkdir -p "$FRESH2"
CC_ARC="$FRESH2" CC_TRACK=correctness CC_ROUND=1 launch -- -p sol; rc_gated=$?
check "control: a real track in a fresh arc is still preflight-gated (rc 6, got $rc_gated)" \
  test "$rc_gated" -eq 6

# The track name is written in two files and compared in a third. Pin them equal here so a rename
# on one side cannot silently turn every one-off back into a gate refusal.
RUN_ONEOFF="$(sed -n 's/^ *TRACK="\([^"]*\)"; ROUND=1$/\1/p' "$RUN" | head -1)"
LOOP_ONEOFF="$(python3 -c "import sys; sys.path.insert(0, '$SKILL'); import loop; print(loop.ONE_OFF_TRACK)")"
check "run-codex.sh's reserved track name is loop.py's ONE_OFF_TRACK ('$RUN_ONEOFF' vs '$LOOP_ONEOFF')" \
  bash -c "[ -n '$RUN_ONEOFF' ] && [ '$RUN_ONEOFF' = '$LOOP_ONEOFF' ]"

# --- 48. a mutation batch holds ONE lock set for its whole life, not one per mutant
# The locks used to be taken per child, so between two mutants the tree was unlocked: a scheduled
# `--write` could enter the worktree mid-battery and every later mutant would be judged against a
# source somebody else was editing. And nothing at all keyed the COPY DIRECTORY, so two batches
# pointed at one --copy-dir would arm each other's mutants in the same files.
# The tree lock is SHARED, deliberately: a batch reads the tree, so batches and reviews still
# overlap. Only a writer is excluded.
echo "== 48. the mutation batch's locks span the batch"
MBL="$SANDBOX/mutlocks"
mkdir -p "$MBL"
printf 'def f(a, b):\n    return a + b\n' > "$MBL/src.py"
printf 'x\n' > "$MBL/t.py"
printf '[{"label":"L1 plus->minus","old":"    return a + b\\n","new":"    return a - b\\n","expect":"survived"}]\n' > "$MBL/m.json"
# Slow on purpose: the batch must still be running when the probe below looks at the lock files.
printf '#!/bin/sh\n[ -f "$1" ] || exit 1\nsleep 3\nprintf "Tests  1 passed (1)\\n"\nexit 0\n' > "$MBL/slow.sh"
chmod +x "$MBL/slow.sh"
python3 "$SKILL/mutate.py" --root="$MBL" --src=src.py --test=t.py --copy-dir=copy \
  --mutants="$MBL/m.json" --test-cmd="$MBL/slow.sh {test}" > "$MBL/batch.out" 2>&1 &
MB_PID=$!
LOCKOBS="$(python3 - "$SKILL" "$MBL" "$MB_PID" <<'MUTLOCK_PY'
import sys, os, time, fcntl
sys.path.insert(0, sys.argv[1])
import loop
root, pid = sys.argv[2], int(sys.argv[3])
ld = loop.lock_dir()
copy_lock = os.path.join(ld, loop.path_lock_name(os.path.join(root, 'copy'), 'copy'))
tree_lock = os.path.join(ld, loop.tree_lock_name(root))

def blocked(path, op):
    """True iff `op` on this lock file cannot be taken right now."""
    if not os.path.exists(path):
        return None
    fd = os.open(path, os.O_RDWR | os.O_CREAT, 0o644)
    try:
        fcntl.flock(fd, op | fcntl.LOCK_NB)
        fcntl.flock(fd, fcntl.LOCK_UN)
        return False
    except BlockingIOError:
        return True
    finally:
        os.close(fd)

# Poll rather than sleep a fixed amount: the assertion is about what the batch HOLDS, and a fixed
# sleep would make this a measurement of the machine.
copy_ex = tree_ex = tree_sh = False
deadline = time.monotonic() + 40
while time.monotonic() < deadline:
    try:
        os.kill(pid, 0)
    except OSError:
        break
    if blocked(copy_lock, fcntl.LOCK_EX): copy_ex = True
    if blocked(tree_lock, fcntl.LOCK_EX):
        tree_ex = True
        if blocked(tree_lock, fcntl.LOCK_SH) is False:
            tree_sh = True
    if copy_ex and tree_ex and tree_sh:
        break
    time.sleep(0.05)
print(f'{copy_ex} {tree_ex} {tree_sh}')
MUTLOCK_PY
)"
wait "$MB_PID"; rc_mb=$?
set -- $LOCKOBS
check "the batch completed green (rc 0, got $rc_mb)" test "$rc_mb" -eq 0
check "a second batch on the same --copy-dir is excluded while it runs (observed=$1)" \
  test "${1:-False}" = True
check "a --write job cannot take the tree while the batch runs (observed=$2)" \
  test "${2:-False}" = True
check "another READER may still overlap the batch -- the tree lock is shared (observed=$3)" \
  test "${3:-False}" = True
check "the locks are released when the batch ends" bash -c "
  python3 - '$SKILL' '$MBL' <<'REL_PY'
import sys, os, fcntl
sys.path.insert(0, sys.argv[1])
import loop
root = sys.argv[2]
ld = loop.lock_dir()
for path in (os.path.join(ld, loop.path_lock_name(os.path.join(root, 'copy'), 'copy')),
             os.path.join(ld, loop.tree_lock_name(root))):
    if not os.path.exists(path):
        continue
    fd = os.open(path, os.O_RDWR | os.O_CREAT, 0o644)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        sys.exit(f'still held after the batch: {os.path.basename(path)}')
    finally:
        os.close(fd)
REL_PY
"
# The copy dir must NOT collapse onto the tree's lock: it lives inside the repo, so tree_lock_name
# would resolve it to the git toplevel -- serialising every reader in the arc to protect one
# directory, while STILL letting two different copy dirs collide on it.
LOCKNAMES="$(python3 - "$SKILL" "$MBL" <<'NAMES_PY'
import sys, os
sys.path.insert(0, sys.argv[1])
import loop
root = sys.argv[2]
a = loop.path_lock_name(os.path.join(root, 'copy'), 'copy')
b = loop.path_lock_name(os.path.join(root, 'copy2'), 'copy')
print(a != loop.tree_lock_name(root) and a != b)
NAMES_PY
)"
check "the copy-dir lock names the directory, not the tree, and two copy dirs differ ($LOCKNAMES)" \
  test "$LOCKNAMES" = True

# --- 49. the stall watchdog kills a wedged run and only a wedged run
# The idle window and the poll interval were literals, so nothing could reach the detector in a
# test: `find ... -newermt` could be broken to `false` -- classifying every long run as idle and
# killing healthy work -- with the whole suite still green. They are read from the environment now
# for exactly this reason, and validated, because an empty or non-numeric override would make
# every poll fail and read as a stall.
echo "== 49. the stall watchdog, exercised in both directions"
RUN_CODEX_POLL=1 RUN_CODEX_IDLE_WINDOW=2 RUN_CODEX_STALL_LIMIT=2 CODEX_STUB_MODE=silent \
  CODEX_STUB_SLEEP=30 WORKDIR="$SANDBOX/plain" launch --one-off -- -p sol; rc_wedge=$?
check "a run that goes silent is killed, not waited on forever (rc $rc_wedge, non-zero)" \
  test "$rc_wedge" -ne 0
check "the log records why it was killed" grep -q '\[watchdog\] log idle' "$SANDBOX/art/run.log"
check "no verdict is promoted from a killed run" test ! -e "$SANDBOX/art/out.json"

RUN_CODEX_POLL=1 RUN_CODEX_IDLE_WINDOW=2 RUN_CODEX_STALL_LIMIT=2 CODEX_STUB_MODE=chatty \
  CODEX_STUB_TICKS=6 WORKDIR="$SANDBOX/plain" launch --one-off -- -p sol; rc_alive=$?
check "control: a run that keeps writing outlives the same budget (rc 0, got $rc_alive)" \
  test "$rc_alive" -eq 0
check "control: the live run was never called idle" \
  bash -c "! grep -q '\[watchdog\] log idle' '$SANDBOX/art/run.log'"
check "control: the live run's verdict landed" test -s "$SANDBOX/art/out.json"

# A non-numeric or zero window would make `sleep` and `find` fail every poll, which reads as a
# stall and kills healthy runs -- so it is a refusal before codex is spent, not a fallback.
RUN_CODEX_POLL=0 WORKDIR="$SANDBOX/plain" launch --one-off -- -p sol; rc_p0=$?
check "RUN_CODEX_POLL=0 is refused (rc 2, got $rc_p0)" test "$rc_p0" -eq 2
check "the zero window never reached codex" test ! -e "$CODEX_STUB_MARKER"
RUN_CODEX_IDLE_WINDOW=abc WORKDIR="$SANDBOX/plain" launch --one-off -- -p sol; rc_pw=$?
check "a non-numeric RUN_CODEX_IDLE_WINDOW is refused (rc 2, got $rc_pw)" test "$rc_pw" -eq 2
check "the refusal names the variable" grep -q 'RUN_CODEX_IDLE_WINDOW must be' "$SANDBOX/stderr"

# The third knob was read straight from the environment while the comment above the block claimed
# all three were validated. It is the multiplier in `POLL * STALL_LIMIT`, so a non-numeric value
# made every `[ "$STALE" -ge "$STALL_LIMIT" ]` a shell error and the watchdog never fired at all --
# a wedged run then waits forever, which is the exact failure this whole section exists to prevent.
RUN_CODEX_STALL_LIMIT=-3 WORKDIR="$SANDBOX/plain" launch --one-off -- -p sol; rc_sl=$?
check "a negative RUN_CODEX_STALL_LIMIT is refused (rc 2, got $rc_sl)" test "$rc_sl" -eq 2
check "the refusal names that variable too" grep -q 'RUN_CODEX_STALL_LIMIT must be' "$SANDBOX/stderr"
check "the refused stall limit never reached codex" test ! -e "$CODEX_STUB_MARKER"

# --- 50. the poll waits for the CHILD, not for the clock
# The liveness loop used a bare `sleep "$POLL"`, so a run whose codex had already exited still sat
# out the whole interval -- once per attempt, on every launch. Nothing here could see that: the
# wedge test above passes whether the poll sleeps or busy-spins, and the chatty control passes
# either way too, because its log is refreshed faster than the idle window in both. So both
# directions are pinned here, and neither asserts a duration the machine has to be fast enough to
# meet: the lower bound is a sleep the launcher was TOLD to take, and the upper bound is a 30s
# knob checked against a 15s ceiling for a run that should finish in about one second.
echo "== 50. a finished child does not cost a whole poll, and the poll still waits"
t0=$(date +%s)
CODEX_STUB_MODE= RUN_CODEX_POLL=30 RUN_CODEX_IDLE_WINDOW=25 RUN_CODEX_STALL_LIMIT=15 \
  WORKDIR="$SANDBOX/plain" launch --one-off -- -p sol; rc_fast=$?
fast=$(( $(date +%s) - t0 ))
check "a run whose codex exits at once still succeeds (rc 0, got $rc_fast)" test "$rc_fast" -eq 0
check "and returns without sitting out its 30s poll (took ${fast}s, want < 15)" test "$fast" -lt 15

# The control for that: with the child alive and silent, the kill must not arrive before the
# budget it was given (POLL x STALL_LIMIT = 4s, and a killed run is retried twice more). A
# busy-spinning poll would kill it immediately and still satisfy every
# existing assertion in section 49.
t0=$(date +%s)
RUN_CODEX_POLL=2 RUN_CODEX_IDLE_WINDOW=1 RUN_CODEX_STALL_LIMIT=2 CODEX_STUB_MODE=silent \
  CODEX_STUB_SLEEP=30 WORKDIR="$SANDBOX/plain" launch --one-off -- -p sol; rc_slow=$?
slow=$(( $(date +%s) - t0 ))
check "control: a silent run is still killed (rc $rc_slow, non-zero)" test "$rc_slow" -ne 0
check "control: and not before its 4s budget (took ${slow}s, want >= 3)" test "$slow" -ge 3

[ "$fail" -eq 0 ] && echo "codex-loop: all checks passed" || echo "codex-loop: FAILURES"
exit "$fail"
