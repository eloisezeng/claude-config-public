#!/bin/bash
# ci-green.test.sh -- the runnable controls for ci-green.sh / ci-derive.py.
#
#   ci-green.test.sh                 run the suite against ~/dotfiles/claude/bin/ci-derive.py
#   ci-green.test.sh <derive.py>     run it against another copy (used by the mutant harness)
#   ci-green.test.sh --mutants       run the suite, then re-run it against PARTIALLY broken COPIES
#                                    and require each one to be caught. Never mutates the real file.
#
# Why this exists: a settle detector that only fails is worthless, and one that only passes is
# dangerous. The green case below is REAL captured output -- `gh api repos/your-org/your-project/commits/
# 1e2dd736.../check-runs` on a commit whose CI actually went green -- so the pass side is not a
# success case invented by the same reasoning that wrote the predicate. Every failing case is that
# same real fixture with ONE field changed, so each case isolates one reason.
set -u
SELF_DIR=$(cd "$(dirname "$0")" && pwd)
DERIVE_DEFAULT="$SELF_DIR/ci-derive.py"
FIXTURES="$SELF_DIR/ci-green.fixtures"
REAL="$FIXTURES/real-green-your-project-1e2dd73"

MUTANTS=0
DERIVE="$DERIVE_DEFAULT"
case "${1:-}" in
  --mutants) MUTANTS=1 ;;
  "") : ;;
  *) DERIVE="$1" ;;
esac

[ -f "$DERIVE" ] || { echo "no derive script at $DERIVE" >&2; exit 2; }
[ -f "$REAL/runs.tsv" ] || { echo "missing captured fixture $REAL/runs.tsv" >&2; exit 2; }

PASS=0; FAIL=0
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

# case <name> <expected-exit> <substring-that-must-appear> <fixture-dir>
case_run() {
  local name="$1" want_rc="$2" want_txt="$3" dir="$4"
  local out rc
  out=$(python3 "$DERIVE" deadbeefdeadbeefdeadbeefdeadbeefdeadbeef "$dir" 2>&1); rc=$?
  if [ "$rc" -eq "$want_rc" ] && printf '%s' "$out" | grep -qF "$want_txt"; then
    PASS=$((PASS+1)); printf 'ok    %s\n' "$name"
  else
    FAIL=$((FAIL+1))
    printf 'FAIL  %s (rc=%s want %s; wanted text %s)\n' "$name" "$rc" "$want_rc" "$want_txt"
    printf '%s\n' "$out" | sed 's/^/        /'
  fi
}

# case_absent <name> <expected-exit> <substring-that-must-appear> <substring-that-must-NOT-appear> <dir>
# Some properties are only pinned in the negative: "this job is no longer required" is invisible to a
# presence-only assertion, because a run can be green for a dozen other reasons.
case_absent() {
  local name="$1" want_rc="$2" want_txt="$3" forbid_txt="$4" dir="$5"
  local out rc
  out=$(python3 "$DERIVE" deadbeefdeadbeefdeadbeefdeadbeefdeadbeef "$dir" 2>&1); rc=$?
  if [ "$rc" -eq "$want_rc" ] && printf '%s' "$out" | grep -qF "$want_txt" \
     && ! printf '%s' "$out" | grep -qF "$forbid_txt"; then
    PASS=$((PASS+1)); printf 'ok    %s\n' "$name"
  else
    FAIL=$((FAIL+1))
    printf 'FAIL  %s (rc=%s want %s; wanted %s; forbade %s)\n' "$name" "$rc" "$want_rc" "$want_txt" "$forbid_txt"
    printf '%s\n' "$out" | sed 's/^/        /'
  fi
}

mk() { local d="$T/$1"; mkdir -p "$d"; cp "$REAL/head.yml" "$REAL/base.yml" "$d/"; cp "$REAL/runs.tsv" "$d/"; echo "$d"; }

# 1. SATISFIABILITY. The real captured green commit must PASS. A guard that can only fail is a bug.
case_run "real captured green commit -> GREEN" 0 "VERDICT: GREEN" "$REAL"

# 2. THE FAIL-OPEN CASE THIS TOOL EXISTS FOR: the rollup has been populated with only one check
#    while the rest have not registered yet. "nothing is pending" is TRUE here and is wrong.
d=$(mk lagging); head -1 "$REAL/runs.tsv" > "$d/runs.tsv"
case_run "partially-registered check list -> NOT-GREEN (presence)" 1 "never registered" "$d"

# 2b. REAL captured in-flight output: the same PR's check-runs 90 seconds after the push
#     (2026-09-01, your-org/your-project PR #50, sha a4dacaa). Two jobs in_progress, one queued, plus a
#     third-party GitGuardian check already green -- an "is anything failing?" predicate says no.
case_run "real captured in-flight commit -> NOT-GREEN" 1 "still running" \
  "$FIXTURES/real-pending-your-project-a4dacaa"

# 3. A check still running.
d=$(mk queued); python3 - "$d" <<'PY'
import sys,os
d=sys.argv[1]; p=os.path.join(d,"runs.tsv")
rows=[l.rstrip("\n").split("\t") for l in open(p) if l.strip()]
rows[0]=[rows[0][0],"queued",""]
open(p,"w").write("".join("\t".join(r)+"\n" for r in rows))
PY
case_run "one check still queued -> NOT-GREEN" 1 "still running" "$d"

