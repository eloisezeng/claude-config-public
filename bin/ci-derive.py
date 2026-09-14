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

def wf_label(path):
    """The workflow's own file name, for printing. ci-green.sh stores each workflow as
    `<side>.<file name>.yml` -- the trailing `.yml` is there so a `.yaml` workflow is still caught by
    the `*.yml` glob above -- so printing the stored basename showed `head.check.yml.yml` for
    `.github/workflows/check.yml` (measured 2026-09-10 on your-org/your-web-app-2026 PR #21). It was a
    DISPLAY defect only: `by_name` keys both sides identically, so head-wins was never affected. A
    basename outside that naming contract (a hand-built fixture's `head.yml`) is printed unchanged."""
    side, name = side_and_name(path)
    if not (name.endswith(".yml.yml") or name.endswith(".yaml.yml")): return os.path.basename(path)
    return name[:-len(".yml")] + (" (base only)" if side == "base" else "")

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
        unreadable_paths.add(f"{wf_label(f)} ({why_})")
    elif r: admitted.append(f)
    else: path_skipped.add(wf_label(f))
selected = admitted

# A job-level `if:` asks the SAME question as the file-level `on:` block, one level down, and a
# wrong answer has the same consequence: a job the event cannot satisfy never registers its name, so
# requiring it reports NOT-GREEN forever. Measured 2026-09-08 on this repo: the 19-leg chromium
# sweep moved behind `if: github.event_name == 'schedule' || github.event_name == 'workflow_dispatch'`
# and the expected set went on demanding `e2e (chromium layout) 1/19` ... `19/19` on every pull
# request, which no pull request could ever satisfy.
#
# This reads EVENT and BRANCH conditions, and it is fail-closed in both directions:
#   - an `if:` naming no event/ref context at all (`always()`, `success()`,
#     `needs.x.result == 'failure'`) does not gate on the event, so the job stays REQUIRED;
#   - `==`/`!=` comparisons of `github.event_name`, `github.base_ref`, `github.ref` or
#     `github.head_ref` against a single-quoted literal, joined by `&&`/`||` and grouped by
#     parentheses, are EVALUATED as GitHub evaluates them -- strings compared ignoring case, which is
#     what GitHub's expression syntax specifies. A two-shape reader (a disjunction of `==` event terms,
#     a conjunction of `!=` ones) was not enough: measured 2026-09-10 on your-org/your-web-app-2026 PR
#     #21, check.yml's `current` job carries `if: github.event_name == 'pull_request' &&
#     github.base_ref == 'main'`, and this predicate answered "could not read job condition(s)" on
#     every pull request in that repository, although the base branch is exactly what ci-green.sh's
#     [base-ref] argument supplies;
#   - a STATUS FUNCTION conjoined onto any of that (`always() && github.event_name != 'push'`)
#     reduces to the rest. This is not a convenience: a fail-closed gate job MUST carry
#     `always()`, because GitHub inserts an implicit `success()` only into a condition naming no
#     status function, so a gate that has to run when a needed job FAILED cannot drop it -- and any
#     event restriction therefore has to be conjoined onto it. Refusing the shape made the ONLY
#     correct way to write "a fail-closed gate that is off on push" unreadable, which is the
#     permanent NOT-GREEN this file exists to prevent, arriving by a third route (measured
#     2026-09-09 on your-org/your-other-project #434);
#   - everything else is REFUSED BY NAME rather than guessed at: a context this does not evaluate
#     (`github.ref_name`, `needs.*`), a function call, `&&` and `||` mixed at one level without
#     parentheses, a status function inside `||`, and a KNOWN context whose value this run was not
#     given -- `github.base_ref` with no [base-ref] argument, the pull request number inside
#     `github.ref`, the head branch in `github.head_ref`. Guessing "it runs" reproduces the permanent
#     NOT-GREEN this exists to fix, and guessing "it is skipped" is a fail-OPEN hole in the required
#     set. A value that is not known can still be irrelevant: `false && <unknown>` is false whatever
#     the unknown holds, so the evaluator is three-valued and refuses only when the answer depends on it.
CONTEXT_TOKENS = ("github.event_name", "github.event", "github.ref", "github.head_ref", "github.base_ref")
STATUS_FNS = ("always()", "success()", "!cancelled()", "!failure()")
TOKEN = re.compile(
    r"(?P<lp>\()|(?P<rp>\))|(?P<and>&&)|(?P<or>\|\|)|(?P<op>==|!=)"
    r"|(?P<status>" + "|".join(re.escape(s) for s in STATUS_FNS) + r")"
    r"|(?P<lit>'(?:[^']|'')*')|(?P<ident>[A-Za-z_][A-Za-z0-9_.-]*)")

