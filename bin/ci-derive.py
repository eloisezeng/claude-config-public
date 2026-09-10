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

# Which workflows can even register a check on this sha? A scheduled or dispatch-only workflow
# never does, so requiring its jobs would report NOT-GREEN forever; and a `push: branches: [main]`
# workflow does not run on a PR branch. So: prefer the pull_request-triggered files, and fall back
# to the push-triggered ones when nothing declares pull_request (a sha already on the base branch).
# Excluding a file that COULD have registered would be fail-open, but a job that did register still
# has to be green below -- the expected set only adds the "never registered at all" check on top.
def triggers(yml):
    keys = set()
    m = re.search(r"^on:\s*(\[.*\]|[A-Za-z_].*)$", yml, re.M)
    if m: keys |= set(re.findall(r"[A-Za-z_]+", m.group(1)))
    m = re.search(r"^on:\s*\n((?:[ \t]+.*\n|\n)*)", yml, re.M)
    if m: keys |= set(re.findall(r"^  ([A-Za-z_]+):", m.group(1), re.M))
    return keys

# A file-level `paths:` filter asks the SAME question as `on:` one level down, and a wrong answer
# costs the same as the two above: a workflow the filter excludes does not run AT ALL, registers no
# check-run for ANY of its jobs, and so leaves every name it declares permanently missing from the
# required set's point of view. Measured 2026-09-08 on your-org/your-other-project: `your-module.yml`
# had just moved behind `paths: ['your-module/provider-data/**', 'package.json', 'package-lock.json',
# '.github/workflows/your-module.yml']`, and this predicate went on demanding its two jobs on every pull
# request -- so a pull request touching none of those paths read NOT-GREEN forever, with no commit
# able to fix it. (The pull request that SHIPPED that filter passed only because it edited
# `.github/workflows/your-module.yml`, which the filter names.)
#
# The patterns are matched against `changed.txt`, written by the caller: the pull request's changed
# files (merge-base..head), or the commit's own diff when the sha is already on the base branch.
# Fail-closed in both directions, exactly as the job-level `if:` rule below:
#   - no `paths:`/`paths-ignore:` on the event -> the workflow runs, nothing changes;
#   - a readable filter is evaluated against the changed set;
#   - an unreadable filter, an unsupported pattern, or a MISSING changed set is REFUSED BY NAME,
#     because guessing "it runs" rebuilds the permanent NOT-GREEN and guessing "it is skipped" is a
#     fail-OPEN hole in the required set.
# Bound, stated: this reads `paths` and `paths-ignore` only. `branches:`/`tags:` are NOT read, which
# is unchanged from before and is the same fail-open the `on:`-selection comment already accepts.
def _indent(l): return len(l) - len(l.lstrip(" "))

def _child_lines(lines, i):
    """Lines strictly more indented than lines[i], stopping at the first line that dedents to it."""
    base, out = _indent(lines[i]), []
    for l in lines[i + 1:]:
        if not l.strip() or l.lstrip().startswith("#"): continue
        if _indent(l) <= base: break
        out.append(l)
    return out

def _get(lines, key):
    """-> (inline value, child lines) for `key` at this block's OWN indent level, else None.
    Anchoring on the block's minimum indent is what keeps a nested `paths:` from being read as the
    event's, the same way `job_if` anchors on exactly four spaces rather than searching."""
    live = [(i, l) for i, l in enumerate(lines) if l.strip() and not l.lstrip().startswith("#")]
    if not live: return None
    lvl = min(_indent(l) for _, l in live)
    for i, l in live:
        if _indent(l) != lvl: continue
        m = re.match(r"""^\s*['"]?([A-Za-z0-9_.-]+)['"]?\s*:\s*(.*)$""", l)
        if m and m.group(1) == key:
            return m.group(2).strip(), _child_lines(lines, i)
    return None

UNREADABLE = "UNREADABLE"

def path_filter(yml, event):
    """-> ('paths'|'paths-ignore', [pattern, ...]) | None (no filter) | UNREADABLE."""
    on = _get(yml.split("\n"), "on")
    if on is None: return None
    inline, kids = on
    # `on: [push, pull_request]` / `on: push` -- a list or scalar form carries no filters at all.
    if inline: return None
    ev = _get(kids, event)
    if ev is None: return None
    ev_inline, ev_kids = ev
    if ev_inline: return UNREADABLE          # a flow mapping, e.g. `pull_request: {paths: [x]}`
    got = [(k, g) for k in ("paths", "paths-ignore") for g in [_get(ev_kids, k)] if g is not None]
    if not got: return None
    if len(got) > 1: return UNREADABLE       # GitHub forbids both on one event; do not adjudicate it
    kind, (v_inline, v_kids) = got[0]
    pats = []
    if v_inline:
        if not (v_inline.startswith("[") and v_inline.endswith("]")): return UNREADABLE
        pats = [x.strip().strip("\"'") for x in v_inline[1:-1].split(",") if x.strip()]
    else:
        for l in v_kids:
            m = re.match(r"^\s*-\s*(.+?)\s*$", l)
            if not m: return UNREADABLE
            pats.append(m.group(1).strip().strip("\"'"))
    return (kind, pats) if pats else UNREADABLE