# 4. A check that completed unsuccessfully.
d=$(mk failed); python3 - "$d" <<'PY'
import sys,os
d=sys.argv[1]; p=os.path.join(d,"runs.tsv")
rows=[l.rstrip("\n").split("\t") for l in open(p) if l.strip()]
rows[1]=[rows[1][0],"completed","failure"]
open(p,"w").write("".join("\t".join(r)+"\n" for r in rows))
PY
case_run "one check failed -> NOT-GREEN" 1 "not successful" "$d"

# 5. A cancelled check is NOT a green one (cancel-in-progress supersedes a run mid-flight).
d=$(mk cancelled); python3 - "$d" <<'PY'
import sys,os
d=sys.argv[1]; p=os.path.join(d,"runs.tsv")
rows=[l.rstrip("\n").split("\t") for l in open(p) if l.strip()]
rows[2]=[rows[2][0],"completed","cancelled"]
open(p,"w").write("".join("\t".join(r)+"\n" for r in rows))
PY
case_run "cancelled check -> NOT-GREEN" 1 "not successful" "$d"

# 6. No checks at all -- the emptiest fail-open shape.
d=$(mk empty); : > "$d/runs.tsv"
case_run "no check-runs at all -> NOT-GREEN" 1 "no check-runs at all" "$d"

# 7. Parser failure must read as NOT-GREEN, never as "nothing required".
d=$(mk noyml); printf 'name: CI\non:\n  push:\n' > "$d/head.yml"; cp "$d/head.yml" "$d/base.yml"
case_run "workflow parses to zero jobs -> NOT-GREEN" 1 "EMPTY required-job set" "$d"

# 8. THE HEAD'S COPY OF A SHARED WORKFLOW WINS. The caller writes every workflow twice, `head.<file>`
#    and `base.<file>`, because a pull_request run executes the MERGE ref -- so a workflow FILE that
#    only the base has still runs, which is case 8b. Reading BOTH copies of the SAME file is a
#    different thing, and it is wrong in the one direction nothing can recover from: the merge ref
#    carries the head's EDIT of that file, so a PR that DELETES a job leaves the base's copy still
#    naming it and the required set demands a check-run that can never appear -- an unmergeable PR
#    with nothing wrong and no commit able to fix it. Measured 2026-09-08 on
#    your-org/your-other-project PR #419, which deleted the `repo layout` job and read
#    `NOT-GREEN -- workflow jobs never registered: ['repo layout']` forever.
#    This case pins BOTH halves: the run is green AND the deleted job is gone from the required set --
#    a presence-only assertion cannot see the difference, since a green run is green for many reasons.
#    Under the pre-2026-09-08 deriver, which globbed both sides flat, this same fixture printed
#    `VERDICT: NOT-GREEN -- workflow jobs never registered: ['analyzer — pytest']` (rc 1), so the
#    assertion below genuinely reddens on the old code rather than passing either way.
d=$(mk head_deletes_job); python3 - "$d" <<'PY'
import sys,os,re
d=sys.argv[1]
head=open(os.path.join(d,"head.yml")).read()
# Drop the analyzer job from the HEAD side only; base.yml keeps it. Cut from the job key to the
# NEXT job key at the same indent (or EOF) -- analyzer happens to be last today, and a slice that
# assumed an ordering would silently leave the job in place and let a base-wins mutant survive.
i=head.index("\n  analyzer:")
m=re.search(r"\n  [A-Za-z0-9_-]+:", head[i+1:])
j=(i+1+m.start()) if m else len(head)
head=head[:i]+head[j:]
assert "  analyzer:" not in head, "fixture failed to remove the analyzer job"
open(os.path.join(d,"head.yml"),"w").write(head)
p=os.path.join(d,"runs.tsv")
rows=[l for l in open(p) if "analyzer" not in l]
open(p,"w").write("".join(rows))
PY
case_absent "a job the HEAD deleted from a shared workflow is NOT required -> GREEN" 0 \
  "VERDICT: GREEN" "analyzer" "$d"

# 8b. ...and the property case 8 replaced is still pinned, in the shape where it is actually TRUE: a
#     workflow FILE the head does not have at all. The merge ref still contains that file, so its
#     jobs still run and are still required. Head-wins must be per-FILE, never "ignore the base".
mk_extra() { # <dirname> -- the real pair plus a base-only workflow file
  local d; d=$(mk "$1")
  cat > "$d/base.extra.yml" <<'YML'
name: extra
on:
  pull_request:
jobs:
  audit:
    name: audit - licences
    runs-on: ubuntu-latest
    steps:
      - run: true
YML
  printf '%s' "$d"
}
d=$(mk_extra base_only_file)
case_run "job from a base-ONLY workflow file, never ran -> NOT-GREEN" 1 "audit - licences" "$d"

# 9. ...and the same pair with that job green is GREEN, so 8b fails on presence and not because the
#    extra file broke the parse.
d=$(mk_extra base_only_file_ok)
printf 'audit - licences\tcompleted\tsuccess\n' >> "$d/runs.tsv"
case_run "job from a base-ONLY workflow file, ran green -> GREEN" 0 "VERDICT: GREEN" "$d"

# 10. The expected set is the job's `name:`, not its yaml key, and the workflow's top-level `on:`
#     keys are not jobs. Both are read off the real fixture's own printed expectation. The line is
#     LOCATED by its label rather than taken as line 1: the header gained an `event=` line, and a
#     positional read would have silently graded the wrong line.
exp=$(python3 "$DERIVE" deadbeef "$REAL" | grep -m1 "expected_jobs=")
if [ -n "$exp" ] && printf '%s' "$exp" | grep -qF "web — typecheck" \
   && ! printf '%s' "$exp" | grep -qE "'(web|analyzer|deploy|push|pull_request|workflow_dispatch)'"; then
  PASS=$((PASS+1)); echo "ok    expected set uses job name:, and on: keys are not jobs"
