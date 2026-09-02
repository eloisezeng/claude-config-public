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
echo "reasoning effort: high"
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
unset CC_ARC CC_TRACK CC_ROUND CLAUDE_JOB_DIR CODEX_STUB_TOUCH CODEX_STUB_MODE CC_LOOP_JOB CC_LOOP_ARC
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

# --- 15. mutate.py refuses the root (or anything outside it) as the copy dir — with a live control
SENT="$MUT/sentinel.txt"; echo keep > "$SENT"
python3 "$MUT/mutate.py" --root "$MUT" --src loop.py --test loop_test.py --copy-dir . \
  --mutants "$SKILL/loop.mutants.json" --test-cmd 'true' --no-lock >"$SANDBOX/guard1.out" 2>&1; rc=$?
check "--copy-dir . is refused as usage (rc 4, got $rc)" [ "$rc" -eq 4 ]
check "root survives the refused run" bash -c "[ -f '$SENT' ] && [ -f '$MUT/loop.py' ]"
python3 "$MUT/mutate.py" --root "$MUT" --src loop.py --test loop_test.py --copy-dir ../outside \
  --mutants "$SKILL/loop.mutants.json" --test-cmd 'true' --no-lock >"$SANDBOX/guard2.out" 2>&1; rc=$?
check "--copy-dir outside root is refused as usage (rc 4, got $rc)" [ "$rc" -eq 4 ]
check "nothing was created outside root" [ ! -e "$SANDBOX/outside" ]
# control on a THROWAWAY root: with the guard's `or` turned into `and`, `.` is accepted and the root is destroyed
CTRL="$SANDBOX/ctrl"; mkdir -p "$CTRL"; cp "$MUT/loop.py" "$MUT/loop_test.py" "$CTRL/"; echo keep > "$CTRL/sentinel.txt"
sed 's/ != root or copy_dir == root:/ != root and copy_dir == root:/' "$MUT/mutate.py" > "$CTRL/mutate.py"
grep -q 'and copy_dir == root' "$CTRL/mutate.py" || bad "control guard mutant did not arm"
printf '[{"label":"C1","old":"SCOPED_MAX_FILES = 8\\n","new":"SCOPED_MAX_FILES = 100\\n","expect":"survived"}]\n' > "$SANDBOX/one.json"
python3 "$CTRL/mutate.py" --root "$CTRL" --src loop.py --test loop_test.py --copy-dir . \
  --mutants "$SANDBOX/one.json" --test-cmd 'true' --no-lock >"$SANDBOX/guard-ctrl.out" 2>&1; rc=$?
check "control: with the guard broken, --copy-dir . is NOT refused (rc $rc)" [ "$rc" -ne 4 ]
check "control: the broken guard destroyed the root's sentinel (what the guard prevents)" [ ! -f "$CTRL/sentinel.txt" ]

# --- 16. a mutant whose named test selects NOTHING is MISARMED, never SURVIVED — with a broken-detector control
printf '[{"label":"P1 misspelled selector","old":"SCOPED_MAX_FILES = 8\\n","new":"SCOPED_MAX_FILES = 100\\n","expect":"survived","test":"test_this_name_does_not_exist"}]\n' > "$SANDBOX/misarmed.json"
python3 "$MUT/mutate.py" --root "$MUT" --src loop.py --test loop_test.py --copy-dir copy \
  --mutants "$SANDBOX/misarmed.json" --test-cmd 'python3 {test} {filter}' --filter-flag=-k --no-lock >"$SANDBOX/misarmed.out" 2>&1; rc=$?
check "zero-match selector is MISARMED and the run fails (rc $rc)" bash -c "[ $rc -ne 0 ] && grep -q '^MISARMED' '$SANDBOX/misarmed.out'"
check "zero-match selector is never reported SURVIVED" bash -c "! grep -q '^SURVIVED' '$SANDBOX/misarmed.out'"
sed 's/if name and tests_ran(out) == 0:/if name and tests_ran(out) < 0:/' "$MUT/mutate.py" > "$MUT/mutate-broken.py"
grep -q 'tests_ran(out) < 0' "$MUT/mutate-broken.py" || bad "control detector mutant did not arm"
python3 "$MUT/mutate-broken.py" --root "$MUT" --src loop.py --test loop_test.py --copy-dir copy \
  --mutants "$SANDBOX/misarmed.json" --test-cmd 'python3 {test} {filter}' --filter-flag=-k --no-lock >"$SANDBOX/misarmed-ctrl.out" 2>&1; rc=$?
