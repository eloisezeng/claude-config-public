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
   "expect": "killed" | "survived" | "unobservable"}
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
import shutil
import subprocess
import sys


def sha256(path: str) -> str:
    with open(path, 'rb') as fh:
        return hashlib.sha256(fh.read()).hexdigest()


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
    ap.add_argument('--test-cmd', default='npx vitest run {test}', help='command template; {test} is the copied test path')
    ap.add_argument('--keep-copy', action='store_true', help='leave the copy dir in place after the last mutant (default: removed)')
    ap.add_argument('--only', help='run only mutants whose label contains this substring')
    args = ap.parse_args()

    root = os.path.abspath(args.root)
    src = os.path.join(root, args.src)
    test = os.path.join(root, args.test)
    copy_dir = os.path.join(root, args.copy_dir)
    for p in (src, test):
        if not os.path.isfile(p):
            print(f'usage: not a file: {p}', file=sys.stderr)
            return 4
    if os.path.commonpath([copy_dir, root]) != root or copy_dir == root:
        print('usage: --copy-dir must be a subdirectory of --root', file=sys.stderr)
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
            cmd = args.test_cmd.format(test=os.path.relpath(test_copy, root))
            proc = subprocess.run(cmd, shell=True, cwd=root, capture_output=True, text=True)
            out = proc.stdout + proc.stderr
            outcome = 'survived' if proc.returncode == 0 else 'killed'
            want = 'survived' if m['expect'] == 'unobservable' else m['expect']
            matched = outcome == want
            summary = next((ln.strip() for ln in out.splitlines() if ln.strip().startswith('Tests ')), '')
            failing = [ln.strip() for ln in out.splitlines() if ln.strip().startswith('×') or ln.strip().startswith('FAIL ')][:4]
            tag = 'OK  ' if matched else 'MISMATCH'
            print(f"{outcome.upper():8} {tag} {m['label']}  (expect {m['expect']})  {summary}")
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
    if changed:
        for p in changed:
            print(f'  TRACKED FILE CHANGED DURING RUN: {os.path.relpath(p, root)}')
        return 3
    return 0 if n_ok == len(results) else 2


if __name__ == '__main__':
    sys.exit(main())