else
  FAIL=$((FAIL+1)); echo "FAIL  expected set wrong: $exp"
fi

# 11. `skipped` and `neutral` are successful conclusions on purpose (a conditional job that did not
#     need to run must not block a merge). Pinned so a later tightening is a deliberate change.
d=$(mk skipped); python3 - "$d" <<'PY'
import sys,os
d=sys.argv[1]; p=os.path.join(d,"runs.tsv")
rows=[l.rstrip("\n").split("\t") for l in open(p) if l.strip()]
rows[0]=[rows[0][0],"completed","skipped"]; rows[1]=[rows[1][0],"completed","neutral"]
open(p,"w").write("".join("\t".join(r)+"\n" for r in rows))
PY
case_run "skipped/neutral count as successful -> GREEN" 0 "VERDICT: GREEN" "$d"

# 11b. ci-green.sh is documented as a directly-executed command (`~/.claude/bin/ci-green.sh <sha>`)
#      and it uses bash-only syntax (`${FULL:0:7}`). With no shebang the kernel returns ENOEXEC and
#      the caller's shell reruns it under /bin/sh -- bash-as-sh here, dash on Linux, where that
#      expansion is a syntax error. Pin the shebang, not just "it works on this Mac".
if head -1 "$SELF_DIR/ci-green.sh" | grep -q '^#!.*bash'; then
  PASS=$((PASS+1)); echo "ok    ci-green.sh declares a bash shebang"
else
  FAIL=$((FAIL+1)); echo "FAIL  ci-green.sh has no bash shebang (bash-only syntax would run under sh)"
fi
# ...and it refuses a missing sha as a USAGE error, before spending any API call. `set -u` alone
# does not do this: the unbound `$1` dies inside the command substitution, leaving FULL empty and
# the script querying the API for the empty sha. `gh` is shadowed by a recorder that would make
# any call visible, so this asserts silence rather than assuming it.
usage_t=$(mktemp -d); mkdir -p "$usage_t/bin"
printf '#!/bin/sh\necho called >> "%s/gh-calls"\nexit 0\n' "$usage_t" > "$usage_t/bin/gh"
chmod +x "$usage_t/bin/gh"
usage_out=$(PATH="$usage_t/bin:$PATH" "$SELF_DIR/ci-green.sh" 2>&1); usage_rc=$?
if [ "$usage_rc" -eq 2 ] && printf '%s' "$usage_out" | grep -q '^usage:'; then
  PASS=$((PASS+1)); echo "ok    ci-green.sh with no sha -> usage error, exit 2"
else
  FAIL=$((FAIL+1)); echo "FAIL  ci-green.sh with no sha: expected exit 2 + usage, got rc=$usage_rc: $usage_out"
fi
if [ -e "$usage_t/gh-calls" ]; then
  FAIL=$((FAIL+1)); echo "FAIL  ci-green.sh called gh before validating its arguments"
else
  PASS=$((PASS+1)); echo "ok    ci-green.sh spent no API call on a missing sha"
fi
# Control: the recorder must be able to see a call, or the silence above proves nothing.
PATH="$usage_t/bin:$PATH" gh anything >/dev/null 2>&1
if [ -e "$usage_t/gh-calls" ]; then
  PASS=$((PASS+1)); echo "ok    gh recorder control: a real call IS recorded"
else
  FAIL=$((FAIL+1)); echo "FAIL  gh recorder never records -- the no-call assertion above is vacuous"
fi
rm -rf "$usage_t"

# 12. ci-green.sh must not have grown a `gh pr checks` call. The string appears in its header
#     comment, which is why comments are stripped first: a MENTION is not a call.
code=$(sed 's/#.*$//' "$SELF_DIR/ci-green.sh")
if printf '%s' "$code" | grep -q "gh pr checks"; then
  FAIL=$((FAIL+1)); echo "FAIL  ci-green.sh calls \`gh pr checks\` outside a comment"
else
  PASS=$((PASS+1)); echo "ok    ci-green.sh has no \`gh pr checks\` call (comments stripped)"
fi
# ...and the stripper is controlled: it must still see a real call if one were there.
probe=$(printf '# gh pr checks in a comment\ngh pr checks 48\n' | sed 's/#.*$//')
if printf '%s' "$probe" | grep -q "gh pr checks"; then
  PASS=$((PASS+1)); echo "ok    comment-stripper control: a real call is still visible"
else
  FAIL=$((FAIL+1)); echo "FAIL  comment-stripper control: it would hide a real call too"
fi

# 13-15. DUPLICATE CHECK-RUN NAMES on one sha. GitHub can register more than one check-run under the
#     same job name -- a workflow_dispatch run alongside the pull_request one, or a rerun that adds
#     rather than replaces. (MEASURED 2026-09-01 on your-project PR #50: `gh run rerun --failed` REPLACED
#     the check-run in place, same id 99904356076, new started_at -- so that particular path does not
#     duplicate. The other two paths are still open, and keying by name discards one row either way.)
#     The rule is all-must-be-green, which fails CLOSED; both orderings are pinned because a
#     last-wins dict passes whichever ordering puts the green row last.
dupe_case() { # <dirname> <status1> <conclusion1> <status2> <conclusion2>
  local d; d=$(mk "$1")
  python3 "$SELF_DIR/ci-green.dupe-fixture.py" "$d" "$2" "$3" "$4" "$5"
  printf '%s' "$d"
}
d=$(dupe_case dupe_stale_first completed success in_progress "")
case_run "duplicate names, stale-green FIRST + running second -> NOT-GREEN" 1 "still running" "$d"
d=$(dupe_case dupe_stale_last in_progress "" completed success)
case_run "duplicate names, running FIRST + green second -> NOT-GREEN" 1 "still running" "$d"
d=$(dupe_case dupe_both_green completed success completed success)
case_run "duplicate names, BOTH green -> GREEN (the rule is satisfiable)" 0 "VERDICT: GREEN" "$d"