class Undecided:
    """Why a job condition could not be decided -- and deliberately NOT a truth value. `admits` answers
    True, False or one of these, and a caller that wrote `if runs:` would read a refusal as a verdict in
    one direction or the other, so testing one for truth raises instead of quietly picking a side."""
    __slots__ = ("why",)
    def __init__(self, why): self.why = why
    def __bool__(self): raise TypeError(f"an undecided job condition is not a verdict: {self.why}")

class Partial:
    """A context value known only up to a pattern. A literal the pattern cannot produce is decidably
    unequal to it; a literal it CAN produce is Undecided, for `why`."""
    __slots__ = ("pattern", "why")
    def __init__(self, pattern, why): self.pattern, self.why = re.compile(pattern, re.I), why

class _Unreadable(Exception): pass

def base_branch(arg, full_name, remotes):
    """What `github.base_ref` holds on a pull_request against the [base-ref] argument: the branch
    name, or an Undecided saying why it is not known. `arg` is None when no argument was given;
    `full_name` is git's `--symbolic-full-name` for it, EMPTY when it names no ref. Only a branch is
    accepted -- measured: that git call prints NOTHING for a sha, and echoes an unknown name back
    while failing, so reading the raw argument as a branch would let `ci-green.sh <sha> 6e9b5c5`
    answer `github.base_ref == 'main'` with a confident False."""
    if arg is None:
        return Undecided("the condition reads `github.base_ref`, and no [base-ref] argument was given "
                         "(ci-green.sh <sha> <base-ref>) -- the origin/main default serves the diff, "
                         "never a condition")
    if full_name.startswith("refs/heads/"): return full_name[len("refs/heads/"):]
    if full_name.startswith("refs/remotes/"):
        rest = full_name[len("refs/remotes/"):]
        for r in sorted(remotes, key=len, reverse=True):
            if rest.startswith(r + "/"): return rest[len(r) + 1:]
    return Undecided(f"the [base-ref] argument {arg!r} is not a branch here, so `github.base_ref` is not known")

def operand(name, event, base):
    """The value of context `name` on `event` -- a str, a Partial or an Undecided -- or None for a
    context this does not evaluate. GitHub fills `base_ref` and `head_ref` on pull_request events only
    and leaves both EMPTY on a push, so those two are known outright there."""
    pr = event == "pull_request"
    if name == "github.event_name": return event
    if name == "github.base_ref": return base if pr else ""
    if name == "github.head_ref":
        return Undecided("`github.head_ref` is the pull request's head branch, which this tool is not given") if pr else ""
    if name == "github.ref":
        if pr: return Partial(r"refs/pull/[0-9]+/merge", "`github.ref` on a pull_request is refs/pull/<number>/merge, and the number is not given")
        return Partial(r"refs/(heads|tags)/.+", "`github.ref` on a push is the pushed branch or tag, which this tool is not given")
    return None

def _parse(e):
    """-> ("cmp", context, op, literal) | ("status", fn) | ("and"|"or", [node, ...]); raises _Unreadable.
    There is deliberately NO precedence: one level joins its terms with one kind of joiner."""
    toks, i = [], 0
    while i < len(e):
        if e[i].isspace():
            i += 1
            continue
        m = TOKEN.match(e, i)
        if not m: raise _Unreadable(f"cannot read {e[i:]!r}")
        toks.append((m.lastgroup, m.group()))
        i = m.end()
    pos = 0
    def take(*kinds):
        nonlocal pos
        if pos < len(toks) and toks[pos][0] in kinds:
            pos += 1
            return toks[pos - 1]
        return None
    def group():
        terms, joiner = [term()], None
        while True:
            j = take("and", "or")
            if j is None: break
            if joiner not in (None, j[0]):
                raise _Unreadable("`&&` and `||` mixed without parentheses -- the answer would rest on precedence")
            joiner = j[0]
            terms.append(term())
        return terms[0] if joiner is None else (joiner, terms)
    def term():
        if take("lp"):
            node = group()
            if not take("rp"): raise _Unreadable("unbalanced parentheses")
            return node
        st = take("status")
        if st: return ("status", st[1])
        a, op, b = take("ident", "lit"), take("op"), take("ident", "lit")
        if not (a and op and b) or {a[0], b[0]} != {"ident", "lit"}:
            raise _Unreadable("expected <context> ==|!= '<literal>'")
        ctx, lit = (a[1], b[1]) if a[0] == "ident" else (b[1], a[1])
        return ("cmp", ctx, op[1], lit[1:-1].replace("''", "'"))
    node = group()
    if pos != len(toks): raise _Unreadable(f"unexpected {toks[pos][1]!r}")
    return node

