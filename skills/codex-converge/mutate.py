#!/usr/bin/env python3
"""mutate.py — arm source mutants on a COPY and classify each as SURVIVED or KILLED.

The mutation discipline of the codex-converge loop, as a reusable tool instead of a
per-arc script rewritten from scratch every round:

  Phase A  (before writing killers)  every accepted test finding's mutant must SURVIVE
           on the reviewed head — a mutant the suite already kills is not a finding.
  Phase C  (after the fix)           every re-armed mutant plus the fix's own mutants
           must be KILLED — except the ones the round labelled unobservable, which
           must still SURVIVE (a labelled-unobservable mutant that dies means the
           label was wrong).

Never arms a mutant in the tracked tree: the source and its test are copied into
`--copy-dir`, the mutant is applied to the COPY with a unique-site assertion, the
test copy's import is rewritten to point at the copy, and vitest runs on the copy
only.  Every tracked file named by `--src`, `--test` and `--tracked` is sha256'd
before and after, and a changed hash fails the run regardless of the mutants.

Usage (paths relative to --root, which defaults to the cwd):

  mutate.py --src plugins/x/foo.ts --test plugins/x/foo.test.ts \
            --copy-dir plugins/mutation-<arc>-tmp \
            --rewrite '@/plugins/x/foo=./foo' \
            --mutants mutants.json [--census 'REGEX=N']... [--keep-copy]

mutants.json is a list of objects:
  {"label": "G4 dash-family drop", "old": "exact source text", "new": "replacement",
   "expect": "killed" | "survived" | "unobservable",
   "test": "exact name of the test that must kill it"}

`test` is OPTIONAL but wanted on every `expect: killed` mutant: it becomes vitest's
`-t` filter, so the mutant runs the ONE test that is supposed to catch it instead of
the whole file (a 52-test file x 9 mutants = 468 test executions becomes 9).  It is
also a stronger assertion than the unfiltered run — it pins WHICH test does the
killing, so a mutant killed by some unrelated neighbour no longer reads as OK.
A run that executes NO test is reported MISARMED, never SURVIVED — whether or not it
was filtered: vitest exits 0 when its name filter matches nothing, and a whole-file
command whose test file has moved does the same, so an unguarded run would silently
convert every `killed` expectation into a passing `survived` one.
The suite must also be GREEN on the unmutated source before any mutant is armed; a
pre-existing red test reports every mutant as KILLED and would certify the run green
on no evidence at all.  That baseline is one unfiltered run per invocation.
`old` must occur EXACTLY ONCE in the source (a zero or multi-site match aborts that
mutant as MISARMED).  `old`/`new` may be parallel LISTS for a mutant made of several
edits (a move = delete here + insert there), applied in order, each asserted unique.
`unobservable` is an alias for `survived` with the intent recorded in the label.

--census 'REGEX=N' asserts that exactly N source lines match REGEX — the
completeness guard for an enumerated defect class (e.g. every /g-flagged literal),
so a site added since the enumeration fails the run instead of going unarmed.

Exit status: 0 every mutant matched its expectation and tracked files are unchanged;
2 at least one mutant did not; 3 a tracked file changed or a census failed;
4 usage error; 5 the baseline suite was not green (red, or it ran no tests) so the
run was refused before arming anything.  Use a copy dir UNIQUE to your session — two sessions sharing one
copy dir will read each other's mutants.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import shlex
import shutil
import signal
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from loop import Locks, arc_dir, record_job, tests_ran, now as _now  # noqa: E402


def sha256(path: str) -> str:
    with open(path, 'rb') as fh:
        return hashlib.sha256(fh.read()).hexdigest()


# tests_ran (the zero-match guard) is defined ONCE, in loop.py, and imported above.


def worktree_of(path: str) -> str | None:
    """Top-level dir of the git worktree containing `path` (which need not exist yet), else None."""
    probe = path
    while not os.path.isdir(probe):
        parent = os.path.dirname(probe)
        if parent == probe:
            return None
        probe = parent
    r = subprocess.run(['git', '-C', probe, 'rev-parse', '--show-toplevel'], capture_output=True, text=True)
    return (r.stdout.strip() or None) if r.returncode == 0 else None


def git_ignored(top: str, path: str) -> bool:
    """Whether the mutant copy dir `path` is git-ignored.

    Measured: a directory-only pattern (`copy/`, the form a human actually writes) reads NOT ignored
    when the directory does not exist yet — which is every FIRST run, so the guard below would refuse
    a correctly-configured repo and tell it to do what it had already done. Probing a path INSIDE the
    dir answers correctly for both `copy/` and `copy`, and still answers no when neither covers it.
    """
    probe = os.path.join(path, '.mutant-armed')
    r = subprocess.run(['git', '-C', top, 'check-ignore', '-q', '--', probe], capture_output=True)
    return r.returncode == 0


_MTIME_TICK = [time.time()]


def write_source(path: str, text: str) -> None:
    """Write a file into the mutated copy under an mtime nothing has ever compiled.

    A mutant can otherwise read as SURVIVED with the mutation correctly applied and the test
    correctly selected, because the interpreter never compiled the file it was handed. CPython
    validates cached bytecode against the source's SIZE and its mtime IN WHOLE SECONDS, so a
    same-size edit landing inside the same second (`a + b` -> `a - b`, or `== 0` -> `< 0`) leaves
    the PREVIOUS mutant's bytecode looking valid. Measured on this harness before the fix: five
    identical runs of one same-size mutant gave KILLED, SURVIVED, KILLED, SURVIVED, SURVIVED — a
    false negative for `expect: killed`, and a false GREEN for any `expect: survived` mutant.

    Deleting `__pycache__` is NOT the fix, and believing it was is how this nearly shipped: the
    macOS system Python sets `sys.pycache_prefix` to ~/Library/Caches/com.apple.python, so the
    cache for a source at /a/b/m.py lives OUTSIDE the tree entirely, keyed by that absolute path.
    A purge under the copy dir removes nothing there, and PYTHONDONTWRITEBYTECODE only stops a new
    entry being written — it does not stop a stale one being read. Forcing a strictly increasing,
    never-repeated mtime invalidates the cache wherever it lives, under any prefix scheme.
    """
    with open(path, 'w', encoding='utf-8') as fh:
        fh.write(text)
    _MTIME_TICK[0] += 2.0
    os.utime(path, (_MTIME_TICK[0], _MTIME_TICK[0]))


class _Interrupted(BaseException):
    """A terminating signal, raised out of the blocking wait so `finally` blocks get to run.

    BaseException, not Exception, so no `except Exception:` on the way out can swallow a shutdown.
    """

    def __init__(self, signum: int):
        super().__init__(signum)
        self.signum = signum


_CHILD: list = [None]   # the test process currently running, for signal forwarding


def _terminate_child(sig: int) -> None:
    """Signal the running test's whole process group; fall back to the shell alone."""
    proc = _CHILD[0]
    if proc is None or proc.poll() is not None:
        return
    try:
        os.killpg(proc.pid, sig)
    except (ProcessLookupError, PermissionError, AttributeError, OSError):
        try:
            proc.send_signal(sig)
        except (ProcessLookupError, OSError):
            pass