# 16. MATRIX EXPANSION. A matrix job's `name:` is a template and GitHub registers one check per leg.
#     Measured 2026-09-01 on your-org/your-other-project: taking the template literally put
#     `e2e (chromium layout) ${{ matrix.shard }}/${{ matrix.shardTotal }}` in the required set -- a
#     name no check-run can ever carry -- so the predicate reported NOT-GREEN forever. This case is
#     the SATISFIABILITY control for expansion: the legs are present, so it must go GREEN.
d=$(mk matrix)
cat > "$d/head.yml" <<'YML'
name: ci
on:
  push:
jobs:
  e2e:
    name: leg ${{ matrix.shard }}/${{ matrix.total }}
    strategy:
      fail-fast: false
      matrix:
        shard: [1, 2, 3]
        total: [3]
    steps:
      - run: true
YML
cp "$d/head.yml" "$d/base.yml"
printf 'leg 1/3\tcompleted\tsuccess\t1\nleg 2/3\tcompleted\tsuccess\t2\nleg 3/3\tcompleted\tsuccess\t3\n' > "$d/runs.tsv"
case_run "matrix name expands to its legs -> GREEN (expansion is satisfiable)" 0 "VERDICT: GREEN" "$d"

# 17. ...and it is EXACT, not merely satisfiable: dropping one leg must fail on PRESENCE. A wrong
#     implementation that matched the template loosely (e.g. by prefix) would pass this too, so the
#     missing leg is named in the expectation.
d2=$(mk matrix_missing); cp "$d/head.yml" "$d/base.yml" "$d2/"
head -2 "$d/runs.tsv" > "$d2/runs.tsv"
case_run "a missing matrix leg -> NOT-GREEN, naming that leg" 1 "'leg 3/3'" "$d2"

# 18. FAIL CLOSED on a template the parser cannot resolve. The two wrong answers are symmetrical:
#     keeping the raw template makes the set unsatisfiable (case 16's bug), and silently dropping it
#     makes the set INCOMPLETE -- a fail-open hole in the very presence check this tool exists for.
#     Here `matrix.shard` is referenced but never defined, and the legs are otherwise all green, so
#     nothing but the unresolved-template branch can produce a failure.
d3=$(mk matrix_unresolvable)
cat > "$d3/head.yml" <<'YML'
name: ci
on:
  push:
jobs:
  e2e:
    name: leg ${{ matrix.shard }}
    steps:
      - run: true
YML
cp "$d3/head.yml" "$d3/base.yml"
printf 'leg 1\tcompleted\tsuccess\t1\n' > "$d3/runs.tsv"
case_run "unresolvable templated name -> NOT-GREEN (incomplete set, not a pass)" 1 "could not resolve templated job name" "$d3"


# 19-21. A CHECK-RUN CAN CARRY A CONCLUSION WHILE ITS `status` STILL SAYS in_progress.
#     REAL captured output, 2026-09-02, your-org/your-other-project sha 0f566b00: the job
#     `deploy freeze check` was served as status="in_progress" conclusion="success" while the
#     workflow run itself was completed/success and the other 23 check-runs all read
#     completed/success. A predicate keyed on status=="completed" reports NOT-GREEN forever on
#     that commit -- measured, a watcher timed out ~40 min after CI had actually gone green.
#     Three cases, because the fix has to hold in both directions:
#       19 satisfiability -- the real capture must go GREEN;
#       20 negative control -- clear that one conclusion and it must go back to NOT-GREEN, so 19
#          cannot be passing because the row is being ignored;
#       21 fail-closed -- `completed` with an EMPTY conclusion is still not a pass.
INPROG="$FIXTURES/real-inprogress-with-conclusion-0f566b00"
[ -f "$INPROG/runs.tsv" ] || { echo "missing captured fixture $INPROG/runs.tsv" >&2; exit 2; }
mk_inprog() { local d="$T/$1"; mkdir -p "$d"; cp "$INPROG/head.yml" "$INPROG/base.yml" "$INPROG/runs.tsv" "$d/"; printf '%s' "$d"; }

# 19. the capture, unmodified.
case_run "real capture: in_progress WITH a success conclusion -> GREEN" 0 "VERDICT: GREEN" "$INPROG"

# 20. same fixture, that row's conclusion cleared -> genuinely unfinished.
d=$(mk_inprog inprog_no_conclusion); python3 - "$d" <<'PY'
import sys, os
p = os.path.join(sys.argv[1], "runs.tsv")
rows = [l.rstrip("\n").split("\t") for l in open(p) if l.strip()]
hit = 0
for r in rows:
    if r[1] != "completed":
        while len(r) < 3: r.append("")
        r[2] = ""; hit += 1
assert hit == 1, f"expected exactly one non-completed row in the capture, found {hit}"
open(p, "w").write("".join("\t".join(r) + "\n" for r in rows))
PY
case_run "in_progress with NO conclusion -> NOT-GREEN (the control for 19)" 1 "still running" "$d"

# 21. and the other direction: a finished-looking row with nothing decided is not a pass.
d=$(mk_inprog completed_no_conclusion); python3 - "$d" <<'PY'
import sys, os
p = os.path.join(sys.argv[1], "runs.tsv")
rows = [l.rstrip("\n").split("\t") for l in open(p) if l.strip()]
for r in rows:
    while len(r) < 3: r.append("")
