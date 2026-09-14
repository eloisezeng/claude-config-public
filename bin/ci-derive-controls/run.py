#!/usr/bin/env python3
"""Controls for ci-derive.py's job-level `if:` handling and its head-wins side selection.

    python3 ~/.claude/bin/ci-derive-controls/run.py     # -> ASSERT-* lines, exit 0 iff all pass

Both rules answer one question -- "can this job register a check-run on this sha at all?" -- and
both were added on 2026-09-08 because getting it wrong makes the gate UNSATISFIABLE rather than
merely wrong: a job that never registers can never be reported green, so `ci-green.sh` reads
NOT-GREEN forever and every session that waits on it waits forever.

`fx/` is a REAL capture, not a hand-written mock: the head workflows are your-org/your-other-project
at 681fc6d4 (PR #419, which moved the 19-shard chromium sweep behind a schedule/dispatch `if:`,
deleted the `repo layout` job and moved the your-module job into its own file), the base workflows are
`main` at 67878bda, and `runs.tsv` is that sha's live check-runs. `unmodified-main.ci.yml` is the
base copy again, used by the no-regression case.

Every case copies that capture, changes exactly ONE token, and runs the SAME command the gate runs.
Testing the pieces separately would be a second measurement that happens to agree, not a control.
"""
import os, shutil, subprocess, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
FX = os.path.join(HERE, "fx")
DERIVE = os.path.join(os.path.dirname(HERE), "ci-derive.py")
SHA = "681fc6d43c05d7444760774d80d3285c4b94c684"
MAIN_SHA = "67878bda02c90b437f10187cd4e5ad1e5aaad4c3"

IF_LINE = "    if: github.event_name == 'schedule' || github.event_name == 'workflow_dispatch'\n"

WORK = tempfile.mkdtemp(prefix="ci-derive-controls.")


def fresh(tag):
    d = os.path.join(WORK, tag)
    shutil.copytree(FX, d)
    os.remove(os.path.join(d, "unmodified-main.ci.yml"))
    return d


def run(d, sha=SHA):
    p = subprocess.run([sys.executable, DERIVE, sha, d], capture_output=True, text=True)
    return p.returncode, p.stdout + p.stderr


def rewrite(path, fn):
    with open(path) as fh:
        t = fh.read()
    t2 = fn(t)
    assert t2 != t, f"control changed nothing in {path} -- it would test the same thing twice"
    with open(path, "w") as fh:
        fh.write(t2)


results = []


def check(label, cond, detail=""):
    results.append(cond)
    print(("ASSERT-PASS  " if cond else "ASSERT-FAIL  ") + label + (f"  | {detail}" if detail else ""))


# --- 0: the capture itself. Only the genuinely unfinished job may be named. ------------------------
rc, out = run(fresh("base"))
check("0: on the real capture, the ONLY complaint is the job that was still running",
      "VERDICT: NOT-GREEN -- still running: test + typecheck (in_progress)" in out
      and "never registered" not in out and rc == 1, f"rc={rc}")

# --- A: delete the `if:` the rule reads. The 19 shard legs must come BACK. -------------------------
d = fresh("A")
rewrite(os.path.join(d, "head.ci.yml.yml"), lambda t: t.replace(IF_LINE, "", 1))
rc, out = run(d)
check("A: without that `if:`, all 19 shard legs are demanded again",
      "e2e (chromium layout) 19/19" in out and "never registered" in out and rc == 1, f"rc={rc}")

# --- B: an `if:` that names the event but cannot be parsed must REFUSE, never guess. ---------------
#        The term carrying the unreadability is a `needs.*` result. It used to be `success()`, which
#        stopped being unreadable on 2026-09-09 when the parser learned to drop a status function
#        from a conjunction -- that case moved to B2, where it is pinned as a READ rather than
#        deleted.
d = fresh("B")
rewrite(os.path.join(d, "head.ci.yml.yml"),
        lambda t: t.replace(IF_LINE, "    if: github.event_name == 'schedule' && needs.build.result == 'failure'\n", 1))
rc, out = run(d)
check("B: an unreadable event condition refuses BY NAME rather than guessing either way",
      "could not read job condition" in out and "e2e: if:" in out and rc == 1, f"rc={rc}")

# --- B2: a status function conjoined onto a readable event term is READ, not refused. A status
#         function is about job outcomes, never about which event fired, so the event half decides
#         registration alone -- `== 'schedule' && success()` cannot run on a pull_request whatever
#         success() returns, so those legs stay OFF-EVENT exactly as the bare `== 'schedule' ||
#         == 'workflow_dispatch'` in the real capture does.
d = fresh("B2")
rewrite(os.path.join(d, "head.ci.yml.yml"),
        lambda t: t.replace(IF_LINE, "    if: github.event_name == 'schedule' && success()\n", 1))
rc, out = run(d)
check("B2: a status fn conjoined onto an off-event term is READ, and those legs stay off-event",
      "could not read job condition" not in out and "e2e (chromium layout) 19/19" not in out,
      f"rc={rc}")