check "control: with the detector broken the same probe reads SURVIVED and exits 0 (rc $rc)" bash -c "[ $rc -eq 0 ] && grep -q '^SURVIVED' '$SANDBOX/misarmed-ctrl.out'"
after2="$(shasum -a 256 "$SKILL/loop.py" "$SKILL/loop_test.py" "$SKILL/mutate.py" | shasum -a 256)"
check "tracked loop.py / loop_test.py / mutate.py untouched by every probe" [ "$after2" = "$(shasum -a 256 "$SKILL/loop.py" "$SKILL/loop_test.py" "$SKILL/mutate.py" | shasum -a 256)" ]

# --- 17. mutate.py refuses to arm a mutant inside a git worktree that does not ignore the copy dir
#     (a tree that auto-commits — like ~/dotfiles/claude itself — would COMMIT the armed mutant)
GITMUT="$SANDBOX/gitmut"; mkdir -p "$GITMUT"
cp "$SKILL/loop.py" "$SKILL/loop_test.py" "$SKILL/mutate.py" "$GITMUT/"
( cd "$GITMUT" && git init -q . && git config user.email t@t && git config user.name t \
  && git add loop.py loop_test.py mutate.py && git commit -qm base )
python3 "$GITMUT/mutate.py" --root "$GITMUT" --src loop.py --test loop_test.py --copy-dir copy \
  --mutants "$SANDBOX/one.json" --test-cmd 'true' --no-lock >"$SANDBOX/git1.out" 2>&1; rc=$?
check "a copy dir inside a git worktree, not ignored, is refused (rc 4, got $rc)" [ "$rc" -eq 4 ]
check "the refusal names why (a commit would carry the armed mutant)" grep -q 'NOT git-ignored' "$SANDBOX/git1.out"
check "nothing was armed in the worktree" [ ! -e "$GITMUT/copy" ]
# BOTH ignore forms must be accepted: `copy/` is what a human writes, and it reads "not ignored"
# on a dir that does not exist yet unless the check probes INSIDE it.
for pat in 'copy/' 'copy'; do
  printf '%s\n' "$pat" > "$GITMUT/.gitignore"
  rm -rf "$GITMUT/copy"
  python3 "$GITMUT/mutate.py" --root "$GITMUT" --src loop.py --test loop_test.py --copy-dir copy \
    --mutants "$SANDBOX/one.json" --test-cmd 'true' --no-lock >"$SANDBOX/git2.out" 2>&1; rc=$?
  check "gitignore pattern '$pat' lets the run proceed (rc 0, got $rc)" [ "$rc" -eq 0 ]
done
printf 'unrelated/\n' > "$GITMUT/.gitignore"
python3 "$GITMUT/mutate.py" --root "$GITMUT" --src loop.py --test loop_test.py --copy-dir copy \
  --mutants "$SANDBOX/one.json" --test-cmd 'true' --no-lock >"$SANDBOX/git3.out" 2>&1; rc=$?
check "an ignore rule that does NOT cover the copy dir is still refused (rc 4, got $rc)" [ "$rc" -eq 4 ]
# live control: with the worktree guard disabled, the same unignored run is accepted
sed 's/if top and not git_ignored(top, copy_dir):/if False and not git_ignored(top, copy_dir):/' \
  "$GITMUT/mutate.py" > "$GITMUT/mutate-noguard.py"
grep -q 'if False and not git_ignored' "$GITMUT/mutate-noguard.py" || bad "worktree-guard control did not arm"
python3 "$GITMUT/mutate-noguard.py" --root "$GITMUT" --src loop.py --test loop_test.py --copy-dir copy \
  --mutants "$SANDBOX/one.json" --test-cmd 'true' --no-lock >"$SANDBOX/git4.out" 2>&1; rc=$?
check "control: with the guard disabled the unignored run is NOT refused (rc $rc)" [ "$rc" -ne 4 ]

[ "$fail" -eq 0 ] && echo "codex-loop: all checks passed" || echo "codex-loop: FAILURES"
exit "$fail"