rows[0][1] = "completed"; rows[0][2] = ""
open(p, "w").write("".join("\t".join(r) + "\n" for r in rows))
PY
case_run "completed with an EMPTY conclusion -> NOT-GREEN (fail closed)" 1 "not successful" "$d"


# 22-26. JOB-LEVEL `if:`. It asks the same question as the file-level `on:` block one level down, and
#     a wrong answer costs the same: a job the event cannot satisfy never registers a check-run, so
#     requiring it reports NOT-GREEN forever. Measured 2026-09-08 on your-org/your-other-project, the
#     19-leg chromium sweep moved behind `if: github.event_name == 'schedule' || ... 'workflow_dispatch'`
#     and the required set went on demanding `e2e (chromium layout) 1/19` ... `19/19` on every pull
#     request -- 19 names no pull request could ever produce.
#     Five cases, because the rule has to hold in every direction it can be wrong in.
mk_if() { # <dirname> <the job's if: line, or "" for none>
  local d="$T/$1"; mkdir -p "$d"
  {
    printf 'name: ci\non:\n  pull_request:\njobs:\n  nightly:\n    name: nightly sweep\n'
    [ -n "$2" ] && printf '    if: %s\n' "$2"
    printf '    steps:\n      - run: true\n  quick:\n    name: quick check\n    steps:\n      - run: true\n'
  } > "$d/head.yml"
  cp "$d/head.yml" "$d/base.yml"
  printf 'quick check\tcompleted\tsuccess\n' > "$d/runs.tsv"
  printf '%s' "$d"
}

# 22. the real shape: an event the pull_request run cannot satisfy -> that job is NOT required.
d=$(mk_if if_off_event "github.event_name == 'schedule' || github.event_name == 'workflow_dispatch'")
case_absent "job gated to another event -> not required, GREEN" 0 "VERDICT: GREEN" "never registered" "$d"

# 23. the CONTROL for 22 -- the same fixture with no `if:` at all must go back to NOT-GREEN, naming
#     that job. Without this, 22 could be passing because the job was dropped for some other reason.
d=$(mk_if if_absent "")
case_run "same fixture with NO if: -> NOT-GREEN, naming that job" 1 "'nightly sweep'" "$d"

# 24. FAIL CLOSED on a condition that names the event context but cannot be read. Guessing "it runs"
#     rebuilds the permanent NOT-GREEN this exists to fix; guessing "it is skipped" is a fail-OPEN
#     hole in the required set. Refusing BY NAME is the only answer that is wrong in neither
#     direction, and it names the job so the refusal is actionable.
#
#     This case USED to use `github.event_name == 'schedule' && success()`, and that fixture stopped
#     being unreadable on 2026-09-09 when the parser learned to drop a status function from a
#     conjunction -- so it moved to 24b below, where it is now pinned as a READ, and the unreadable
#     case is carried by a `needs.*` term, which is not a status function and is still refused.
d=$(mk_if if_unreadable "github.event_name == 'schedule' && needs.build.result == 'failure'")
case_run "an unreadable event condition -> NOT-GREEN, refusing by name" 1 "could not read job condition" "$d"

# 24b. A STATUS FUNCTION conjoined onto a readable event term does not make the condition
#      unreadable: a status function is about job OUTCOMES, never about which event fired, so the
#      event half decides registration on its own. `== 'schedule' && success()` cannot run on a
#      pull_request whatever success() says, so that job is NOT required and the verdict is GREEN.
d=$(mk_if if_status_fn_conjunct "github.event_name == 'schedule' && success()")
case_absent "a status fn conjoined onto an off-event term -> not required, GREEN" 0 "VERDICT: GREEN" "never registered" "$d"

# 24c. The shape 24b exists for, and the direction that matters: a FAIL-CLOSED GATE job. GitHub
#      inserts an implicit success() only into a condition naming no status function, so a gate that
#      must still report when a needed job FAILED has to carry `always()`, and an event restriction
#      has to be conjoined onto it -- `always() && github.event_name != 'push'` is the only way to
#      write "fail-closed gate, off on push". On a pull_request that job RUNS, so it stays required
#      and its absence from runs.tsv must read NOT-GREEN by name. Refusing this shape (the behaviour
#      before 2026-09-09) made every pull request in a repo that uses it permanently unreadable.
d=$(mk_if if_always_and_event "always() && github.event_name != 'push'")
case_run "a fail-closed gate gated off push -> still required on a pull_request" 1 "'nightly sweep'" "$d"

# 24d. ...and the OTHER direction of 24c, which is the whole point of the conjunct: `always()` must
#      not swallow the event term. A tautology here would put the job back in the required set on
#      every event, which is the fail-closed-forever bug wearing the opposite sign.
d=$(mk_if if_always_or_event "always() || github.event_name != 'push'")
case_run "a status fn DISJOINED with an event term is still refused" 1 "could not read job condition" "$d"

# 25. ...and the other direction: an `if:` that does not gate on the event at all (`always()`,
#     `success()`, a `needs.*` result) decides nothing about registration, so the job stays REQUIRED.
#     A rule that treated any `if:` as "might not run" would silently shrink the required set.
d=$(mk_if if_not_event_gated "always()")
case_run "an if: that names no event context -> still required" 1 "'nightly sweep'" "$d"