# GitHub's filter patterns are a glob dialect: `*` stops at `/`, `**` crosses it, `?` is one
# non-`/` character. `!` negation, `+`, character classes and brace expansion are NOT translated
# here -- a pattern using them is refused by name rather than approximated, since an approximate
# filter is a required set that is wrong by an unknown amount in an unknown direction.
GLOB_SAFE = re.compile(r"^[A-Za-z0-9_./*?-]+$")

def glob_re(pat):
    if not GLOB_SAFE.match(pat or ""): return None
    out, i = [], 0
    while i < len(pat):
        if pat[i] == "*":
            if pat[i + 1:i + 2] == "*": out.append(".*"); i += 2
            else: out.append("[^/]*"); i += 1
        elif pat[i] == "?": out.append("[^/]"); i += 1
        else: out.append(re.escape(pat[i])); i += 1
    return re.compile("^" + "".join(out) + "$")

def file_runs(yml, event, changed):
    """True/False when the file-level path filter is decidable; None when it cannot be read.
    `changed` is None when the caller could not determine the changed-file set at all."""
    pf = path_filter(yml, event)
    if pf is None: return True
    if pf is UNREADABLE or changed is None: return None
    kind, pats = pf
    res = [glob_re(p) for p in pats]
    if any(r is None for r in res): return None
    hit = lambda f: any(r.match(f) for r in res)
    # An EMPTY changed set means no path can match, so a `paths:`-filtered workflow does not run --
    # which is what GitHub does, not a parser failure.
    if kind == "paths": return any(hit(f) for f in changed)
    return any(not hit(f) for f in changed)

# The caller writes each workflow TWICE -- once from the head sha and once from the base ref, named
# `head.<file>` and `base.<file>` -- because a pull_request run executes the MERGE ref, so a file
# only the base defines still runs. Reading BOTH copies of the SAME file is a different thing, and
# it is wrong in the one direction that cannot be recovered from: the merge ref carries the head's
# EDIT of that file, so a pull request that DELETES a job leaves the base's copy still naming it and
# the expected set demands a check-run that by construction can never appear. Measured 2026-09-08 on
# this repo: a PR moving the your-module job out of ci.yml and the repo-layout job into a git hook read
# NOT-GREEN on `repo layout` with nothing wrong and no commit able to fix it -- an unsatisfiable
# gate, the same permanent red the matrix-template comment above exists to prevent.
# So: for a file present on BOTH sides the head's copy wins, and the base's copy is read only for a
# file the head does not have at all. The residual hole is a job the BASE added while the pull
# request was open; that job still registers a check-run and still has to be green below, exactly as
# the `on:`-selection comment above already accepts.
def side_and_name(path):
    b = os.path.basename(path)
    tag, _, rest = b.partition(".")
    return (tag, rest) if tag in ("head", "base") else ("head", b)

files = {f: open(f).read() for f in sorted(glob.glob(os.path.join(D, "*.yml")))}
by_name = {}
for f in files:
    side, name = side_and_name(f)
    if name not in by_name or side == "head": by_name[name] = f
files = {f: y for f, y in files.items() if f in set(by_name.values())}

event = "pull_request"
selected = [f for f, y in files.items() if "pull_request" in triggers(y)]
if not selected:
    event = "push"
    selected = [f for f, y in files.items() if "push" in triggers(y)]

# The changed-file set the caller measured, one path per line. ABSENT is not EMPTY: an absent file
# means "not determined" and refuses every path-filtered workflow by name below, where an empty one
# is a real answer (nothing changed, so nothing a `paths:` filter names can match).
cpath = os.path.join(D, "changed.txt")
changed = None
if os.path.exists(cpath):
    changed = [l.strip() for l in open(cpath) if l.strip()]

path_skipped, unreadable_paths, admitted = set(), set(), []
for f in selected:
    r = file_runs(files[f], event, changed)
    if r is None:
        why_ = "no changed-file set" if changed is None else "unreadable filter"
        unreadable_paths.add(f"{os.path.basename(f)} ({why_})")
    elif r: admitted.append(f)
    else: path_skipped.add(os.path.basename(f))
selected = admitted

