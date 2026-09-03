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
echo "model: gpt-5.6-sol"
echo "reasoning effort: ${CODEX_STUB_EFFORT:-high}"
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

# launch [launcher flags...] -- [codex-args...]; positionals are fixed so a case reads as its flags
launch() {
  local flags=()
  while [ "$#" -gt 0 ] && [ "$1" != "--" ]; do flags+=("$1"); shift; done
  [ "$#" -gt 0 ] && shift
  rm -f "$CODEX_STUB_MARKER" "$CODEX_STUB_MARKER.count" "$SANDBOX/art/out.json" "$SANDBOX/art/out.json.tree-moved"
  bash "$RUN" --policy-version "$POLICY" ${flags[@]+"${flags[@]}"} \
       "$SANDBOX/prompt.txt" "$SANDBOX/art/out.json" "$SANDBOX/art/run.log" "${WORKDIR:-$WORK}" "$@" \
       >"$SANDBOX/stdout" 2>"$SANDBOX/stderr"
}

# --- 1. an unattributed launch is refused before codex is spent
launch -- -p sol; rc=$?
check "unattributed launch refused (rc 2, got $rc)" [ "$rc" -eq 2 ]
check "unattributed launch never invoked codex" [ ! -e "$CODEX_STUB_MARKER" ]
check "refusal names the way out (--one-off)" grep -q -- '--one-off' "$SANDBOX/stderr"
check "unattributed launch wrote no ledger" [ ! -e "$LEDGER" ]

# --- 2. --one-off is the explicit unscheduled path: runs, records nothing
launch --one-off -- -p sol; rc=$?
check "--one-off runs (rc 0, got $rc)" [ "$rc" -eq 0 ]
check "--one-off invoked codex and landed the verdict" [ -e "$CODEX_STUB_MARKER" ] && [ -s "$SANDBOX/art/out.json" ]
check "--one-off wrote no ledger" [ ! -e "$LEDGER" ]

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
sed 's/if tests_ran(out) == 0:/if tests_ran(out) < 0:/' "$MUT/mutate.py" > "$MUT/mutate-broken.py"
grep -q 'if tests_ran(out) < 0:' "$MUT/mutate-broken.py" || bad "control detector mutant did not arm"
python3 "$MUT/mutate-broken.py" --root "$MUT" --src loop.py --test loop_test.py --copy-dir copy \
  --mutants "$SANDBOX/misarmed.json" --test-cmd 'python3 {test} {filter}' --filter-flag=-k --no-lock >"$SANDBOX/misarmed-ctrl.out" 2>&1; rc=$?
check "control: with the detector broken the same probe reads SURVIVED and exits 0 (rc $rc)" bash -c "[ $rc -eq 0 ] && grep -q '^SURVIVED' '$SANDBOX/misarmed-ctrl.out'"
after2="$(shasum -a 256 "$SKILL/loop.py" "$SKILL/loop_test.py" "$SKILL/mutate.py" | shasum -a 256)"
check "tracked loop.py / loop_test.py / mutate.py untouched by every probe" [ "$after2" = "$before_all" ]

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
check "the refusal says the tier was unintended" grep -q 'unintended tier' "$SANDBOX/stderr"
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
# an UNTRACKED file is tolerated on purpose: node_modules and a lens's scratch are untracked and
# change nothing about the code under review.
git -C "$SNAP" checkout -- file.txt
: > "$SNAP/scratch-note.txt"
SNAP4="$(python3 "$SKILL/loop.py" snapshot --arc="$SNAPARC" --track=A --round=4 --repo="$WORK" --sha="$SNAPSHA")"; rc=$?
check "an untracked scratch file does not block reuse (rc 0, got $rc)" bash -c "[ $rc -eq 0 ] && [ '$SNAP4' = '$SNAP' ]"

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

[ "$fail" -eq 0 ] && echo "codex-loop: all checks passed" || echo "codex-loop: FAILURES"
exit "$fail"
