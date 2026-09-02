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
A filter that selects NO test is reported MISARMED, never SURVIVED: vitest exits 0
when its name filter matches nothing, so an unguarded filter would silently convert
every `killed` expectation into a passing `survived` one.
`old` must occur EXACTLY ONCE in the source (a zero or multi-site match aborts that
mutant as MISARMED).  `old`/`new` may be parallel LISTS for a mutant made of several
edits (a move = delete here + insert there), applied in order, each asserted unique.
`unobservable` is an alias for `survived` with the intent recorded in the label.

--census 'REGEX=N' asserts that exactly N source lines match REGEX — the
completeness guard for an enumerated defect class (e.g. every /g-flagged literal),
so a site added since the enumeration fails the run instead of going unarmed.

Exit status: 0 every mutant matched its expectation and tracked files are unchanged;
2 at least one mutant did not; 3 a tracked file changed or a census failed;
4 usage error.  Use a copy dir UNIQUE to your session — two sessions sharing one
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
import subprocess
import sys

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
    ap.add_argument('--census', action='append', default=[], metavar='REGEX=N', help='assert exactly N source lines match REGEX (repeatable)')
    ap.add_argument('--test-cmd', default='npx vitest run {test} {filter}', help="command template; {test} is the copied test path, {filter} the -t name filter from the mutant's `test` key (empty when it has none)")
    ap.add_argument('--keep-copy', action='store_true', help='leave the copy dir in place after the last mutant (default: removed)')
    ap.add_argument('--only', help='run only mutants whose label contains this substring')
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

    with open(args.mutants) as fh:
        mutants = json.load(fh)
    for m in mutants:
        missing = {'label', 'old', 'new', 'expect'} - set(m)
        if missing or m['expect'] not in ('killed', 'survived', 'unobservable'):
            print(f'usage: bad mutant entry {m!r} (missing {sorted(missing)} or bad expect)', file=sys.stderr)
            return 4
    if args.only:
        mutants = [m for m in mutants if args.only in m['label']]

    tracked = [src, test] + [os.path.join(root, t) for t in args.tracked]
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

    test_copy_text = apply_rewrites(test_text, args.rewrite)
    src_base = os.path.basename(src)
    test_base = os.path.basename(test)

    results: list[tuple[str, str, str, bool]] = []  # label, expect, outcome, matched
    timings: list[tuple[float, float, float]] = []  # t_req, t_run, t_end per executed mutant
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
            mutated = apply_rewrites(mutated, args.src_rewrite)
            with open(os.path.join(copy_dir, src_base), 'w', encoding='utf-8') as fh:
                fh.write(mutated)
            test_copy = os.path.join(copy_dir, test_base)
            with open(test_copy, 'w', encoding='utf-8') as fh:
                fh.write(test_copy_text)
            name = m.get('test')
            filt = f'{args.filter_flag} {shlex.quote(name)}' if name else ''
            cmd = args.test_cmd.format(test=os.path.relpath(test_copy, root), filter=filt)
            # Each mutant run is a LIGHT CPU job: it shares the machine with other light jobs
            # and waits for a heavy one (a full suite, a tsc) instead of fighting it.
            t_req = _now()
            with Locks(None, None, None if args.no_lock else 'sh', holder=f"mutate:{m['label'][:40]}"):
                t_run = _now()
                proc = subprocess.run(cmd, shell=True, cwd=root, capture_output=True, text=True)
            timings.append((t_req, t_run, _now()))
            out = proc.stdout + proc.stderr
            # A vitest name filter that matches nothing marks every test skipped and exits 0,
            # which would read as SURVIVED and turn each `killed` expectation green by default.
            # Require that the filtered run actually EXECUTED a test; fail closed if it did not.
            if name and tests_ran(out) == 0:
                print(f"MISARMED  {m['label']}: -t {name!r} selected 0 tests "
                      f"(a zero-match filter exits 0 and would read as SURVIVED)")
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
    unscoped = [m['label'] for m in mutants if m['expect'] == 'killed' and not m.get('test')]
    if unscoped:
        print(f"  UNSCOPED: {len(unscoped)} `expect: killed` mutant(s) ran the whole file — set `test` on each: "
              + ', '.join(unscoped[:6]))
    if changed:
        for p in changed:
            print(f'  TRACKED FILE CHANGED DURING RUN: {os.path.relpath(p, root)}')
    rc = 3 if changed else (0 if n_ok == len(results) else 2)
    arc = arc_dir(args.arc)
    if arc and args.track and args.round is not None and timings:
        # One ledger row for the whole mutant batch, so `loop.py profile` can price the
        # round's mutation work per mutant (lever L3) and see the queue it waited in.
        record_job(arc, args.track, args.round, 'mutant', f'mutants-{os.path.splitext(src_base)[0]}',
                   timings[0][1], timings[-1][2], rc, cpu='light', t_req=timings[0][0],
                   queued_s=sum(t1 - t0 for t0, t1, _ in timings), mutants=len(timings),
                   unscoped=len(unscoped), reported=sum(t2 - t1 for _, t1, t2 in timings),
                   reason=f'{n_ok}/{len(results)} matched; tracked unchanged: {not changed}')
    return rc


if __name__ == '__main__':
    sys.exit(main())
