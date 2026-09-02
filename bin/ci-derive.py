import re, sys, os, glob, itertools
sha, D = sys.argv[1], sys.argv[2]

# A matrix job's `name:` is a TEMPLATE, and GitHub registers one check per expanded leg. Taking the
# template literally makes the required set UNSATISFIABLE: measured 2026-09-01 on this repo, the
# expected set carried `e2e (chromium layout) ${{ matrix.shard }}/${{ matrix.shardTotal }}`, a name
# no check-run can ever have, so the predicate reported NOT-GREEN forever and could not pass at all.
# Expanding against the inline matrix is also STRICTER than dropping the entry: it requires all 19
# shard check-runs by name, where the un-expandable template required nothing that exists.
def matrix_values(body):
    m = re.search(r"^      matrix:\n((?:        .*\n|\n)*)", body, re.M)
    if not m: return {}
    out = {}
    for k, v in re.findall(r"^        ([A-Za-z0-9_-]+):\s*\[(.*?)\]\s*$", m.group(1), re.M):
        vals = [x.strip().strip('"\'') for x in v.split(",") if x.strip()]
        if vals: out[k] = vals
    return out

def expand(name, mtx):
    """-> list of concrete names, or None if the template cannot be resolved (caller fails closed)."""
    keys = sorted(set(re.findall(r"\$\{\{\s*matrix\.([A-Za-z0-9_-]+)\s*\}\}", name)))
    if not keys: return [name]
    if any(k not in mtx for k in keys): return None
    names = [name]
    for k in keys:
        pat = re.compile(r"\$\{\{\s*matrix\." + re.escape(k) + r"\s*\}\}")
        names = [pat.sub(v, n) for n in names for v in mtx[k]]
    return names

expected, unresolved = set(), set()
for f in sorted(glob.glob(os.path.join(D, "*.yml"))):
    yml = open(f).read()
    if "\njobs:\n" not in yml: continue
    body = yml.split("\njobs:\n", 1)[1]
    # a job block ends at the first line that is not indented (the next top-level key), if any
    body = re.split(r"\n(?=\S)", body)[0]
    for m in re.finditer(r"^  ([A-Za-z0-9_-]+):\n((?:    .*\n|\n)*)", body, re.M):
        nm = re.search(r"^    name:\s*(.+?)\s*$", m.group(2), re.M)
        raw = nm.group(1) if nm else m.group(1)
        exp = expand(raw, matrix_values(m.group(2)))
        # An unresolvable template must NOT become a literal expectation (that is the unsatisfiable
        # guard above) and must NOT be silently dropped (that is a fail-OPEN hole in the required
        # set). Record it and refuse below.
        if exp is None or any("${{" in e for e in exp): unresolved.add(raw)
        else: expected.update(exp)
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
if unresolved: why.append(f"could not resolve templated job name(s) {sorted(unresolved)} -- the required set is INCOMPLETE, which is a parser failure, not a pass")
missing = expected - names
if missing: why.append(f"workflow jobs never registered: {sorted(missing)}")
if not rows: why.append("no check-runs at all")
for n, st, cc, rid in rows:
    if st != "completed": why.append(f"still running: {n} ({st})")
    elif cc not in ("success", "neutral", "skipped"): why.append(f"not successful: {n} ({cc})")
if why: print("VERDICT: NOT-GREEN --", "; ".join(why)); sys.exit(1)
print(f"VERDICT: GREEN -- {len(rows)} checks, all completed successfully"); sys.exit(0)