def _install_signal_handlers() -> None:
    def handler(signum, _frame):
        raise _Interrupted(signum)
    for sig in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
        signal.signal(sig, handler)


def run_test_cmd(cmd: str, root: str, copy_dir: str) -> subprocess.CompletedProcess:
    """Run one test command with bytecode writing off and any in-tree cache purged.

    Belt and braces around `write_source`, which is the guarantee: this keeps the copy dir clean
    for interpreters that DO cache in-tree, and stops the run leaving cache entries behind at all.

    The test runs in its OWN SESSION and is killed as a group on the way out. `subprocess.run` left
    a terminated mutation run's suite executing unsupervised — a full vitest worker pool competing
    for the machine with whatever ran next, while this process's ledger row said nothing had ever
    started. Killing the group (rather than the `sh -c`) is what actually reaches the workers.
    """
    for dirpath, dirnames, _files in os.walk(copy_dir):
        for d in list(dirnames):
            if d == '__pycache__':
                shutil.rmtree(os.path.join(dirpath, d), ignore_errors=True)
                dirnames.remove(d)
    env = dict(os.environ)
    env['PYTHONDONTWRITEBYTECODE'] = '1'
    proc = subprocess.Popen(cmd, shell=True, cwd=root, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                            text=True, env=env, start_new_session=True)
    _CHILD[0] = proc
    try:
        out, err = proc.communicate()
    except BaseException:
        _terminate_child(signal.SIGTERM)
        try:
            proc.communicate(timeout=5)
        except BaseException:
            _terminate_child(signal.SIGKILL)
            try:
                proc.communicate(timeout=5)
            except BaseException:
                pass
        raise
    finally:
        _CHILD[0] = None
    return subprocess.CompletedProcess(cmd, proc.returncode, out, err)