# 26. A STEP's `if:` is not the JOB's. It sits two indents deeper, and reading it as a job condition
#     would drop a job that always runs -- the same fail-open hole as 25, reached by a parser slip.
d=$(mk_if if_on_a_step "")
python3 - "$d" <<'PY'
import sys, os
p = os.path.join(sys.argv[1], "head.yml")
t = open(p).read()
old = "  nightly:\n    name: nightly sweep\n    steps:\n      - run: true\n"
new = "  nightly:\n    name: nightly sweep\n    steps:\n      - run: true\n        if: github.event_name == 'schedule'\n"
assert old in t, "fixture shape changed -- the step-level if: would not be inserted"
open(p, "w").write(t.replace(old, new, 1))
PY
cp "$d/head.yml" "$d/base.yml"
case_run "a STEP-level event condition does not gate the JOB -> still required" 1 "'nightly sweep'" "$d"

# 26a-26g. The OTHER decidable shape: `if: github.event_name != '<lit>'`. A job carrying it is the
#     mirror image of case 22 -- it runs on every event EXCEPT the named ones -- and reading it as
#     unreadable is not a safe default here: measured 2026-09-09 on your-org/your-other-project,
#     `ci.yml`'s `test` job moving behind `if: github.event_name != 'push'` made this predicate
#     answer `VERDICT: NOT-GREEN -- could not read job condition(s) ["test: if: github.event_name !=
#     'push'"]` on every pull request, i.e. a permanently unreadable merge gate. Both directions and
#     every refusal are pinned, because the shape is only safe if the operator and the joiner agree.
mk_if_push() { # <dirname> <the job's if: line> -- same fixture on a PUSH-only trigger, so event=push
  local d="$T/$1"; mkdir -p "$d"
  {
    printf 'name: ci\non:\n  push:\njobs:\n  nightly:\n    name: nightly sweep\n'
    printf '    if: %s\n' "$2"
    printf '    steps:\n      - run: true\n  quick:\n    name: quick check\n    steps:\n      - run: true\n'
  } > "$d/head.yml"
  cp "$d/head.yml" "$d/base.yml"
  printf 'quick check\tcompleted\tsuccess\n' > "$d/runs.tsv"
  printf '%s' "$d"
}

# 26a. the ADMITTING direction: on a pull_request, `!= 'push'` is true, so the job stays REQUIRED --
#      and it must be required by DECISION, not refused, so the refusal text is forbidden here.
d=$(mk_if if_ne_admits "github.event_name != 'push'")
case_absent "an != condition the event satisfies -> still required, no refusal" 1 "'nightly sweep'" \
  "could not read job condition" "$d"

# 26b. ...and the EXCLUDING direction, which is L1's exact shape: the same condition on a push build
#      excludes the job, so it is not required and the run reads GREEN off the jobs that did run.
d=$(mk_if_push if_ne_excludes "github.event_name != 'push'")
case_absent "an != condition the event fails -> not required, GREEN" 0 "VERDICT: GREEN" "never registered" "$d"

# 26c. a CONJUNCTION of != terms, excluding direction.
d=$(mk_if_push if_ne_and_excludes "github.event_name != 'push' && github.event_name != 'schedule'")
case_absent "a conjunction of != terms, one of them the event -> not required, GREEN" 0 \
  "VERDICT: GREEN" "never registered" "$d"

# 26d. ...and the same conjunction where the event is NONE of the named ones -> still required.
d=$(mk_if if_ne_and_admits "github.event_name != 'push' && github.event_name != 'schedule'")
case_absent "a conjunction of != terms, none of them the event -> still required" 1 "'nightly sweep'" \
  "could not read job condition" "$d"

# 26e. MIXED OPERATORS are refused. `a == 'push' || a != 'schedule'` is not one of the two shapes, and
#      evaluating it as if it were either one gives a different answer than GitHub would.
d=$(mk_if if_mixed_ops "github.event_name == 'push' || github.event_name != 'schedule'")
case_run "a mixed ==/!= condition -> NOT-GREEN, refusing by name" 1 "could not read job condition" "$d"

# 26f. An operator paired with the WRONG joiner is refused rather than evaluated: `== && ==` is
#      unsatisfiable and `!= || !=` is a tautology, so either is a typo, not an intent to honour.
d=$(mk_if if_ne_or "github.event_name != 'push' || github.event_name != 'schedule'")
case_run "!= terms joined by || (a tautology) -> NOT-GREEN, refusing by name" 1 \
  "could not read job condition" "$d"

# 26g. MIXED JOINERS are refused even when every term is an event term and every operator agrees --
#      the answer would depend on && binding tighter than ||, which is precedence this predicate has
#      no business adjudicating. Without the refusal this reads FALSE for `push` and silently drops a
#      job that does run: the fail-OPEN direction.
d=$(mk_if_push if_mixed_joiners "github.event_name != 'schedule' && github.event_name != 'workflow_dispatch' || github.event_name != 'push'")
case_run "!= terms with mixed &&/|| joiners -> NOT-GREEN, refusing by name" 1 \
  "could not read job condition" "$d"

# 27-33. FILE-LEVEL `paths:`. The third level of the same question, and the most expensive one to get
#     wrong: a workflow its filter excludes does not run AT ALL, so EVERY job it declares is missing,
#     not just one. Measured 2026-09-08 on your-org/your-other-project, `your-module.yml` moved behind
#     `paths: ['your-module/provider-data/**', ...]` and this predicate went on demanding its jobs on
#     every pull request -- a gate no commit touching other paths could ever satisfy.
mk_paths() { # <dirname> <the `paths:`/`paths-ignore:` block for extra.yml, or "">
  local d="$T/$1"; mkdir -p "$d"
  printf 'name: ci\non:\n  pull_request:\njobs:\n  quick:\n    name: quick check\n    steps:\n      - run: true\n' > "$d/ci.yml"
  { printf 'name: extra\non:\n  pull_request:\n'
    printf '%s' "$2"
    printf 'jobs:\n  provider:\n    name: provider data\n    steps:\n      - run: true\n'
  } > "$d/extra.yml"
  printf 'quick check\tcompleted\tsuccess\n' > "$d/runs.tsv"
  printf '%s' "$d"
}
YOUR-MODULE_PATHS=$'    paths:\n      - \'your-module/provider-data/**\'\n      - \'package.json\'\n'