# A job-level `if:` asks the SAME question as the file-level `on:` block, one level down, and a
# wrong answer has the same consequence: a job the event cannot satisfy never registers its name, so
# requiring it reports NOT-GREEN forever. Measured 2026-09-08 on this repo: the 19-leg chromium
# sweep moved behind `if: github.event_name == 'schedule' || github.event_name == 'workflow_dispatch'`
# and the expected set went on demanding `e2e (chromium layout) 1/19` ... `19/19` on every pull
# request, which no pull request could ever satisfy.
#
# This reads EVENT conditions only, and it is fail-closed in both directions:
#   - an `if:` naming no event/ref context at all (`always()`, `success()`,
#     `needs.x.result == 'failure'`) does not gate on the event, so the job stays REQUIRED;
#   - a plain disjunction of `github.event_name == '<literal>'` terms is evaluated against the event,
#     and so is a plain conjunction of `github.event_name != '<literal>'` terms -- those two are the
#     only shapes GitHub workflows here actually write, and they are the two that are decidable from
#     the event name alone;
#   - a STATUS FUNCTION conjoined onto either of those (`always() && github.event_name != 'push'`)
#     reduces to the event half. This is not a convenience: a fail-closed gate job MUST carry
#     `always()`, because GitHub inserts an implicit `success()` only into a condition naming no
#     status function, so a gate that has to run when a needed job FAILED cannot drop it -- and any
#     event restriction therefore has to be conjoined onto it. Refusing the shape made the ONLY
#     correct way to write "a fail-closed gate that is off on push" unreadable, which is the
#     permanent NOT-GREEN this file exists to prevent, arriving by a third route (measured
#     2026-09-09 on your-org/your-other-project #434);
#   - anything else mentioning that context is REFUSED BY NAME below rather than guessed at, since
#     guessing "it runs" reproduces the permanent NOT-GREEN this exists to fix, and guessing "it is
#     skipped" is a fail-OPEN hole in the required set.
CONTEXT_TOKENS = ("github.event_name", "github.event", "github.ref", "github.head_ref", "github.base_ref")
EVENT_TERM = re.compile(r"^github\.event_name\s*(==|!=)\s*'([A-Za-z_]+)'$")
STATUS_FNS = ("always()", "success()", "!cancelled()", "!failure()")

def job_if(body):
    """The JOB's own `if:` value, block scalars folded, or None. A step's `if:` is indented deeper
    than four spaces and so is not a job condition -- the anchor is exact, not a search."""
    lines = body.split("\n")
    for i, line in enumerate(lines):
        m = re.match(r"^    if:\s*(.*)$", line)
        if not m: continue
        val = m.group(1).strip()
        if val in (">", ">-", ">+", "|", "|-", "|+"):
            cont = []
            for nxt in lines[i + 1:]:
                if not nxt.strip(): continue
                if not re.match(r"^     +\S", nxt): break
                cont.append(nxt.strip())
            return " ".join(cont)
        return val
    return None

def admits(if_expr, event):
    """True/False when the condition is decidable for `event`; None when it cannot be read.

    Exactly two shapes are decidable, and they are the two that appear in these workflows:
    a pure DISJUNCTION of `github.event_name == '<lit>'` (the event must be one of them), and a pure
    conjunction of `github.event_name != '<lit>'` (the event must be none of them). A status
    function CONJOINED onto either (`always() && github.event_name != 'push'`) reduces to the event
    half -- see the module comment; a status function is about job outcomes, never about the event. The operator and
    the joiner have to agree -- `a == x && b == y` is unsatisfiable and `a != x || b != y` is a
    tautology, so both are almost certainly a typo rather than an intent worth evaluating, and both
    are refused. Anything else naming a context token is refused too: guessing "it runs" rebuilds the
    permanent NOT-GREEN this exists to fix, and guessing "it is skipped" is a fail-OPEN hole in the
    required set.
    """
    if if_expr is None: return True
    e = if_expr.strip()
    m = re.match(r"^\$\{\{(.*)\}\}$", e, re.S)
    if m: e = m.group(1).strip()
    if not any(t in e for t in CONTEXT_TOKENS): return True
    if "||" in e and "&&" in e: return None   # mixed joiners: precedence is not ours to adjudicate
    # A status function does not gate on the EVENT -- this parser already answers True for a BARE
    # `always()`/`success()` at the CONTEXT_TOKENS line above -- so drop such terms from a
    # CONJUNCTION and decide on what is left. Only from a conjunction: `always() || <anything>` is a
    # tautology and stays refused, for the same reason `a != x || b != y` is. The match is on the
    # exact token, so `needs.x.result == 'failure' && github.event_name != 'push'` is still refused
    # by name rather than guessed at.
    if "&&" in e:
        kept = [t for t in e.split("&&") if t.strip() not in STATUS_FNS]
        if not kept: return True              # nothing but status functions: no event gating at all
        e = " && ".join(t.strip() for t in kept)
    ops, events = set(), set()
    terms = re.split(r"\|\||&&", e)
    for term in terms:
        t = term.strip()
        while t.startswith("(") and t.endswith(")"): t = t[1:-1].strip()
        m = EVENT_TERM.match(t)
        if not m: return None
        ops.add(m.group(1))
        events.add(m.group(2))
    if len(ops) != 1: return None             # a mixed `==`/`!=` is not one of the two shapes
    op = ops.pop()
    joiner = "&&" if "&&" in e else ("||" if len(terms) > 1 else None)
    if op == "==" and joiner != "&&": return event in events
    if op == "!=" and joiner != "||": return event not in events
    return None