def _contexts(node):
    if node[0] == "cmp": return {node[1]}
    if node[0] == "status": return set()
    return set().union(*(_contexts(k) for k in node[1]))

def _undecided(vals):
    return Undecided("; ".join(dict.fromkeys(v.why for v in vals if isinstance(v, Undecided))))

def _and(vals):
    if any(v is False for v in vals): return False
    return _undecided(vals) if any(isinstance(v, Undecided) for v in vals) else True

def _or(vals):
    if any(v is True for v in vals): return True
    return _undecided(vals) if any(isinstance(v, Undecided) for v in vals) else False

def _evaluate(node, event, base):
    kind = node[0]
    if kind == "status": return True
    if kind == "cmp":
        _, name, op, lit = node
        val = operand(name, event, base)
        if isinstance(val, Undecided): return val
        if isinstance(val, Partial):
            if val.pattern.fullmatch(lit): return Undecided(val.why)
            equal = False
        else:
            equal = val.lower() == lit.lower()
        return equal if op == "==" else not equal
    kids = node[1]
    # A status function is about job OUTCOMES, never about which event fired, so it drops out of a
    # conjunction. Inside `||` it is refused: `always() || <x>` would put the job in the required set
    # on EVERY event, the fail-closed-forever bug wearing the opposite sign.
    if kind == "and":
        return _and([_evaluate(k, event, base) for k in kids if k[0] != "status"])
    if any(k[0] == "status" for k in kids):
        return Undecided("a status function joined by `||` is an outcome test, not an event test")
    return _or([_evaluate(k, event, base) for k in kids])

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

def admits(if_expr, event, base):
    """True when a job carrying `if_expr` registers a check-run on `event`, False when it cannot, and
    an Undecided naming the reason when this cannot tell -- see the module comment for what is read.
    `base` is what `github.base_ref` holds on a pull_request: a branch name, or an Undecided.

    A context this does not evaluate refuses the WHOLE condition by name, even where short-circuiting
    could have skipped it: an operand this tool does not know is a failure to read, never a silent
    true or false."""
    if if_expr is None: return True
    e = if_expr.strip()
    m = re.match(r"^\$\{\{(.*)\}\}$", e, re.S)
    if m: e = m.group(1).strip()
    if not any(t in e for t in CONTEXT_TOKENS): return True
    try:
        node = _parse(e)
    except _Unreadable as x:
        return Undecided(f"unreadable: {x}")
    unknown = sorted(c for c in _contexts(node) if operand(c, event, base) is None)
    if unknown:
        return Undecided(f"{', '.join('`' + c + '`' for c in unknown)} is not a context this tool evaluates")
    return _evaluate(node, event, base)

# What `github.base_ref` holds, from ci-green.sh's EXPLICIT [base-ref] argument: `base_ref.txt` is the
# argument on line 1 and git's full ref name for it on line 2 (empty when it names no ref), and
# `remotes.txt` lists the remotes so `origin/main` reads as the branch `main`. ABSENT means the
# argument was not given, which is never the same as `main` -- a condition that needs it is refused.
bpath = os.path.join(D, "base_ref.txt")
if os.path.exists(bpath):
    blines = open(bpath).read().split("\n")
    rpath = os.path.join(D, "remotes.txt")
    remotes = [l.strip() for l in open(rpath) if l.strip()] if os.path.exists(rpath) else []
    base = base_branch(blines[0], blines[1].strip() if len(blines) > 1 else "", remotes)
else:
    base = base_branch(None, "", [])

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
        runs = admits(cond, event, base)
        if isinstance(runs, Undecided):
            unreadable_if.add(f"{m.group(1)}: if: {cond} -- {runs.why}")
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
print(f"sha={sha[:7]} event={event} workflows={sorted(wf_label(f) for f in selected)}")
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
if unreadable_if: why.append(f"could not read job condition(s) {sorted(unreadable_if)} -- cannot tell whether `{event}` runs them, which is a failure to decide, not a pass")
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