# 27. the real shape: the pull request touches none of the filtered paths, so that workflow never
#     ran and its jobs are NOT required.
d=$(mk_paths paths_miss "$YOUR-MODULE_PATHS"); printf 'app/page.tsx\nsrc/worker/index.ts\n' > "$d/changed.txt"
case_absent "path filter excludes the workflow -> not required, GREEN" 0 "VERDICT: GREEN" "never registered" "$d"

# 28. the CONTROL for 27 -- one changed file inside the filter and the same jobs are required again.
#     Without this, 27 could be passing because the file was dropped for any other reason.
d=$(mk_paths paths_hit "$YOUR-MODULE_PATHS"); printf 'your-module/provider-data/deliverables/providers.csv\n' > "$d/changed.txt"
case_run "path filter matches a changed file -> that job IS required" 1 "'provider data'" "$d"

# 29. ABSENT is not EMPTY. With no changed-file set at all the filter cannot be evaluated, and both
#     guesses are wrong: "it ran" rebuilds the permanent NOT-GREEN, "it did not" is a fail-OPEN hole.
d=$(mk_paths paths_unknown "$YOUR-MODULE_PATHS")
case_run "a path filter with NO changed-file set -> NOT-GREEN, refusing by name" 1 "could not read the file-level path filter" "$d"

# 30. ...and an EMPTY changed set is a real answer, not the same thing: nothing can match, so the
#     workflow did not run. This is the pair that pins ABSENT != EMPTY in both directions.
d=$(mk_paths paths_empty "$YOUR-MODULE_PATHS"); : > "$d/changed.txt"
case_absent "an EMPTY changed set -> the filtered workflow did not run, GREEN" 0 "VERDICT: GREEN" "never registered" "$d"

# 31. A pattern dialect this does not translate (negation) is refused BY NAME rather than
#     approximated -- an approximate filter is a required set wrong by an unknown amount.
d=$(mk_paths paths_negated $'    paths:\n      - \'!docs/**\'\n'); printf 'app/page.tsx\n' > "$d/changed.txt"
case_run "an untranslatable pattern -> NOT-GREEN, refusing by name" 1 "could not read the file-level path filter" "$d"

# 32. `paths-ignore` is the other polarity and must not be read as `paths`: a pull request touching
#     ONLY ignored files does not run the workflow; one touching anything else does.
d=$(mk_paths ignore_all $'    paths-ignore:\n      - \'docs/**\'\n'); printf 'docs/a.md\ndocs/b/c.md\n' > "$d/changed.txt"
case_absent "paths-ignore covering every changed file -> not required, GREEN" 0 "VERDICT: GREEN" "never registered" "$d"
d=$(mk_paths ignore_some $'    paths-ignore:\n      - \'docs/**\'\n'); printf 'docs/a.md\napp/page.tsx\n' > "$d/changed.txt"
case_run "paths-ignore with one non-ignored file -> that job IS required" 1 "'provider data'" "$d"

# 33. `*` stops at a slash and `**` crosses it. A translator that treats them alike matches
#     `lander/templates/x.ts` against `lander/*.ts` and silently keeps a workflow that never ran.
d=$(mk_paths star_depth $'    paths:\n      - \'lander/*.ts\'\n'); printf 'lander/templates/registry.ts\n' > "$d/changed.txt"
case_absent "a single * does not cross a slash -> not required, GREEN" 0 "VERDICT: GREEN" "never registered" "$d"
d=$(mk_paths star_flat $'    paths:\n      - \'lander/*.ts\'\n'); printf 'lander/shelf.ts\n' > "$d/changed.txt"
case_run "the same pattern DOES match a file at its own depth -> required" 1 "'provider data'" "$d"


echo "----"
echo "$PASS passed, $FAIL failed  (derive under test: $DERIVE)"
SUITE_RC=0; [ "$FAIL" -eq 0 ] || SUITE_RC=1