# --- B3: the shape B2 exists for. A FAIL-CLOSED GATE has to carry `always()` (GitHub inserts an
#         implicit success() only into a condition naming no status function), so "a fail-closed gate
#         that is off on push" can only be written `always() && github.event_name != 'push'`. On a
#         pull_request it RUNS, so its legs come back into the required set -- identical to control A,
#         which is the proof that the conjunct is being read rather than the whole `if:` ignored.
d = fresh("B3")
rewrite(os.path.join(d, "head.ci.yml.yml"),
        lambda t: t.replace(IF_LINE, "    if: always() && github.event_name != 'push'\n", 1))
rc, out = run(d)
check("B3: a fail-closed gate gated off push is REQUIRED on a pull_request",
      "could not read job condition" not in out and "e2e (chromium layout) 19/19" in out and rc == 1,
      f"rc={rc}")

# --- B4: ...and `always() || <event term>` is a tautology, so it must STILL be refused. Without
#         this, B3 could be passing because the parser started ignoring status functions entirely.
d = fresh("B4")
rewrite(os.path.join(d, "head.ci.yml.yml"),
        lambda t: t.replace(IF_LINE, "    if: always() || github.event_name != 'push'\n", 1))
rc, out = run(d)
check("B4: a status fn DISJOINED with an event term is still refused by name",
      "could not read job condition" in out and "e2e: if:" in out and rc == 1, f"rc={rc}")

# --- C: with the head's ci.yml gone the BASE copy wins, and `repo layout` returns. -----------------
d = fresh("C")
os.remove(os.path.join(d, "head.ci.yml.yml"))
rc, out = run(d)
check("C: head-wins is what dropped `repo layout` -- the base copy still names it",
      "'repo layout'" in out and rc == 1, f"rc={rc}")

# --- D: the predicate can still reach GREEN. A gate that can only fail is unusable. ----------------
d = fresh("D")
rewrite(os.path.join(d, "runs.tsv"),
        lambda t: t.replace("test + typecheck\tin_progress\t\t", "test + typecheck\tcompleted\tsuccess\t"))
rc, out = run(d)
check("D: with the last job finished the verdict is GREEN and the exit status 0",
      "VERDICT: GREEN" in out and rc == 0, f"rc={rc}")

# --- E: a red check still blocks. The fix must not have widened what counts as green. --------------
d = fresh("E")
rewrite(os.path.join(d, "runs.tsv"),
        lambda t: t.replace("deploy freeze check\tcompleted\tsuccess\t", "deploy freeze check\tcompleted\tfailure\t"))
rc, out = run(d)
check("E: a failed required check is still NOT-GREEN",
      "not successful: deploy freeze check (failure)" in out and rc == 1, f"rc={rc}")

# --- F: no regression. On a tree with no event-gated job the required set must be UNCHANGED, so the
#        rule is inert everywhere it does not apply rather than quietly reshaping every repo's gate.
d = fresh("F")
for side in ("head", "base"):
    shutil.copyfile(os.path.join(FX, "unmodified-main.ci.yml"), os.path.join(d, f"{side}.ci.yml.yml"))
os.remove(os.path.join(d, "head.your-module.yml.yml"))
rc, out = run(d, MAIN_SHA)
expected_line = next((l for l in out.splitlines() if "expected_jobs=" in l), "")
check("F: on unmodified `main` the required set still carries all 19 legs and `repo layout`",
      "'repo layout'" in expected_line and "'e2e (chromium layout) 19/19'" in expected_line
      and "'e2e (chromium layout) 1/19'" in expected_line, f"rc={rc}")

# --- G: the fixture's own changed-file set, and the fail-closed rule that reads it. `changed.txt`
#        is what `ci-green.sh` measures with `git diff --name-only <merge-base> <head>`; an ABSENT
#        set means "not determined", never "nothing changed", so every path-filtered workflow must be
#        refused BY NAME rather than assumed to run or assumed to be skipped. This control exists
#        because the fixture had NO changed.txt until 2026-09-09 -- the path-filter rule landed after
#        the capture was taken -- so `head.your-module.yml.yml` was refused on every case and controls 0
#        and D had been reading ASSERT-FAIL, unnoticed, ever since. Supplying the real set fixed
#        those two; this pins the refusal so the absent case is a tested behaviour instead of a
#        silent red.
d = fresh("G")
os.remove(os.path.join(d, "changed.txt"))
rc, out = run(d)
check("G: with NO changed-file set, a path-filtered workflow is refused BY NAME, not assumed",
      "could not read the file-level path filter" in out and "'your-module.yml (no changed-file set)'" in out
      and "no changed-file set" in out and rc == 1, f"rc={rc}")

# --- H: ...and the other direction, so G cannot pass by the filter being unreadable in general: with
#        a changed set that matches NOTHING the your-module filter names, the workflow is decided as
#        SKIPPED, and its job leaves the required set rather than being refused.
d = fresh("H")
with open(os.path.join(d, "changed.txt"), "w") as fh:
    fh.write("README.md\n")
rc, out = run(d)
check("H: a changed set matching no filtered path SKIPS the workflow instead of refusing it",
      "could not read the file-level path filter" not in out and "your-module provider data" not in
      next((l for l in out.splitlines() if "expected_jobs=" in l), ""), f"rc={rc}")

shutil.rmtree(WORK, ignore_errors=True)
ok = all(results)
print(f"RESULT: {sum(results)}/{len(results)} controls passed" + ("" if ok else "  -- A CONTROL FAILED"))
sys.exit(0 if ok else 1)