expected, unresolved, unreadable_if, off_event = set(), set(), set(), set()
for f in selected:
    yml = files[f]
    if "\njobs:\n" not in yml: continue
    body = yml.split("\njobs:\n", 1)[1]
    # a job block ends at the first line that is not indented (the next top-level key), if any
    body = re.split(r"\n(?=\S)", body)[0]
    for m in re.finditer(r"^  ([A-Za-z0-9_-]+):\n((?:    .*\n|\n)*)", body, re.M):
        nm = re.search(r"^    name:\s*(.+?)\s*$", m.group(2), re.M)
        raw = nm.group(1) if nm else m.group(1)
        cond = job_if(m.group(2))
        runs = admits(cond, event)
        if runs is None:
            unreadable_if.add(f"{m.group(1)}: if: {cond}")
            continue
        if not runs:
            off_event.add(f"{m.group(1)} (if: {cond})")
            continue
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
print(f"sha={sha[:7]} event={event} workflows={sorted(os.path.basename(f) for f in selected)}")
print(f"  expected_jobs={sorted(expected)}")
# Print what was REMOVED from the required set, never only what survived: a set that silently shrank
# has no diff line to point at, and every entry here is a job this predicate has stopped requiring.
if off_event: print(f"  not required on `{event}`: {sorted(off_event)}")
if path_skipped: print(f"  workflow file(s) excluded by their own `paths:` filter: {sorted(path_skipped)}")
for n, st, cc, rid in sorted(rows):
    print(f"  {st:12} {cc or '-':10} {n}" + (f"  (check-run {rid})" if rid else ""))
if len(rows) != len(names):
    dups = sorted({n for n in names if sum(1 for r in rows if r[0] == n) > 1})
    print(f"  NOTE: {len(rows)} check-runs for {len(names)} names; duplicated: {dups} -- all must be green")
why = []
# An empty required set is refused whichever way it was reached -- including "every workflow was
# excluded by its own path filter", which is a real answer but one no repo here can produce (ci.yml
# carries a bare `pull_request:`), and reporting GREEN off zero required jobs is not a risk worth
# taking to serve a repo that path-filters ALL of its workflows.
if not expected: why.append("derived an EMPTY required-job set (parser failure, not a pass)")
if unresolved: why.append(f"could not resolve templated job name(s) {sorted(unresolved)} -- the required set is INCOMPLETE, which is a parser failure, not a pass")
if unreadable_paths: why.append(f"could not read the file-level path filter of {sorted(unreadable_paths)} -- cannot tell whether `{event}` runs that workflow at all, which is a parser failure, not a pass")
if unreadable_if: why.append(f"could not read job condition(s) {sorted(unreadable_if)} -- cannot tell whether `{event}` runs them, which is a parser failure, not a pass")
missing = expected - names
if missing: why.append(f"workflow jobs never registered: {sorted(missing)}")
if not rows: why.append("no check-runs at all")
for n, st, cc, rid in rows:
    # A check-run that carries a CONCLUSION is FINISHED, whatever its `status` field says. Measured
    # 2026-09-02 on your-org/your-other-project sha 0f566b00: GitHub served the job
    # `deploy freeze check` as status="in_progress" WITH conclusion="success", while the run itself
    # was completed/success and every other job read completed/success. Requiring status=="completed"
    # therefore reported NOT-GREEN forever and a watcher timed out ~40 min after CI had gone green.
    # This is not fail-open: `conclusion` is written only at finalization, so an unfinished check has
    # an empty one and still lands in the "still running" branch below; and a check that says
    # completed with NO conclusion falls through to the not-successful branch rather than passing.
    if st == "completed" or cc:
        if cc not in ("success", "neutral", "skipped"): why.append(f"not successful: {n} ({cc})")
    else:
        why.append(f"still running: {n} ({st})")
if why: print("VERDICT: NOT-GREEN --", "; ".join(why)); sys.exit(1)
print(f"VERDICT: GREEN -- {len(rows)} checks, all completed successfully"); sys.exit(0)