if [ "$MUTANTS" -eq 1 ]; then
  echo
  echo "=== mutant harness: each PARTIAL breakage must be caught by the suite above ==="
  BEFORE=$(md5 -q "$DERIVE_DEFAULT" 2>/dev/null || md5sum "$DERIVE_DEFAULT" | cut -d' ' -f1)
  MD=$T/mutants; mkdir -p "$MD"
  mutate() { # <name> <python-replacement-expr-file-content>
    local name="$1" old="$2" new="$3"
    local f="$MD/$name.py"
    python3 - "$DERIVE_DEFAULT" "$f" "$old" "$new" <<'PY'
import sys
src=open(sys.argv[1]).read()
old,new=sys.argv[3],sys.argv[4]
assert old in src, "mutation anchor not found: "+old
open(sys.argv[2],"w").write(src.replace(old,new,1))
PY
    local mrc=$?
    # A stale anchor must not read as a CAUGHT mutant: the build fails, no copy is written, and
    # running a missing file exits 2 -- which is non-zero, i.e. indistinguishable from a mutant the
    # suite killed. That is fail-OPEN reporting on the very harness that measures the suite.
    if [ "$mrc" -ne 0 ] || [ ! -f "$f" ]; then
      echo "FAIL  mutant '$name' could not be BUILT -- its anchor is stale, so it proves nothing"
      SUITE_RC=1; return
    fi
    local out rc
    out=$("$0" "$f" 2>&1); rc=$?
    if [ "$rc" -ne 0 ]; then
      echo "ok    mutant '$name' was CAUGHT"
    else
      echo "FAIL  mutant '$name' SURVIVED -- the suite does not test that branch"
      SUITE_RC=1
    fi
  }
  mutate drop-presence-check 'if missing: why.append' 'if False: why.append'
  mutate accept-any-status   'why.append(f"still running: {n} ({st})")' 'pass'
  mutate accept-any-conclusion 'if cc not in ("success", "neutral", "skipped"): why.append' 'if False: why.append'
  # Reverting the conclusion-aware settle rule: this is exactly the predicate that hung on
  # 0f566b00, and case 19 is the only thing in the suite that can see it.
  mutate require-completed-status 'if st == "completed" or cc:' 'if st == "completed" and True:'
  mutate allow-empty-expected 'if not expected: why.append' 'if False: why.append'
  mutate dedupe-by-name 'rows.append((p[0], p[1], p[2] if len(p) > 2 else "", p[3] if len(p) > 3 else ""))' 'rows[:] = [r for r in rows if r[0] != p[0]] + [(p[0], p[1], p[2] if len(p) > 2 else "", p[3] if len(p) > 3 else "")]'
  # Side selection: reading only the head loses a base-ONLY workflow file (case 8b), and letting the
  # BASE copy win re-requires a job the head deleted (case 8) -- the unsatisfiable direction.
  mutate head-only-derivation 'glob.glob(os.path.join(D, "*.yml"))' 'glob.glob(os.path.join(D, "head*.yml"))'
  mutate base-copy-wins 'if name not in by_name or side == "head": by_name[name] = f' 'if name not in by_name or side == "base": by_name[name] = f'
  # The job-level `if:` rule, one mutant per direction: ignore the condition (case 22 goes red), and
  # silently drop a condition that cannot be read instead of refusing (case 24 goes red).
  mutate ignore-job-if 'cond = job_if(m.group(2))' 'cond = None'
  mutate drop-unreadable-if 'unreadable_if.add(f"{m.group(1)}: if: {cond}")' 'pass'
  # The `!=` shape, one mutant per branch it added: refuse to read it at all (case 26b goes red --
  # this is the pre-2026-09-09 behaviour, the permanently unreadable merge gate), invert its polarity
  # (26a and 26b both flip), accept a mixed ==/!= by guessing an operator (26e), and accept mixed
  # joiners by dropping the precedence refusal (26g).
  mutate ne-not-read "EVENT_TERM = re.compile(r\"^github\\.event_name\\s*(==|!=)\\s*'([A-Za-z_]+)'\$\")" "EVENT_TERM = re.compile(r\"^github\\.event_name\\s*(==)\\s*'([A-Za-z_]+)'\$\")"
  mutate ne-polarity-flipped 'if op == "!=" and joiner != "||": return event not in events' 'if op == "!=" and joiner != "||": return event in events'
  mutate guess-a-mixed-operator 'if len(ops) != 1: return None' 'if len(ops) != 1: ops = {"=="}'
  mutate accept-mixed-joiners 'if "||" in e and "&&" in e: return None' 'if False: return None'
  # ...and treating a non-event `if:` as a possible skip, which shrinks the required set (case 25).
  mutate any-if-is-a-skip 'if not any(t in e for t in CONTEXT_TOKENS): return True' 'if not any(t in e for t in CONTEXT_TOKENS): return False'
  # The file-level path filter, one mutant per direction it can be wrong in: ignore the filter
  # (case 27 goes red -- the your-module shape comes straight back), drop an unreadable filter instead
  # of refusing (cases 29 and 31 go red -- the fail-OPEN hole), treat an ABSENT changed set as an
  # empty one (case 29 again -- "not determined" quietly becoming a verdict), invert the polarity of
  # paths-ignore (case 32), and let a single `*` cross a slash (case 33).
  mutate ignore-path-filter 'pf = path_filter(yml, event)' 'pf = None'
  mutate drop-unreadable-path-filter 'if unreadable_paths: why.append' 'if False: why.append'
  mutate absent-changed-set-is-empty 'if os.path.exists(cpath):' 'if True:
    changed = []
if os.path.exists(cpath):'
  mutate flip-paths-ignore 'return any(not hit(f) for f in changed)' 'return any(hit(f) for f in changed)'
  mutate star-crosses-slash 'else: out.append("[^/]*"); i += 1' 'else: out.append(".*"); i += 1'
  # The two ways expansion goes wrong, one mutant each: expand to a single leg (loses the presence
  # check on the others), and drop an unresolvable template instead of refusing (fail-open hole).
  mutate expand-only-first-leg 'names = [pat.sub(v, n) for n in names for v in mtx[k]]' 'names = [pat.sub(mtx[k][0], n) for n in names]'
  mutate ignore-unresolved-template 'if unresolved: why.append' 'if False: why.append'
  AFTER=$(md5 -q "$DERIVE_DEFAULT" 2>/dev/null || md5sum "$DERIVE_DEFAULT" | cut -d' ' -f1)
  if [ "$BEFORE" = "$AFTER" ]; then
    echo "ok    the real ci-derive.py is byte-identical after the mutant run ($BEFORE)"
  else
    echo "FAIL  the real ci-derive.py CHANGED during the mutant run"; SUITE_RC=1
  fi
fi

exit $SUITE_RC
