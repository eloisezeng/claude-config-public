import re, sys, os, glob
sha, D = sys.argv[1], sys.argv[2]
expected = set()
for f in sorted(glob.glob(os.path.join(D, "*.yml"))):
    yml = open(f).read()
    if "\njobs:\n" not in yml: continue
    body = yml.split("\njobs:\n", 1)[1]
    # a job block ends at the first line that is not indented (the next top-level key), if any
    body = re.split(r"\n(?=\S)", body)[0]
    for m in re.finditer(r"^  ([A-Za-z0-9_-]+):\n((?:    .*\n|\n)*)", body, re.M):
        nm = re.search(r"^    name:\s*(.+?)\s*$", m.group(2), re.M)
        expected.add(nm.group(1) if nm else m.group(1))
# One NAME can have SEVERAL check-runs on one sha (a workflow_dispatch alongside the pull_request run;
# a rerun that adds a run rather than replacing it). Keying by name would silently keep only one of
# them, and which one is unspecified -- so every row is kept and EVERY row must be green. That fails
# CLOSED: a stale red duplicate blocks, where last-wins could have merged over it.
rows = []
for line in open(os.path.join(D, "runs.tsv")):
    p = line.rstrip("\n").split("\t")
    if len(p) >= 2:
        rows.append((p[0], p[1], p[2] if len(p) > 2 else "", p[3] if len(p) > 3 else ""))
names = {r[0] for r in rows}
print(f"sha={sha[:7]} expected_jobs={sorted(expected)}")
for n, st, cc, rid in sorted(rows):
    print(f"  {st:12} {cc or '-':10} {n}" + (f"  (check-run {rid})" if rid else ""))
if len(rows) != len(names):
    dups = sorted({n for n in names if sum(1 for r in rows if r[0] == n) > 1})
    print(f"  NOTE: {len(rows)} check-runs for {len(names)} names; duplicated: {dups} -- all must be green")
why = []
if not expected: why.append("derived an EMPTY required-job set (parser failure, not a pass)")
missing = expected - names
if missing: why.append(f"workflow jobs never registered: {sorted(missing)}")
if not rows: why.append("no check-runs at all")
for n, st, cc, rid in rows:
    if st != "completed": why.append(f"still running: {n} ({st})")
    elif cc not in ("success", "neutral", "skipped"): why.append(f"not successful: {n} ({cc})")
if why: print("VERDICT: NOT-GREEN --", "; ".join(why)); sys.exit(1)
print(f"VERDICT: GREEN -- {len(rows)} checks, all completed successfully"); sys.exit(0)