def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--root', default=os.getcwd(), help='repo root; vitest runs here (default: cwd)')
    ap.add_argument('--src', required=True, help='source file to mutate, relative to root')
    ap.add_argument('--test', required=True, help='its test file, relative to root')
    ap.add_argument('--copy-dir', required=True, help='directory (relative to root) that receives the copies; must be inside vitest include')
    ap.add_argument('--rewrite', action='append', default=[], metavar='FROM=TO', help='import specifier rewrite applied to the TEST copy (repeatable)')
    ap.add_argument('--src-rewrite', action='append', default=[], metavar='FROM=TO', help='import specifier rewrite applied to the SOURCE copy (repeatable)')
    ap.add_argument('--mutants', required=True, help='JSON file: [{label, old, new, expect}]')
    ap.add_argument('--tracked', action='append', default=[], help='extra tracked files whose sha256 must not change (repeatable)')
    ap.add_argument('--also-copy', action='append', default=[], metavar='FILE',
                    help='extra file to place UNMUTATED beside the copy each round, e.g. the module the '
                         'test imports (repeatable). Also hashed as tracked.')
    ap.add_argument('--census', action='append', default=[], metavar='REGEX=N', help='assert exactly N source lines match REGEX (repeatable)')
    ap.add_argument('--test-cmd', default='npx vitest run {test} {filter}', help="command template; {test} is the copied test path, {filter} the -t name filter from the mutant's `test` key (empty when it has none)")
    ap.add_argument('--keep-copy', action='store_true', help='leave the copy dir in place after the last mutant (default: removed)')
    ap.add_argument('--only', action='append', default=[],
                    help='run only mutants whose label contains this substring (repeatable)')
    ap.add_argument('--filter-flag', default='-t', help="the runner's name-filter flag that {filter} expands to (default -t; -k for python unittest)")
    ap.add_argument('--arc', help='ledger this run for loop.py profile (default $CC_ARC / $CLAUDE_JOB_DIR/tmp); needs --track and --round')
    ap.add_argument('--track', help='track label for the ledger')
    ap.add_argument('--round', type=int, help='round number for the ledger')
    ap.add_argument('--no-lock', action='store_true', help='do not take the shared light CPU lock (self-tests only)')
    args = ap.parse_args()

    root = os.path.abspath(args.root)
    src = os.path.join(root, args.src)
    test = os.path.join(root, args.test)
    # abspath NORMALISES: without it `--copy-dir .` is `<root>/.`, which commonpath calls equal to
    # root while `== root` calls different, so the guard passed and rmtree destroyed the root;
    # `../outside` slipped through the same way (commonpath treats `..` as a plain component).
    copy_dir = os.path.abspath(os.path.join(root, args.copy_dir))
    for p in (src, test):
        if not os.path.isfile(p):
            print(f'usage: not a file: {p}', file=sys.stderr)
            return 4
    if os.path.commonpath([copy_dir, root]) != root or copy_dir == root:
        print('usage: --copy-dir must be a subdirectory of --root', file=sys.stderr)
        return 4
    top = worktree_of(copy_dir)
    if top and not git_ignored(top, copy_dir):
        print(f'usage: --copy-dir {copy_dir} is inside the git worktree {top} and is NOT git-ignored — '
              f'a tree that auto-commits (or a `git add -A`) would commit the ARMED mutant; '
              f'add it to .gitignore or use a --root outside any worktree', file=sys.stderr)
        return 4

    # A --test-cmd that never names the COPY runs the ORIGINAL test against the ORIGINAL source, so
    # the mutant is armed in a file nothing executes and EVERY mutant reports SURVIVED — a total,
    # silent fail-open of the harness, indistinguishable from a genuinely weak suite. Measured while
    # writing this guard: `--test-cmd 'python3 loop_test.py {filter}'` (a literal path instead of
    # {test}) reported SURVIVED for a mutant that, hand-armed, fails the same test in 0.25s.
    # {test} is the copy; naming --copy-dir directly (e.g. `npx vitest run --dir <copy>`) is the other
    # legitimate way to reach it. Anything else cannot be reading the mutant.
    if '{test}' not in args.test_cmd and args.copy_dir not in args.test_cmd:
        print(f'usage: --test-cmd {args.test_cmd!r} names neither {{test}} nor the copy dir '
              f'{args.copy_dir!r}, so it would run the UNMUTATED original and report every mutant '
              f'SURVIVED; use the {{test}} placeholder', file=sys.stderr)
        return 4

    with open(args.mutants) as fh:
        mutants = json.load(fh)
    for m in mutants:
        missing = {'label', 'old', 'new', 'expect'} - set(m)
        if missing or m['expect'] not in ('killed', 'survived', 'unobservable'):
            print(f'usage: bad mutant entry {m!r} (missing {sorted(missing)} or bad expect)', file=sys.stderr)
            return 4
    all_mutants = list(mutants)
    if args.only:
        # Repeatable, and a selector matching nothing is a REFUSAL, not an empty green run — the
        # zero-match hazard this tool exists to police applies to its own selector too.
        mutants = [m for m in mutants if any(o in m['label'] for o in args.only)]
        unmatched = [o for o in args.only if not any(o in m['label'] for m in all_mutants)]
        if unmatched:
            print(f'--only matched no mutant: {unmatched}', file=sys.stderr)
            return 4
        if not mutants:
            print('--only selected zero mutants', file=sys.stderr)
            return 4

    companions = [os.path.join(root, c) for c in args.also_copy]
    for c in companions:
        if not os.path.isfile(c):
            print(f'usage: --also-copy not a file: {c}', file=sys.stderr)
            return 4

    tracked = [src, test] + companions + [os.path.join(root, t) for t in args.tracked]
    before = {p: sha256(p) for p in tracked}

    src_text = open(src, encoding='utf-8').read()
    test_text = open(test, encoding='utf-8').read()

    census_failed = False
    for spec in args.census:
        regex, _, n = spec.rpartition('=')
        hits = [ln for ln in src_text.splitlines() if re.search(regex, ln)]
        ok = len(hits) == int(n)
        print(f"census {'OK  ' if ok else 'FAIL'} {regex!r}: {len(hits)} lines (expected {n})")
        if not ok:
            for ln in hits:
                print('   ', ln.strip()[:120])
            census_failed = True
    if census_failed:
        print('census failed: enumerate the new sites and arm them before trusting this run')
        return 3

    def apply_rewrites(text: str, specs: list[str]) -> str:
        for spec in specs:
            frm, _, to = spec.partition('=')
            if frm not in text:
                raise SystemExit(f'usage: rewrite source {frm!r} not found')
            text = text.replace(frm, to)
        return text

    def place_companions() -> None:
        """Put the unmutated companions in the copy dir.

        A test file imports its subject by NAME from its own directory, so a copy dir holding only
        the test cannot import anything. These are copied verbatim and never mutated.
        """
        for c in companions:
            shutil.copyfile(c, os.path.join(copy_dir, os.path.basename(c)))

    test_copy_text = apply_rewrites(test_text, args.rewrite)
    src_base = os.path.basename(src)
    test_base = os.path.basename(test)

    # The copy dir holds the source under its basename and the test under ITS basename, and the test
    # is written SECOND. If those two basenames collide, the test write lands on top of the armed
    # source and every mutant runs against unmutated code -- SURVIVED across the board, exit 0, with
    # nothing in the output to say so. That is the same silent fail-open the --test-cmd guard above
    # exists to police, so it is handled here in both of its shapes:
    #
    #  * SAME FILE (--src loop_test.py --test loop_test.py): legitimate and now supported. Harness
    #    helpers live in the test file, and a mutant is the only way to show a test of one can fail.
    #    One file is written once, carrying both rewrite sets.
    #  * DIFFERENT FILES, SAME BASENAME (--src a/x.py --test b/x.py): unsupported and REFUSED. There
    #    is one path for two contents and no ordering makes both readable.
    same_file = os.path.realpath(src) == os.path.realpath(test)
    seen = {}
    for label, path in ([('--src', src), ('--test', test)] + [('--also-copy', c) for c in companions]):
        b = os.path.basename(path)
        prev = seen.get(b)
        if prev and os.path.realpath(prev[1]) != os.path.realpath(path):
            print(f'usage: {label} {path} and {prev[0]} {prev[1]} share the basename {b!r}, so one would '
                  f'overwrite the other in the copy dir; rename one', file=sys.stderr)
            return 4
        seen[b] = (label, path)

    if src_base == test_base and not same_file:
        print(f'usage: --src {src} and --test {test} share the basename {src_base!r}, so the test copy '
              f'would overwrite the armed source and every mutant would read SURVIVED; rename one or '
              f'copy them to distinct names', file=sys.stderr)
        return 4

    # A mutation run READS the tracked tree (it copies the source out of it and hashes every
    # tracked file before and after), so it is a reader and must hold the shared tree lock — it
    # previously took only the cpu lock, and a concurrent `--write` job could rewrite the source
    # between the copy and the census. Shared, so mutation runs still overlap each other.
    lock_args = (None, None, None) if args.no_lock else (root, 'sh', 'sh')

    # Signals are handled from here on, because from here on there is a child to kill and a
    # ledger row to write. A terminated mutation run used to do neither: its suite kept running
    # unsupervised and `loop.py profile` saw no mutant work at all for the round, so the wall-clock
    # it consumed landed in the unexplained-gap bucket instead of against the job that spent it.
    _install_signal_handlers()
    t_batch = _now()
    results: list[tuple[str, str, str, bool]] = []   # label, expect, outcome, matched
    timings: list[tuple[float, float, float]] = []   # t_req, t_run, t_end per executed mutant
    unscoped: list[str] = []
    rc = 1
    interrupted = None
    try:
        # ---- green baseline: the suite must PASS on the UNMUTATED source before anything is armed.
        # A test that is already red reports every mutant as KILLED, so every `expect: killed` matches
        # and the harness certifies itself green on zero evidence. Measured before this guard, with a
        # one-test file asserting 1 + 2 == 999 (red on the unmutated source):
        #   KILLED   OK   M1 plus becomes minus  (expect killed)
        #   1/1 mutants matched expectation; tracked files unchanged: True   -> exit 0
        # One unfiltered run per invocation, not one per mutant: if the whole file passes here, no
        # per-mutant filter can select a test that was already failing.
        shutil.rmtree(copy_dir, ignore_errors=True)
        os.makedirs(copy_dir)
        place_companions()
        base_copy = os.path.join(copy_dir, test_base)
        if same_file:
            write_source(base_copy, apply_rewrites(apply_rewrites(src_text, args.src_rewrite), args.rewrite))
        else:
            write_source(os.path.join(copy_dir, src_base), apply_rewrites(src_text, args.src_rewrite))
            write_source(base_copy, test_copy_text)
        base_cmd = args.test_cmd.format(test=os.path.relpath(base_copy, root), filter='')
        with Locks(*lock_args, holder='mutate:baseline'):
            base_proc = run_test_cmd(base_cmd, root, copy_dir)
        base_out = base_proc.stdout + base_proc.stderr
        base_ran = tests_ran(base_out)
        if base_proc.returncode != 0 or base_ran == 0:
            why = ('the suite is RED before any mutant is armed' if base_proc.returncode != 0
                   else 'the suite executed ZERO tests')
            print(f'BASELINE NOT GREEN: {why} (rc={base_proc.returncode}, tests executed={base_ran}).')
            print('  Every mutant would then read as KILLED and this run would report itself green.')
            print(f'  command: {base_cmd}')
            for ln in base_out.splitlines()[-12:]:
                print('   ', ln[:140])
            if not args.keep_copy:
                shutil.rmtree(copy_dir, ignore_errors=True)
            rc = 5
            return rc
        print(f'baseline OK: {base_ran} test(s) pass on the unmutated source')

        try:
            for m in mutants:
                # `old`/`new` may be parallel lists: one mutant made of several edits (a MOVE is a
                # delete at one site plus an insert at another), each still asserted unique.
                olds = m['old'] if isinstance(m['old'], list) else [m['old']]
                news = m['new'] if isinstance(m['new'], list) else [m['new']]
                if len(olds) != len(news):
                    print(f"MISARMED  {m['label']}: old/new lists differ in length")
                    results.append((m['label'], m['expect'], 'misarmed', False))
                    continue
                mutated = src_text
                misarmed = None
                for old, new in zip(olds, news):
                    count = mutated.count(old)
                    if count != 1:
                        misarmed = f'`old` {old[:50]!r} occurs {count} times (need exactly 1)'
                        break
                    mutated = mutated.replace(old, new)
                if misarmed:
                    print(f"MISARMED  {m['label']}: {misarmed}")
                    results.append((m['label'], m['expect'], 'misarmed', False))
                    continue
                shutil.rmtree(copy_dir, ignore_errors=True)
                os.makedirs(copy_dir)
                place_companions()
                mutated = apply_rewrites(mutated, args.src_rewrite)
                test_copy = os.path.join(copy_dir, test_base)
                if same_file:
                    # One file, written ONCE and carrying the mutation. Writing the test copy after it
                    # would erase the mutant; see the same_file note where it is computed.
                    write_source(test_copy, apply_rewrites(mutated, args.rewrite))
                else:
                    write_source(os.path.join(copy_dir, src_base), mutated)
                    with open(test_copy, 'w', encoding='utf-8') as fh:
                        fh.write(test_copy_text)
                name = m.get('test')
                filt = f'{args.filter_flag} {shlex.quote(name)}' if name else ''
                cmd = args.test_cmd.format(test=os.path.relpath(test_copy, root), filter=filt)
                # Each mutant run is a LIGHT CPU job: it shares the machine with other light jobs
                # and waits for a heavy one (a full suite, a tsc) instead of fighting it.
                t_req = _now()
                with Locks(*lock_args, holder=f"mutate:{m['label'][:40]}"):
                    t_run = _now()
                    proc = run_test_cmd(cmd, root, copy_dir)
                timings.append((t_req, t_run, _now()))
                out = proc.stdout + proc.stderr
                # A vitest name filter that matches nothing marks every test skipped and exits 0,
                # which would read as SURVIVED and turn each `killed` expectation green by default.
                # Require that the filtered run actually EXECUTED a test; fail closed if it did not.
                # Guarded for EVERY run, not only filtered ones. The `name and` form left the
                # unfiltered case open: a whole-file command that executes nothing (a moved test file,
                # a harness that prints no summary) exits 0, reads as SURVIVED, and turns every
                # `expect: survived` mutant green without running a line of the code under test.
                # "No test ran" is the absence of evidence in both directions, so it fails closed.
                if tests_ran(out) == 0:
                    why = (f'{args.filter_flag} {name!r} selected 0 tests' if name
                           else 'the unfiltered run executed 0 tests')
                    print(f"MISARMED  {m['label']}: {why} "
                          f"(a run that executes nothing exits 0 and would read as SURVIVED)")
                    results.append((m['label'], m['expect'], 'misarmed', False))
                    continue
                outcome = 'survived' if proc.returncode == 0 else 'killed'
                want = 'survived' if m['expect'] == 'unobservable' else m['expect']
                matched = outcome == want
                summary = next((ln.strip() for ln in out.splitlines() if ln.strip().startswith('Tests ')), '')
                failing = [ln.strip() for ln in out.splitlines() if ln.strip().startswith('×') or ln.strip().startswith('FAIL ')][:4]
                tag = 'OK  ' if matched else 'MISMATCH'
                scope = '' if name or m['expect'] != 'killed' else '  UNSCOPED(whole file; set `test`)'
                print(f"{outcome.upper():8} {tag} {m['label']}  (expect {m['expect']})  {summary}{scope}")
                for ln in failing:
                    print('   ', ln[:140])
                results.append((m['label'], m['expect'], outcome, matched))
        finally:
            if not args.keep_copy:
                shutil.rmtree(copy_dir, ignore_errors=True)

        after = {p: sha256(p) for p in tracked}
        changed = [p for p in tracked if before[p] != after[p]]
        n_ok = sum(1 for r in results if r[3])
        print(f'\n{n_ok}/{len(results)} mutants matched expectation; tracked files unchanged: {not changed}')
        for label, expect, outcome, matched in results:
            if not matched:
                print(f'  mismatch: {label}: expected {expect}, got {outcome}')
        unscoped[:] = [m['label'] for m in mutants if m['expect'] == 'killed' and not m.get('test')]
        if unscoped:
            print(f"  UNSCOPED: {len(unscoped)} `expect: killed` mutant(s) ran the whole file — set `test` on each: "
                  + ', '.join(unscoped[:6]))
        if changed:
            for p in changed:
                print(f'  TRACKED FILE CHANGED DURING RUN: {os.path.relpath(p, root)}')
        rc = 3 if changed else (0 if n_ok == len(results) else 2)
        return rc   # the batch's ledger row is written by the finally below, on EVERY exit path
    except _Interrupted as e:
        interrupted = e.signum
        rc = 128 + e.signum
        print(f'\nINTERRUPTED by signal {e.signum}: the running test was killed as a group; '
              f'{len(results)} of {len(mutants)} mutant(s) had completed.', file=sys.stderr)
        return rc
    finally:
        _terminate_child(signal.SIGKILL)
        if not args.keep_copy:
            shutil.rmtree(copy_dir, ignore_errors=True)
        arc = arc_dir(args.arc)
        if arc and args.track and args.round is not None:
            # One ledger row for the whole mutant batch, so `loop.py profile` can price the
            # round's mutation work per mutant (lever L3) and see the queue it waited in.
            # Written from `finally` so an interrupted or baseline-refused run is still ATTRIBUTED:
            # a job that spent wall-clock and left no row is exactly the unexplained gap the
            # profiler is meant to eliminate.
            t0 = timings[0][1] if timings else t_batch
            t_req0 = timings[0][0] if timings else t_batch
            note = (f'INTERRUPTED by signal {interrupted}; ' if interrupted else '')
            record_job(arc, args.track, args.round, 'mutant', f'mutants-{os.path.splitext(src_base)[0]}',
                       t0, _now(), rc, cpu='light', t_req=t_req0,
                       queued_s=sum(t1 - t_q for t_q, t1, _ in timings), mutants=len(timings),
                       unscoped=len(unscoped), reported=sum(t2 - t1 for _, t1, t2 in timings),
                       reason=f'{note}{sum(1 for r in results if r[3])}/{len(results)} matched; rc={rc}')




if __name__ == '__main__':
    sys.exit(main())
