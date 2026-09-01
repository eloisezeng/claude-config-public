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

# 8. UNION WITH THE BASE REF. A pull_request run executes the workflow from the merge ref, so a job
#    only the base defines still runs -- deriving from the head alone would never require it.
d=$(mk baseonly); python3 - "$d" <<'PY'
import sys,os,re
d=sys.argv[1]
head=open(os.path.join(d,"head.yml")).read()
# Drop the analyzer job from the HEAD side only; base.yml keeps it. Cut from the job key to the
# NEXT job key at the same indent (or EOF) -- analyzer happens to be last today, and a slice that
# assumed an ordering would silently leave the job in place and let a head-only mutant survive.
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
case_run "job defined only on base, never ran -> NOT-GREEN" 1 "analyzer" "$d"

# 9. ...and the same pair with that job present is GREEN, so case 8 fails for the right reason.
d2=$(mk baseonly_ok); cp "$T/baseonly/head.yml" "$d2/head.yml"
case_run "job defined only on base, ran green -> GREEN" 0 "VERDICT: GREEN" "$d2"

# 10. The expected set is the job's `name:`, not its yaml key, and the workflow's top-level `on:`
#     keys are not jobs. Both are read off the real fixture's own printed expectation.
exp=$(python3 "$DERIVE" deadbeef "$REAL" | head -1)
if printf '%s' "$exp" | grep -qF "web — typecheck" \
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
  mutate accept-any-status   'if st != "completed": why.append' 'if False: why.append'
  mutate accept-any-conclusion 'elif cc not in ("success", "neutral", "skipped"): why.append' 'elif False: why.append'
  mutate allow-empty-expected 'if not expected: why.append' 'if False: why.append'
  mutate dedupe-by-name 'rows.append((p[0], p[1], p[2] if len(p) > 2 else "", p[3] if len(p) > 3 else ""))' 'rows[:] = [r for r in rows if r[0] != p[0]] + [(p[0], p[1], p[2] if len(p) > 2 else "", p[3] if len(p) > 3 else "")]'
  mutate head-only-derivation 'for f in sorted(glob.glob(os.path.join(D, "*.yml"))):' 'for f in [os.path.join(D, "head.yml")]:'
  AFTER=$(md5 -q "$DERIVE_DEFAULT" 2>/dev/null || md5sum "$DERIVE_DEFAULT" | cut -d' ' -f1)
  if [ "$BEFORE" = "$AFTER" ]; then
    echo "ok    the real ci-derive.py is byte-identical after the mutant run ($BEFORE)"
  else
    echo "FAIL  the real ci-derive.py CHANGED during the mutant run"; SUITE_RC=1
  fi
fi

exit $SUITE_RC
