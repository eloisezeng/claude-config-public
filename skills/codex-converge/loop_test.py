#!/usr/bin/env python3
"""loop_test.py — pins loop.py's fail-closed rules, lock classes, gate and attribution.

Run:  python3 loop_test.py [-k PATTERN]
Prints a vitest-shaped `Test Files` / `Tests` summary at the end so mutate.py's zero-match
guard (`tests_ran`) applies to this file's own mutants:
  mutate.py --src loop.py --test loop_test.py --copy-dir <copy> --mutants <json> \
            --test-cmd 'python3 {test} {filter}' --filter-flag -k
Every lock and ledger lives under a fresh temp dir (CC_LOCK_DIR / --arc), never the user's.
"""
from __future__ import annotations

import io
import json
import os
import random
import shutil
import signal
import stat
import subprocess
import sys
import tempfile
import time
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import loop  # noqa: E402

LOOP = os.path.join(HERE, 'loop.py')
PY = sys.executable
STUB = '''#!/bin/sh
[ -n "${VITEST_STUB_ARGS:-}" ] && printf '%s\\n' "$*" >> "$VITEST_STUB_ARGS"
printf '%s\\n' "${VITEST_STUB_OUT:-}"
exit "${VITEST_STUB_RC:-0}"
'''
HAPPY = 'Test Files  1 passed (1)\nTests  3 passed (3)\nDuration  0.40s'


class Sandbox:
    def __init__(self):
        self.dir = tempfile.mkdtemp(prefix='looptest-')
        self.arc = os.path.join(self.dir, 'job', 'tmp')
        os.makedirs(self.arc)
        os.makedirs(os.path.join(self.dir, 'bin'))
        stub = os.path.join(self.dir, 'bin', 'vitest')
        with open(stub, 'w') as fh:
            fh.write(STUB)
        os.chmod(stub, 0o755)
        self.env = {k: v for k, v in os.environ.items()
                    if k not in ('CC_ARC', 'CC_TRACK', 'CC_ROUND', 'CLAUDE_JOB_DIR', 'VITEST_STUB_OUT', 'VITEST_STUB_RC', 'VITEST_STUB_ARGS')}
        self.env['CC_LOCK_DIR'] = os.path.join(self.dir, 'locks')
        self.env['PATH'] = os.path.join(self.dir, 'bin') + os.pathsep + self.env.get('PATH', '')

    def record_preflight(self):
        """Put an efficiency preflight on this arc's ledger, as `loop.py preflight` would.

        Round 1 refuses a review/write/mutant launch without one, so every test whose subject is
        something ELSE (locks, the scheduler, close-round) needs this or it silently becomes a test
        of the preflight gate -- and fails as a 20s wait_event timeout that never names the cause.
        """
        loop.ledger_append(self.arc, dict(
            ev='preflight', codex=None, codex_unavailable='sandbox: no reviewer in a unit test',
            supersedes=None, critical_path='the fixture under test, not a real arc',
            parallel='nothing -- one job at a time unless the test says otherwise',
            batch='the sandbox batches no checks', scope='only the behaviour this test names',
            stop='1 round: the assertion at the end of this test', drivers='none: a stub vitest'))

    def cleanup(self):
        shutil.rmtree(self.dir, ignore_errors=True)

    def run(self, *args, env=None, **kw):
        e = dict(self.env)
        e.update(env or {})
        return subprocess.run([PY, LOOP, *args], env=e, capture_output=True, text=True, **kw)

    def start(self, *args, env=None):
        e = dict(self.env)
        e.update(env or {})
        return subprocess.Popen([PY, LOOP, *args], env=e, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)

    def jobs(self):
        """name -> dict(start, end, queued, rc, reason, cpu, checkpoint, tree_moved, tests, kind)."""
        starts, ends = {}, {}
        for ev in loop.ledger_read(self.arc):
            if ev.get('ev') == 'start':
                starts[ev['job']] = ev
            elif ev.get('ev') == 'end':
                ends[ev['job']] = ev
        out = {}
        for job, s in starts.items():
            e = ends.get(job, {})
            out[s['name']] = dict(start=s['t'], end=e.get('t'), queued=s.get('queued_s', 0.0), rc=e.get('rc'),
                                  reason=e.get('reason', ''), cpu=s.get('cpu'), checkpoint=s.get('checkpoint'),
                                  tree_moved=e.get('tree_moved'), tests=e.get('tests'), kind=s.get('kind'),
                                  cmd=s.get('cmd'), affected=s.get('affected'))
        return out

    def git_repo(self, name='repo'):
        r = os.path.join(self.dir, name)
        os.makedirs(r)
        g = ['git', '-C', r, '-c', 'user.email=t@t', '-c', 'user.name=t']
        subprocess.run(g[:3] + ['init', '-q'], check=True)
        for f, body in (('a.ts', 'export const a = 1;\n'), ('a.test.ts', 'import {a} from "./a";\n'), ('README.md', 'hi\n')):
            with open(os.path.join(r, f), 'w') as fh:
                fh.write(body)
        subprocess.run(g + ['add', '-A'], check=True)
        subprocess.run(g + ['commit', '-qm', 'init'], check=True)
        return r, g


def sbx(test, preflight=True):
    """A fresh sandbox, preflighted by default so round 1 will launch.

    `preflight=False` is the un-preflighted arc, and TestPreflight uses it deliberately: the gate's
    own tests must exercise the refusing path, or the default here could stop working and nothing
    would notice.
    """
    s = Sandbox()
    test.addCleanup(s.cleanup)
    if preflight:
        s.record_preflight()
    return s


# ---------------------------------------------------------------------------- pure rules
class TestCpuClass(unittest.TestCase):
    def test_table(self):
        tbl = [
            (('vitest', ['npx', 'vitest', 'run']), 'heavy'),
            (('vitest', ['npx', 'vitest']), 'heavy'),
            (('vitest', ['npx', 'vitest', 'run', 'a.test.ts']), 'light'),
            (('vitest', ['npx', 'vitest', 'related', '--run', 'x.ts']), 'light'),
            (('vitest', ['npx', 'vitest', 'run', '--coverage', 'a.test.ts']), 'heavy'),
            (('vitest', ['npx', 'vitest', 'run', 'scripts/']), 'heavy'),
            (('vitest', ['npx', 'vitest', 'run', 'scripts']), 'heavy'),
            (('vitest', ['npm', 'test']), 'heavy'),
            (('vitest', ['npm', 'run', 'test:unit']), 'heavy'),
            (('vitest', ['npx', 'vitest', 'run', '-t', 'name', 'a.test.ts']), 'light'),
            (('vitest', ['npx', 'vitest', 'run', '--reporter', 'junit', '--outputFile', 'o.xml', 'a.test.ts']), 'light'),
            (('vitest', ['npx', 'vitest', 'run'] + [f'f{i}.test.ts' for i in range(8)]), 'light'),
            (('vitest', ['npx', 'vitest', 'run'] + [f'f{i}.test.ts' for i in range(9)]), 'heavy'),
            (('vitest', ['./node_modules/.bin/vitest', 'run', 'a.test.ts']), 'light'),
            (('vitest', ['some-unknown-runner', 'a.test.ts']), 'heavy'),
            (('tsc', ['npx', 'tsc', '--noEmit']), 'heavy'),
            (('review', ['codex']), 'none'),
            (('write', ['codex']), 'none'),
            (('ci', ['gh', 'run', 'watch']), 'none'),
            (('mutant', ['x']), 'light'),
            (('other', ['sleep', '1']), 'light'),
        ]
        for (k, a), want in tbl:
            self.assertEqual(loop.cpu_class(k, a), want, (k, a))
        self.assertEqual(loop.cpu_class('other', ['x'], 'heavy'), 'heavy')
        self.assertEqual(loop.cpu_class('other', ['x'], 'none'), 'none')
        self.assertEqual(loop.cpu_class('tsc', ['x'], 'light'), 'heavy', 'explicit cannot downgrade a classified kind')

    def test_flag_forms_and_related_bounds(self):
        tbl = [
            (['npx', 'vitest', 'run', '--coverage=true', 'a.test.ts'], 'heavy'),
            (['npx', 'vitest', 'run', '--changed=HEAD~1', 'a.test.ts'], 'heavy'),
            (['npx', 'vitest', 'run', '--reporter=junit', 'a.test.ts'], 'light'),
            (['npx', 'vitest', 'run', '--testNamePattern=x', 'a.test.ts'], 'light'),
            (['npx', 'vitest', 'run', '--outputFile=o.xml', '--reporter=junit', 'a.test.ts'], 'light'),
            (['npx', 'vitest', 'related', '--run'] + [f's{i}.ts' for i in range(8)], 'light'),
            (['npx', 'vitest', 'related', '--run'] + [f's{i}.ts' for i in range(9)], 'heavy'),
            (['npx', 'vitest', 'related', '--run'], 'heavy'),
            (['npx', 'vitest', 'related', '--run', 'src/'], 'heavy'),
            (['npx', 'vitest', 'related', '--run', '--coverage', 'a.ts'], 'heavy'),
            (['npx', 'vitest', 'run', '--dir=scripts', 'a.test.ts'], 'light'),
            (['npx', 'vitest', 'run', 'tests/**/*.test.ts'], 'heavy'),
            (['npx', 'vitest', 'run', '*.test.ts'], 'heavy'),
            (['npx', 'vitest', 'run', 'a.test.ts', 'b?.test.ts'], 'heavy'),
            (['npx', 'vitest', 'run', 'one.test.ts', '--watch=true'], 'heavy'),
            (['npx', 'vitest', 'run', 'one.test.ts', '--coverage=false'], 'heavy'),
        ]
        for argv, want in tbl:
            self.assertEqual(loop.cpu_class('vitest', argv), want, argv)

    def test_a_literal_bracket_folder_is_one_file_not_a_glob(self):
        """Next.js names route folders `[slug]`. A test file that EXISTS under one is a single file
        (light); the same spelling with no file behind it keeps the glob reading (heavy)."""
        import tempfile
        with tempfile.TemporaryDirectory() as d:
            os.makedirs(os.path.join(d, 'app', '[slug]'))
            real = os.path.join(d, 'app', '[slug]', 'card.test.tsx')
            open(real, 'w').close()
            missing = os.path.join(d, 'app', '[slug]', 'gone.test.tsx')
            self.assertEqual(loop.cpu_class('vitest', ['npx', 'vitest', 'run', real]), 'light')
            self.assertEqual(loop.cpu_class('vitest', ['npx', 'vitest', 'run', real, 'a.test.ts']), 'light')
            self.assertEqual(loop.cpu_class('vitest', ['npx', 'vitest', 'run', missing]), 'heavy')
            # eight real files stay light; a ninth tips it, exactly as for plain names
            eight = [real] * 8
            self.assertEqual(loop.cpu_class('vitest', ['npx', 'vitest', 'run'] + eight), 'light')
            self.assertEqual(loop.cpu_class('vitest', ['npx', 'vitest', 'run'] + eight + [real]), 'heavy')

    VALUE_FLAGS = ['-t', '--testNamePattern', '-c', '--config', '-r', '--root', '--dir', '--reporter',
                   '--outputFile', '--pool', '--maxWorkers', '--minWorkers', '--environment',
                   '--project', '--shard', '--testTimeout', '--hookTimeout', '--exclude', '--mode',
                   '--coverage.reporter', '--sequence.seed', '--retry', '--bail', '--maxConcurrency']

    def test_every_value_flag_is_swept_at_the_eight_file_boundary_in_both_spellings(self):
        """A value-taking flag whose VALUE is not consumed leaves that value looking like a file.

        `--maxWorkers 4` with eight real test files then counts as nine operands and the run is
        classified heavy -- a scoped question paying for a wide run, forever, silently. The random
        sweep above draws from a hand-written sample of eight flags, so a member dropped from
        VALUE_FLAGS is invisible to it; this walks the real tuple, and the bound 8 is written as a
        literal here rather than imported, so widening SCOPED_MAX_FILES cannot pass both.
        """
        # The tuple's MEMBERSHIP is written out here as well as swept below. Sweeping
        # `loop.VALUE_FLAGS` alone is a derived oracle: delete a member and it drops out of the
        # sweep too, so the test that exists to catch that deletion passes. The literal is the
        # half that fails; the sweep is the half that says what each member has to DO.
        self.assertEqual(sorted(self.VALUE_FLAGS), sorted(loop.VALUE_FLAGS),
                         'VALUE_FLAGS changed: add the new flag here too, and check it really '
                         'takes a value -- a flag listed here wrongly EATS the next operand')
        files = [f'f{i}.test.ts' for i in range(8)]
        self.assertEqual(loop.cpu_class('vitest', ['npx', 'vitest', 'run'] + files), 'light',
                         'eight files with no flag at all is the light side of the boundary')
        self.assertEqual(loop.cpu_class('vitest', ['npx', 'vitest', 'run'] + files + ['f8.test.ts']), 'heavy',
                         'nine is the heavy side -- if this fails the boundary moved and the sweep below means nothing')
        for flag in sorted(loop.VALUE_FLAGS):
            for argv in (['npx', 'vitest', 'run', flag, 'v'] + files,
                         ['npx', 'vitest', 'run', f'{flag}=v'] + files):
                self.assertEqual(loop.cpu_class('vitest', argv), 'light',
                                 f'{argv[3:5]} ate a file slot: its value was counted as a test file')
            self.assertEqual(loop.cpu_class('vitest', ['npx', 'vitest', 'run', flag, 'v'] + files + ['f8.test.ts']),
                             'heavy', f'{flag} must not HIDE a ninth file either')

    def test_vitest_sweep_against_an_independent_oracle(self):
        """The oracle is written as literal rules with the literal bound 8 — it must NOT import
        SCOPED_MAX_FILES or restate cpu_class, or a mutant that widens the bound passes both."""
        rng = random.Random(20260902)
        wide_forms = ['--coverage', '--changed', '-w', '--coverage=true', '--changed=HEAD~1']
        value_forms = [['--reporter', 'junit'], ['--reporter=dot'], ['-t', 'some name'], ['--testNamePattern=x'],
                       ['--outputFile', 'o.xml'], ['--outputFile=o.xml'], ['--dir', 'scripts'], ['--dir=scripts']]
        for _ in range(600):
            nfiles = rng.choice([0, 1, 2, 5, 7, 8, 9, 12])
            dirs = rng.random() < 0.2
            wide = rng.choice([None] + wide_forms) if rng.random() < 0.3 else None
            related = rng.random() < 0.3
            argv = ['npx', 'vitest', 'related' if related else 'run']
            if related:
                argv.append('--run')
            if wide:
                argv.append(wide)
            for vf in rng.sample(value_forms, rng.choice([0, 0, 1, 2])):
                argv += vf
            files = [f's{i}.ts' if related else f'f{i}.test.ts' for i in range(nfiles)]
            rng.shuffle(files)
            argv += files
            if dirs:
                argv.insert(rng.randrange(3, len(argv) + 1), rng.choice(['scripts/', 'scripts']))
            glob = rng.random() < 0.15
            if glob:
                argv.insert(rng.randrange(3, len(argv) + 1), rng.choice(['tests/**/*.test.ts', '*.test.ts', 'f[0-9].test.ts']))
            # --- the oracle: literal rules, literal 8 ---
            if wide is not None:
                want = 'heavy'
            elif dirs or glob:
                want = 'heavy'
            elif nfiles == 0 or nfiles > 8:
                want = 'heavy'
            else:
                want = 'light'
            self.assertEqual(loop.cpu_class('vitest', argv), want, argv)

    def test_needs_checkpoint(self):
        self.assertTrue(loop.needs_checkpoint('vitest', 'heavy', None))
        self.assertTrue(loop.needs_checkpoint('vitest', 'heavy', '  '))
        self.assertFalse(loop.needs_checkpoint('vitest', 'heavy', 'pre-merge'))
        self.assertFalse(loop.needs_checkpoint('vitest', 'light', None))
        self.assertFalse(loop.needs_checkpoint('tsc', 'heavy', None))

    # Every family CONFIG_RE names, written out as literals rather than derived from the pattern:
    # a table built by re-reading the regex passes whatever the regex says, including after a
    # mutation. Escalating is expensive (a wide run), so both directions matter -- a family that
    # stops escalating silently narrows what a config change re-verifies, and one that starts
    # escalating turns every ordinary edit into a full suite.
    ROOT_CONFIGS = ['vitest.config.js', 'vitest.config.cjs', 'vitest.config.mjs', 'vitest.config.ts',
                    'vitest.config.cts', 'vitest.config.mts',
                    'vitest.workspace.ts', 'vitest.workspace.js', 'vitest.workspace.mjs',
                    'vite.config.ts', 'vite.config.js', 'vite.config.mts',
                    'package.json', 'package-lock.json',
                    'tsconfig.json', 'tsconfig.build.json', 'tsconfig.node.json',
                    '.github/workflows/ci.yml', '.github/workflows/fly-deploy.yml']
    # (path, the files affected_plan should select) -- NONE of these may escalate. The nested forms
    # are the ones that matter: a repo with a package per directory has dozens of them, and a
    # pattern that lost its `^` would turn every one of them into a full-suite run.
    NOT_ROOT_CONFIGS = [('sub/vitest.config.ts', ['sub/vitest.config.ts']),
                        ('packages/app/vite.config.ts', ['packages/app/vite.config.ts']),
                        ('a/b/package.json', []),
                        ('x/tsconfig.json', []),
                        ('sub/.github/workflows/ci.yml', []),
                        ('packages.json', []),
                        ('my-package.json', []),
                        ('tsconfig.json.bak', []),
                        ('vitest.config.txt', []),
                        ('vitest.config.ts.snap', []),
                        ('README.md', [])]

    def test_affected_plan_escalates_every_root_config_family_and_nothing_else(self):
        for f in self.ROOT_CONFIGS:
            self.assertEqual(loop.affected_plan([f]), ('wide', [f]),
                             f'{f} is a root config: a change to it must escalate to a wide run')
            self.assertEqual(loop.affected_plan(['a.ts', f]), ('wide', [f]),
                             f'{f} must escalate even when it arrives alongside ordinary sources')
        for f, expected in self.NOT_ROOT_CONFIGS:
            self.assertEqual(loop.affected_plan([f]), ('scoped', expected),
                             f'{f} is not a ROOT config and must not escalate')

    def test_affected_plan(self):
        self.assertEqual(loop.affected_plan(['a.ts', 'b.test.ts', 'README.md', 'x/y.mjs']), ('scoped', ['a.ts', 'b.test.ts', 'x/y.mjs']))
        self.assertEqual(loop.affected_plan(['README.md']), ('scoped', []))
        self.assertEqual(loop.affected_plan([]), ('scoped', []))


class TestTestCounting(unittest.TestCase):
    def test_tests_ran(self):
        self.assertEqual(loop.tests_ran('Tests  3 passed | 2 skipped (5)'), 3)
        self.assertEqual(loop.tests_ran('  Tests  2 failed | 3 passed (5)'), 5)
        self.assertEqual(loop.tests_ran('Tests  0 passed | 5 skipped (5)'), 0)
        self.assertEqual(loop.tests_ran('Test Files  1 passed (1)'), 0, 'the Test Files line is not the Tests line')
        self.assertEqual(loop.tests_ran(''), 0)

    def test_test_files_ran(self):
        self.assertEqual(loop.test_files_ran('Test Files  1 passed (1)'), 1)
        self.assertEqual(loop.test_files_ran('Test Files  2 failed | 3 passed (5)'), 5)
        self.assertIsNone(loop.test_files_ran('No test files found, exiting with code 0'))
        self.assertIsNone(loop.test_files_ran(''))
        self.assertTrue(loop.no_tests_found('No test files found, exiting with code 0'))

    def test_verdict_truth_table(self):
        V = loop.vitest_verdict
        # a red child stays red, whatever the output says
        for out in ('', HAPPY, 'No test files found'):
            for nf in (False, True):
                for allow in (False, True):
                    self.assertEqual(V(1, out, nf, allow)[0], 1, (out, nf, allow))
                    self.assertEqual(V(137, out, nf, allow)[0], 137)
        # green + name filter + 0 executed = MISARMED regardless of allow
        zero = 'Test Files  1 passed (1)\nTests  0 passed | 5 skipped (5)'
        for allow in (False, True):
            rc, why = V(0, zero, True, allow)
            self.assertEqual(rc, loop.RC_FAILCLOSED)
            self.assertIn('MISARMED', why)
        # green + no summary / no files = NO-TESTS unless allowed
        for out in ('', 'No test files found, exiting with code 0', 'Test Files  0 passed (0)'):
            rc, why = V(0, out, False, False)
            self.assertEqual(rc, loop.RC_FAILCLOSED, out)
            self.assertIn('NO-TESTS', why)
            rc, why = V(0, out, False, True)
            self.assertEqual(rc, 0)
            self.assertIn('no-tests-allowed', why)
        # green with files and tests is green
        self.assertEqual(V(0, HAPPY, False, False), (0, '1 test file(s), 3 test(s)'))
        self.assertEqual(V(0, HAPPY, True, False)[0], 0)

    def test_has_name_filter(self):
        self.assertTrue(loop.has_name_filter(['npx', 'vitest', 'run', '-t', 'x', 'a.test.ts']))
        self.assertTrue(loop.has_name_filter(['npx', 'vitest', 'run', '--testNamePattern=x', 'a.test.ts']))
        self.assertTrue(loop.has_name_filter(['npx', 'vitest', 'run', '--testNamePattern', 'x']))
        self.assertFalse(loop.has_name_filter(['npx', 'vitest', 'run', 'a.test.ts']))


class TestGate(unittest.TestCase):
    def test_decision_sweep(self):
        rng = random.Random(7)
        ids = list(loop.LEVER_IDS)
        for _ in range(500):
            closed = rng.random() < 0.7
            trig = {i for i in ids if rng.random() < 0.4}
            disp = {i for i in ids if rng.random() < 0.5}
            ok, missing = loop.gate_decision(closed, trig, disp)
            self.assertEqual(missing, trig - disp)
            self.assertEqual(ok, closed and trig <= disp)

    def test_round_to_close_is_the_last_active_round_not_rnd_minus_one(self):
        """Which round must be closed is its own decision, and `rnd - 1` is wrong twice over."""
        evs = [dict(ev='queued', t=1, track='A', round=1, job='a1'),
               dict(ev='end', t=2, track='A', round=1, job='a1', rc=0, span_s=1.0),
               dict(ev='round-close', t=3, track='A', round=1, triggered=[]),
               dict(ev='queued', t=4, track='A', round=2, job='a2'),
               dict(ev='start', t=5, track='A', round=2, job='a2', pid=1)]
        # a track with no history before this round has nothing to close -- this is the
        # mid-arc lane case, and refusing it only pushed callers onto the lockless --one-off path
        self.assertIsNone(loop.round_to_close(evs, 'fresh', 3))
        self.assertIsNone(loop.round_to_close(evs, 'A', 1))
        # the last EARLIER round with activity, whichever it is
        self.assertEqual(loop.round_to_close(evs, 'A', 3), 2)
        self.assertEqual(loop.round_to_close(evs, 'A', 2), 1)
        # skipping a round must not escape the gate: launching round 9 still answers round 2
        self.assertEqual(loop.round_to_close(evs, 'A', 9), 2)
        # a failed launch that only ledgered a refusal still counts as history. The refusal must
        # count ON ITS OWN: a `queued` beside it would answer the same round anyway, so a test
        # carrying both cannot see `refused` being dropped from the set.
        self.assertEqual(loop.round_to_close(
            [dict(ev='refused', t=2, track='B', round=3, job='b1', reason='queue')], 'B', 4), 3)
        self.assertEqual(loop.round_to_close(
            [dict(ev='queued', t=1, track='B', round=1, job='b0'),
             dict(ev='refused', t=2, track='B', round=3, job='b1', reason='queue')], 'B', 4), 3,
            'the refused round is later than the queued one and must win')
        # a lever or a close alone is history too; no event kind of this track is exempt
        self.assertEqual(loop.round_to_close([dict(ev='lever', track='C', round=2, id='L1')], 'C', 5), 2)
        self.assertEqual(loop.round_to_close([dict(ev='round-close', track='C', round=2)], 'C', 5), 2)
        # another track's rounds are never this track's problem
        self.assertIsNone(loop.round_to_close(evs, 'other', 5))
        # a non-integer round in the ledger is ignored rather than crashing the gate
        self.assertIsNone(loop.round_to_close([dict(ev='start', track='D', round='2', job='x')], 'D', 5))
        self.assertIsNone(loop.round_to_close([dict(ev='start', track='D', job='x')], 'D', 5))

    def test_gate_admits_a_fresh_track_and_holds_a_used_one(self):
        """End to end through gate(), on a real ledger file."""
        import tempfile
        with tempfile.TemporaryDirectory() as arc:
            loop.ledger_append(arc, dict(ev='queued', track='used', round=2, job='j1'))
            loop.ledger_append(arc, dict(ev='start', track='used', round=2, job='j1', pid=os.getpid()))
            ok, why = loop.gate(arc, 'used', 3)
            self.assertFalse(ok, why)
            self.assertIn('round 2 of track used is not closed', why)
            ok, why = loop.gate(arc, 'fix-lane', 3)
            self.assertTrue(ok, why)
            self.assertIn('no earlier rounds', why)
            # closing round 2 lets the used track through
            loop.ledger_append(arc, dict(ev='round-close', track='used', round=2, triggered=[]))
            ok, why = loop.gate(arc, 'used', 3)
            self.assertTrue(ok, why)
        # A GAP: activity in round 1, closed, and nothing in round 2. Launching round 3 must read
        # round ONE. A gate still keyed on `rnd - 1` looks at the empty round 2, finds no close and
        # refuses -- so this case is the only one that can see that mutation.
        with tempfile.TemporaryDirectory() as arc:
            loop.ledger_append(arc, dict(ev='queued', track='G', round=1, job='g1'))
            loop.ledger_append(arc, dict(ev='end', track='G', round=1, job='g1', rc=0, span_s=1.0))
            ok, why = loop.gate(arc, 'G', 3)
            self.assertFalse(ok, 'round 1 is unclosed, so the gate must hold')
            self.assertIn('round 1 of track G is not closed', why)
            loop.ledger_append(arc, dict(ev='round-close', track='G', round=1, triggered=[]))
            ok, why = loop.gate(arc, 'G', 3)
            self.assertTrue(ok, why)
            self.assertIn('round 1 closed', why)

    def test_round_status_ignores_levers_recorded_before_the_close(self):
        evs = [
            dict(ev='lever', t=10, track='A', round=1, id='L2', state='landed', note='early'),
            dict(ev='round-close', t=20, track='A', round=1, triggered=['L2', 'L4']),
            dict(ev='lever', t=30, track='A', round=1, id='L4', state='declined', note='both wide runs were the checkpoint'),
            dict(ev='lever', t=31, track='B', round=1, id='L2', state='landed', note='other track'),
            dict(ev='lever', t=32, track='A', round=2, id='L2', state='landed', note='other round'),
        ]
        st = loop.round_status(evs, 'A', 1)
        self.assertTrue(st['closed'])
        self.assertEqual(st['triggered'], {'L2', 'L4'})
        self.assertEqual(st['dispositioned'], {'L4'}, 'the L2 lever event predates the close and must not count')
        self.assertEqual(loop.round_status(evs, 'A', 2)['closed'], False)
        self.assertEqual(loop.round_status([], 'A', 1)['closed'], False)

    def test_gate_cli_round_1_needs_a_preflight_not_history(self):
        """Round 1 used to pass unconditionally, and that was the bug the user reported.

        The efficiency machinery (profile-loop, close-round, levers) all keys on a CLOSED round, so
        while round 1 was free the earliest anything could ask "is this process shaped right?" was
        AFTER the first round's bill -- and round 1 is where the plan's shape is chosen. There is
        still no history to close at round 1; what is owed now is the preflight.
        """
        bare = sbx(self, preflight=False)
        r = bare.run('gate', '--arc', bare.arc, '--track', 'A', '--round', '1')
        self.assertEqual(r.returncode, loop.RC_GATE, r.stdout + r.stderr)
        self.assertIn('no efficiency preflight on record', r.stdout + r.stderr)

        s = sbx(self)
        r = s.run('gate', '--arc', s.arc, '--track', 'A', '--round', '1')
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertIn('nothing to close', r.stdout + r.stderr,
                      'round 1 still has no history to close -- the preflight is what it owes')


    def test_gate_refuses_rounds_below_one(self):
        """`rnd <= 1` waved round 0 and every negative round through unconditionally.

        A typo'd `--round 0` therefore bought a free launch AND recorded itself against round -1,
        which nothing ever closes — the gate's whole job, silently skipped. Rounds are 1-based.
        """
        s = sbx(self)   # preflighted: this test's subject is round <= 0, and it controls on round 1 passing
        for bad in ('0', '-3'):
            r = s.run('gate', '--arc', s.arc, '--track', 'Z', '--round', bad)
            self.assertEqual(r.returncode, loop.RC_GATE, f'round {bad} was waved through: {r.stdout}{r.stderr}')
            self.assertIn('not a valid round number', r.stdout + r.stderr)
        ok, why = loop.gate(s.arc, 'Z', 1)
        self.assertTrue(ok, why)   # control: round 1 still passes with no history


class TestGapClasses(unittest.TestCase):
    def test_classes(self):
        C = loop.classify_gap
        self.assertEqual(C(100, 200, [dict(t=150, text='waiting on the user')], None), ('declared', 'waiting on the user'))
        self.assertEqual(C(100, 200, [dict(t=50, text='before')], None)[0], 'unknown')
        self.assertEqual(C(100, 200, [], [(150, 'working', 'reading x')])[0], 'seat-active')
        self.assertIn('reading x', C(100, 200, [], [(150, 'working', 'reading x')])[1])
        self.assertEqual(C(100, 200, [], [(50, 'working', ''), (250, 'working', '')])[0], 'seat-silent')
        self.assertEqual(C(100, 200, [dict(t=150, text='declared wins')], [(150, 'working', '')])[0], 'declared')
        cls, why = C(100, 200, [], [(120, 'working', 'x'), (150, 'blocked', 'You have hit your session limit'), (190, 'blocked', 'go')])
        self.assertEqual(cls, 'seat-blocked', 'a blocked heartbeat inside the gap names the cause; activity does not outrank it')
        self.assertIn('session limit', why)

    def test_load_timeline_parses_iso_z(self):
        s = sbx(self)
        p = os.path.join(s.dir, 'job', 'timeline.jsonl')
        with open(p, 'w') as fh:
            fh.write(json.dumps(dict(at='2026-09-01T17:50:00.000Z', state='working', detail='x')) + '\n')
            fh.write('not json\n')
            fh.write(json.dumps(dict(at='bogus', state='working')) + '\n')
        tl = loop.load_timeline(s.arc)
        self.assertEqual(len(tl), 1)
        self.assertEqual(tl[0][1], 'working')
        self.assertIsNone(loop.load_timeline(os.path.join(s.dir, 'nowhere', 'tmp')))


# --------------------------------------------------------------------- scheduler (real)
def overlap(a, b):
    return a['start'] < b['end'] and b['start'] < a['end']


def hold(mdir, name, release='release', max_iter=600):
    """A child that marks itself started, then holds until <mdir>/<release> exists (≤ ~30 s)."""
    return ['sh', '-c', f'touch "{mdir}/{name}.started"; i=0; '
                        f'while [ ! -e "{mdir}/{release}" ] && [ $i -lt {max_iter} ]; do sleep 0.05; i=$((i+1)); done']


def touch(mdir, name):
    return ['sh', '-c', f'touch "{mdir}/{name}.started"']


def calibrate_spawn(run=subprocess.run, clock=time.time) -> float:
    """The cost of one trivial python subprocess RIGHT NOW, on this machine, under this load.

    Every liveness deadline below is a multiple of this rather than a bare literal. A fixed ceiling
    measures the machine, not the code, and this suite is contended by construction: its own
    codex-loop.test.sh runs mutate.py, which runs 44 filtered python suites beside it. Measured on
    this Mac: the 64-test suite takes 22 s alone and 114 s beside the mutant batch, and at that
    5x the fixed 20 s ceiling in `wait_path` failed two lock tests that are not otherwise flaky.
    One constant cannot be both a useful backstop and non-flaky across that spread.

    The median of three rejects a single outlier while still moving with real contention.
    """
    samples = []
    for _ in range(3):
        t0 = clock()
        run([sys.executable, '-c', 'pass'], capture_output=True)
        samples.append(clock() - t0)
    return reduce_samples(samples)


def reduce_samples(samples: list[float]) -> float:
    """Median of three, floored -- the sample-reduction rule, split out so it can be TESTED.

    Whether calibration measures the machine at all is not observable from its return value: on an
    idle Mac a real spawn costs about the floor, so `return 0.02` and a genuine measurement agree.
    The two decisions inside the rule ARE observable given samples, so they live here where a test
    can hand them a slow outlier and a machine faster than the floor.
    """
    return max(0.02, sorted(samples)[1])


SPAWN = [calibrate_spawn()]


def deadline(scale: float, floor: float) -> float:
    return max(floor, scale * SPAWN[0])


def _expired(t0, timeout, scale, floor, recalibrated) -> tuple[bool, bool]:
    """(give up now, recalibrated) — a caller-supplied timeout is absolute; a derived one gets ONE
    re-measurement first, because the machine may have become loaded since import."""
    lim = timeout if timeout is not None else deadline(scale, floor)
    if time.time() - t0 <= lim:
        return False, recalibrated
    if timeout is None and not recalibrated:
        SPAWN[0] = calibrate_spawn()
        return False, True
    return True, recalibrated


def wait_path(path, timeout=None, procs=()):
    """Wait for a marker a child process is expected to touch.

    The deadline is a BACKSTOP against a hang, not a measurement — so the real failure signal is
    `procs`: if every process that could produce this marker has exited without producing it, the
    wait can never succeed and fails immediately with that process's stderr, which is both faster
    and a far better diagnostic than a clock running out.
    """
    t0 = time.time()
    recal = False
    while not os.path.exists(path):
        if procs and all(p.poll() is not None for p in procs) and not os.path.exists(path):
            why = []
            for p in procs:
                try:
                    why.append(f'rc={p.returncode} {(p.stderr.read() if p.stderr else "")[-400:]}')
                except (ValueError, OSError):
                    why.append(f'rc={p.returncode}')
            raise AssertionError(f'{path} will never appear: every producer exited. ' + ' | '.join(why))
        over, recal = _expired(t0, timeout, 400.0, 20.0, recal)
        if over:
            raise AssertionError(f'{path} did not appear within {deadline(400.0, 20.0):.0f}s '
                                 f'(spawn calibration {SPAWN[0] * 1000:.0f} ms)')
        time.sleep(0.02)


def wait_event(arc, pred, timeout=None):
    """Poll the ledger until an event satisfies pred (the ledger is the synchronisation point)."""
    t0 = time.time()
    recal = False
    led = os.path.join(arc, 'jobs.jsonl')
    while True:
        if os.path.exists(led):
            with open(led, encoding='utf-8') as fh:
                for line in fh:
                    try:
                        ev = json.loads(line)
                    except ValueError:
                        continue
                    if pred(ev):
                        return ev
        over, recal = _expired(t0, timeout, 400.0, 20.0, recal)
        if over:
            raise AssertionError('ledger event not seen within %.0fs (spawn calibration %.0f ms)'
                                 % (deadline(400.0, 20.0), SPAWN[0] * 1000))
        time.sleep(0.02)


def mdir_of(s):
    d = os.path.join(s.dir, 'markers')
    os.makedirs(d, exist_ok=True)
    return d


class TestScheduler(unittest.TestCase):
    """Every ordering assertion here is STRUCTURAL: the holder blocks until the test releases it,
    so 'B started before/after A ended' is decided by the lock, never by machine speed.  The only
    numeric bounds are LOWER bounds on a wait the test itself imposed, which slowness can only
    lengthen (a mutant that fakes or clamps the queue measurement still fails them)."""

    def _serialised(self, s, kind_a, kind_b, hold_s=0.5, **extra):
        m = mdir_of(s)
        pa = s.start('run', '--arc', s.arc, '--track', 'A', '--round', '1', '--kind', kind_a, '--name', 'a', *extra.get('a', []), '--', *hold(m, 'a'))
        wait_path(os.path.join(m, 'a.started'), procs=(pa,))
        pb = s.start('run', '--arc', s.arc, '--track', 'A', '--round', '1', '--kind', kind_b, '--name', 'b', *extra.get('b', []), '--', *touch(m, 'b'))
        wait_event(s.arc, lambda ev: ev.get('ev') == 'queued' and ev.get('name') == 'b')
        time.sleep(hold_s)   # b is provably waiting throughout: a holds until we release it
        self.assertFalse(os.path.exists(os.path.join(m, 'b.started')), 'b ran while a held the lock')
        open(os.path.join(m, 'release'), 'w').close()
        pa.wait(timeout=deadline(600.0, 30.0))
        pb.wait(timeout=deadline(600.0, 30.0))
        self.assertEqual(pa.returncode, 0, pa.stderr.read())
        self.assertEqual(pb.returncode, 0, pb.stderr.read())
        j = s.jobs()
        self.assertGreaterEqual(j['b']['start'], j['a']['end'], j)
        self.assertGreaterEqual(j['b']['queued'], hold_s, j)
        # metric identity: the ledgered queue wait IS the request→start interval
        st = wait_event(s.arc, lambda ev: ev.get('ev') == 'start' and ev.get('name') == 'b')
        self.assertAlmostEqual(st['queued_s'], st['t'] - st['t_req'], delta=0.05)
        return j

    def _overlapped(self, s, kind_a, kind_b, **extra):
        m = mdir_of(s)
        pa = s.start('run', '--arc', s.arc, '--track', 'A', '--round', '1', '--kind', kind_a, '--name', 'a', *extra.get('a', []), '--', *hold(m, 'a'))
        wait_path(os.path.join(m, 'a.started'), procs=(pa,))
        pb = s.start('run', '--arc', s.arc, '--track', 'B', '--round', '1', '--kind', kind_b, '--name', 'b', *extra.get('b', []), '--', *hold(m, 'b'))
        wait_path(os.path.join(m, 'b.started'), procs=(pb,))   # b started while a still holds: structural overlap
        open(os.path.join(m, 'release'), 'w').close()
        pa.wait(timeout=deadline(600.0, 30.0))
        pb.wait(timeout=deadline(600.0, 30.0))
        self.assertEqual(pa.returncode, 0, pa.stderr.read())
        self.assertEqual(pb.returncode, 0, pb.stderr.read())
        j = s.jobs()
        self.assertTrue(overlap(j['a'], j['b']), j)
        self.assertLess(j['b']['start'], j['a']['end'], j)
        return j

    def test_heavy_heavy_serialise(self):
        self._serialised(sbx(self), 'tsc', 'tsc')

    def test_light_light_overlap(self):
        self._overlapped(sbx(self), 'mutant', 'mutant')

    def test_heavy_waits_for_light(self):
        self._serialised(sbx(self), 'mutant', 'tsc', hold_s=0.3)

    def test_review_overlaps_heavy(self):
        j = self._overlapped(sbx(self), 'tsc', 'review')
        self.assertEqual(j['b']['cpu'], 'none')

    def test_max_queue_refuses_instead_of_running_unlocked(self):
        s = sbx(self)
        m = mdir_of(s)
        pa = s.start('run', '--arc', s.arc, '--track', 'A', '--round', '1', '--kind', 'tsc', '--name', 'a', '--', *hold(m, 'a'))
        wait_path(os.path.join(m, 'a.started'), procs=(pa,))
        r = s.run('run', '--arc', s.arc, '--track', 'A', '--round', '1', '--kind', 'tsc', '--name', 'b', '--max-queue', '0.3', '--', *touch(m, 'b'))
        t_refused = time.time()
        self.assertEqual(r.returncode, loop.RC_LOCK, r.stderr)
        self.assertFalse(os.path.exists(os.path.join(m, 'b.started')), 'a refused job must not run')
        open(os.path.join(m, 'release'), 'w').close()
        pa.wait(timeout=deadline(600.0, 30.0))
        j = s.jobs()
        self.assertNotIn('b', j, 'a refused job must not be ledgered as started')
        self.assertGreaterEqual(j['a']['end'], t_refused, 'the holder was still holding when b was refused')
        ref = wait_event(s.arc, lambda ev: ev.get('ev') == 'refused' and ev.get('name') == 'b', timeout=1)
        self.assertIn('lock not available', ref['reason'])
        # It must have WAITED the deadline, not merely refused. `--max-queue` used to compare a wall
        # `now()` against a monotonic origin, so the difference was ~1.79e9 and every deadline fired on
        # the first contended poll: the refusal above is satisfied by a `--max-queue 3600` that refuses
        # in zero seconds. Measure the wait from the ledger (queued→refused, both stamped inside the
        # process under test) rather than from this test's own wall clock, which would be measuring
        # interpreter start-up on the machine as much as the deadline.
        q = wait_event(s.arc, lambda ev: ev.get('ev') == 'queued' and ev.get('name') == 'b', timeout=1)
        self.assertGreaterEqual(ref['t'] - q['t'], 0.3,
                                'refused before the --max-queue deadline elapsed (wall/monotonic mix-up)')
        # The wait was MEASURED with time.monotonic() by the process that did the waiting, and that
        # measurement has to be written down: the profiler row, L5 and the queued total all read
        # `queued_s` off this event, and a refusal that omits it silently falls back to subtracting
        # two wall stamps. Here the two agree to milliseconds, so only the field's presence is
        # checkable -- TestRefusedWaitSurvivesTheClock is where they are driven apart.
        self.assertIsNotNone(ref.get('queued_s'),
                             'the refusal must carry its own monotonic wait; rows_from_ledger reads queued_s')
        self.assertGreaterEqual(float(ref['queued_s']), 0.3)
        rows, _ = loop.rows_from_ledger(loop.ledger_read(s.arc))
        brow = [r for r in rows if r['path'].endswith('/b')]
        self.assertEqual(len(brow), 1, 'the refused job must still appear as a profiler row')
        self.assertGreaterEqual(brow[0]['queued'], 0.3,
                                'the profiler bills the wait it was handed, not a reconstruction')
        self.assertTrue(brow[0]['never_started'])

    def test_unwritable_lock_dir_refuses(self):
        s = sbx(self)
        afile = os.path.join(s.dir, 'afile')
        with open(afile, 'w') as fh:
            fh.write('x')
        r = s.run('run', '--arc', s.arc, '--track', 'A', '--round', '1', '--kind', 'tsc', '--', 'true',
                  env={'CC_LOCK_DIR': os.path.join(afile, 'locks')})
        self.assertEqual(r.returncode, loop.RC_LOCK, r.stderr)
        self.assertIn('unlocked', r.stderr)


class TestTreeLockAndMoved(unittest.TestCase):
    def test_write_waits_for_reader_of_same_tree(self):
        s = sbx(self)
        repo, _ = s.git_repo()
        m = mdir_of(s)   # markers live OUTSIDE the repo so they cannot move the tree under the reader
        pa = s.start('run', '--arc', s.arc, '--track', 'A', '--round', '1', '--kind', 'other', '--name', 'rd', '--tree', repo, '--', *hold(m, 'rd'))
        wait_path(os.path.join(m, 'rd.started'), procs=(pa,))
        pb = s.start('run', '--arc', s.arc, '--track', 'A', '--round', '1', '--kind', 'write', '--name', 'wr', '--tree', repo, '--', *touch(m, 'wr'))
        wait_event(s.arc, lambda ev: ev.get('ev') == 'queued' and ev.get('name') == 'wr')
        time.sleep(0.3)
        self.assertFalse(os.path.exists(os.path.join(m, 'wr.started')), 'the write ran while a reader held the tree')
        open(os.path.join(m, 'release'), 'w').close()
        pa.wait(timeout=deadline(600.0, 30.0))
        pb.wait(timeout=deadline(600.0, 30.0))
        self.assertEqual(pa.returncode, 0, pa.stderr.read())
        j = s.jobs()
        self.assertGreaterEqual(j['wr']['start'], j['rd']['end'], j)
        self.assertGreaterEqual(j['wr']['queued'], 0.3)

    def test_two_readers_of_same_tree_overlap(self):
        s = sbx(self)
        repo, _ = s.git_repo()
        m = mdir_of(s)
        pa = s.start('run', '--arc', s.arc, '--track', 'A', '--round', '1', '--kind', 'other', '--name', 'r1', '--tree', repo, '--', *hold(m, 'r1'))
        wait_path(os.path.join(m, 'r1.started'), procs=(pa,))
        pb = s.start('run', '--arc', s.arc, '--track', 'B', '--round', '1', '--kind', 'other', '--name', 'r2', '--tree', repo, '--', *hold(m, 'r2'))
        wait_path(os.path.join(m, 'r2.started'), procs=(pb,))
        open(os.path.join(m, 'release'), 'w').close()
        pa.wait(timeout=deadline(600.0, 30.0))
        pb.wait(timeout=deadline(600.0, 30.0))
        j = s.jobs()
        self.assertTrue(overlap(j['r1'], j['r2']), j)

    def test_snapshot_installs_the_link_for_every_installed_entry_it_finds(self):
        """The reuse check tolerates these entries only as links THIS command made. Nothing
        asserted the command makes them, so `os.path.isdir(src)` could become `os.path.isfile(src)`
        and every snapshot would come out with no node_modules at all -- each lens then resolving
        imports against whatever it could find, or failing to run, with the suite still green."""
        s = sbx(self)
        repo, g = s.git_repo()
        sha = subprocess.run(['git', '-C', repo, 'rev-parse', 'HEAD'], capture_output=True, text=True).stdout.strip()
        for rel in loop.SNAPSHOT_INSTALLED:
            os.mkdir(os.path.join(repo, rel))
            with open(os.path.join(repo, rel, 'marker.txt'), 'w') as fh:
                fh.write('the source copy\n')
        r = s.run('snapshot', '--arc', s.arc, '--track', 'A', '--round', '1', '--repo', repo, '--sha', sha)
        self.assertEqual(r.returncode, 0, r.stderr)
        path = r.stdout.strip()
        for rel in loop.SNAPSHOT_INSTALLED:
            here = os.path.join(path, rel)
            self.assertTrue(os.path.islink(here), f'{rel} was not installed as a LINK in the snapshot')
            self.assertEqual(os.path.realpath(here), os.path.realpath(os.path.join(repo, rel)),
                             f'{rel} points somewhere other than the source repo copy')
        # ...and the reuse path agrees with the installer: what it just made is not pollution.
        self.assertEqual(s.run('snapshot', '--arc', s.arc, '--track', 'A', '--round', '1',
                               '--repo', repo, '--sha', sha).stdout.strip(), path,
                         'the entries the installer created were then read back as pollution')

    def test_snapshot_installs_nothing_for_an_entry_the_source_repo_does_not_have(self):
        """Control for the sweep above: the link is installed because the source HAS the directory,
        not unconditionally -- a dangling symlink into a non-existent path is worse than no link."""
        s = sbx(self)
        repo, g = s.git_repo()
        sha = subprocess.run(['git', '-C', repo, 'rev-parse', 'HEAD'], capture_output=True, text=True).stdout.strip()
        path = s.run('snapshot', '--arc', s.arc, '--track', 'A', '--round', '1', '--repo', repo, '--sha', sha).stdout.strip()
        for rel in loop.SNAPSHOT_INSTALLED:
            self.assertFalse(os.path.lexists(os.path.join(path, rel)),
                             f'{rel} was linked although the source repo has no such directory')

    def test_snapshot_pins_a_detached_worktree_and_is_reused(self):
        s = sbx(self)
        repo, g = s.git_repo()
        first = subprocess.run(['git', '-C', repo, 'rev-parse', 'HEAD'], capture_output=True, text=True).stdout.strip()
        with open(os.path.join(repo, 'a.ts'), 'w') as fh:
            fh.write('export const a = 2;\n')
        subprocess.run(g + ['commit', '-aqm', 'second'], check=True, capture_output=True)

        r = s.run('snapshot', '--arc', s.arc, '--track', 'A', '--round', '1', '--repo', repo, '--sha', first)
        self.assertEqual(r.returncode, 0, r.stderr)
        path = r.stdout.strip()
        self.assertEqual(os.path.basename(path), first[:12])
        # the frozen tree really is the OLD commit, not whatever the live repo moved on to
        self.assertEqual(loop.tree_state(path)[0], first)
        with open(os.path.join(path, 'a.ts')) as fh:
            self.assertEqual(fh.read(), 'export const a = 1;\n')
        self.assertEqual(s.run('snapshot', '--arc', s.arc, '--track', 'A', '--round', '1',
                               '--repo', repo, '--sha', first).stdout.strip(), path, 'not reused')
        bad = s.run('snapshot', '--arc', s.arc, '--track', 'A', '--round', '1', '--repo', repo, '--sha', 'nosuchsha')
        self.assertEqual(bad.returncode, loop.RC_USAGE, bad.stderr)
        pr = s.run('snapshot', '--arc', s.arc, '--track', 'A', '--round', '1', '--repo', repo, '--prune')
        self.assertEqual(pr.returncode, 0, pr.stderr)
        self.assertFalse(os.path.isdir(path), 'prune left the worktree behind')

    def test_a_read_of_a_snapshot_overlaps_a_write_on_the_live_tree(self):
        """THE point of the snapshot: a review does not queue behind unrelated implementation.

        The live tree and the frozen tree are different paths, so they take different tree locks, and
        neither a review nor a `--write` takes the CPU lock. Without the snapshot these two jobs are
        the same tree and the review waits for the whole write (that serialised wait is what the arc
        profile measured as 7h34m)."""
        s = sbx(self)
        repo, _ = s.git_repo()
        sha = subprocess.run(['git', '-C', repo, 'rev-parse', 'HEAD'], capture_output=True, text=True).stdout.strip()
        snap = s.run('snapshot', '--arc', s.arc, '--track', 'A', '--round', '1', '--repo', repo, '--sha', sha).stdout.strip()
        m = mdir_of(s)
        pw = s.start('run', '--arc', s.arc, '--track', 'A', '--round', '1', '--kind', 'write', '--name', 'impl',
                     '--tree', repo, '--', *hold(m, 'impl'))
        wait_path(os.path.join(m, 'impl.started'), procs=(pw,))
        pr = s.start('run', '--arc', s.arc, '--track', 'B', '--round', '1', '--kind', 'review', '--name', 'lens',
                     '--tree', snap, '--', *hold(m, 'lens'))
        # the review must START while the write still holds the live tree exclusively
        wait_path(os.path.join(m, 'lens.started'), procs=(pr,))
        self.assertTrue(os.path.exists(os.path.join(m, 'impl.started')))
        open(os.path.join(m, 'release'), 'w').close()
        pw.wait(timeout=deadline(600.0, 30.0))
        pr.wait(timeout=deadline(600.0, 30.0))
        self.assertEqual(pr.returncode, 0, pr.stderr.read())
        j = s.jobs()
        # `overlap` IS the property: the two jobs held the machine at the same time. An added
        # `queued < 1.0` ceiling asserted nothing overlap does not, and what it actually measured
        # was this machine's process start-up under whatever else was running -- so it reddened
        # under load and said nothing about the scheduler either way.
        self.assertTrue(overlap(j['impl'], j['lens']), j)

    def test_sigkilling_the_scheduler_leaves_its_live_writer_holding_the_lock(self):
        """SIGKILL is uncatchable, so the lock has to survive it in the KERNEL, not in a handler.

        Before the fix the flock lived only on the scheduler's own fds: `kill -9` on the scheduler
        released the tree lock the same instant, while its --write child carried on editing that
        tree. The next queued job was then granted a lock on a worktree with a live writer in it —
        two processes writing one tree, which is the single corruption this scheduler exists to
        prevent. The child now inherits the lock fds, so the open file description (and its lock)
        stands for exactly as long as a writer exists.
        """
        s = sbx(self)
        repo, _ = s.git_repo()
        m = mdir_of(s)
        rel = os.path.join(m, 'release')
        # writes its own pid so the test can prove WHO is still holding the lock
        holder = ['sh', '-c', f'echo $$ > "{m}/impl.pid"; touch "{m}/impl.started"; i=0; '
                              f'while [ ! -e "{rel}" ] && [ $i -lt 600 ]; do sleep 0.05; i=$((i+1)); done']
        pw = s.start('run', '--arc', s.arc, '--track', 'A', '--round', '1', '--kind', 'write',
                     '--name', 'impl', '--tree', repo, '--', *holder)
        wait_path(os.path.join(m, 'impl.started'), procs=(pw,))
        with open(os.path.join(m, 'impl.pid')) as fh:
            kid = int(fh.read().strip())

        os.kill(pw.pid, signal.SIGKILL)
        pw.wait(timeout=deadline(600.0, 30.0))
        self.assertTrue(loop.pid_alive(kid), 'the writer died with its scheduler — test proves nothing')

        second = s.run('run', '--arc', s.arc, '--track', 'B', '--round', '1', '--kind', 'write',
                       '--name', 'second', '--tree', repo, '--max-queue', '3', '--', *touch(m, 'second'))
        self.assertEqual(second.returncode, loop.RC_LOCK,
                         f'a second writer was let into a tree with a live writer in it: {second.stdout}{second.stderr}')
        self.assertFalse(os.path.exists(os.path.join(m, 'second.started')), 'the second writer ran anyway')

        # control: the lock is held by the CHILD, not leaked forever — it frees the moment it exits
        open(rel, 'w').close()
        for _ in range(400):
            if not loop.pid_alive(kid):
                break
            time.sleep(0.05)
        self.assertFalse(loop.pid_alive(kid), 'the orphaned writer never exited')
        third = s.run('run', '--arc', s.arc, '--track', 'B', '--round', '1', '--kind', 'write',
                      '--name', 'third', '--tree', repo, '--max-queue', '20', '--', *touch(m, 'third'))
        self.assertEqual(third.returncode, 0, third.stdout + third.stderr)
        self.assertTrue(os.path.exists(os.path.join(m, 'third.started')))

    def test_a_forwarded_signal_reaches_the_childs_grandchildren(self):
        """`send_signal` reaches the direct child only — the work usually lives one level down.

        A forwarded TERM killed the `sh` and left codex's own helpers (or a vitest worker pool)
        running under a tree lock that release() was about to drop: unsupervised writers in a tree
        the scheduler had just declared free. Signalling the process GROUP reaches them, which is
        why the child is started in its own session.
        """
        s = sbx(self)
        repo, _ = s.git_repo()
        m = mdir_of(s)
        # a child that backgrounds a grandchild, then waits — TERM to the child alone orphans it
        # `$!` (the background job's pid), NOT `$$` inside a subshell — POSIX sh expands `$$` to the
        # PARENT shell even there, so an earlier version of this test watched the direct child and
        # passed under both implementations.
        kid = ['sh', '-c', f'sleep 60 & echo $! > "{m}/gc.pid"; '
                           f'touch "{m}/gc.started"; touch "{m}/impl.started"; wait']
        p = s.start('run', '--arc', s.arc, '--track', 'A', '--round', '1', '--kind', 'other',
                    '--name', 'impl', '--tree', repo, '--', *kid)
        wait_path(os.path.join(m, 'gc.started'), procs=(p,))
        with open(os.path.join(m, 'gc.pid')) as fh:
            gc = int(fh.read().strip())
        self.assertTrue(loop.pid_alive(gc))

        p.send_signal(signal.SIGTERM)
        p.wait(timeout=deadline(600.0, 30.0))
        for _ in range(200):
            if not loop.pid_alive(gc):
                break
            time.sleep(0.05)
        self.assertFalse(loop.pid_alive(gc),
                         'the grandchild outlived the signal that stopped its job (and its tree lock)')

    def test_a_subdir_takes_the_same_lock_as_its_toplevel(self):
        """One lock per WORKTREE. Keying on the passed path split it into two.

        `--tree /repo` and `--tree /repo/sub` are the same worktree, so a reader and a `--write`
        job could each hold "the tree lock" while the writer edited files under the reader — the
        exact corruption this scheduler exists to prevent. Measured before the fix: the two paths
        hashed to tree-5c1a7c92... and tree-189ab888...
        """
        s = sbx(self)
        repo, _ = s.git_repo()
        sub = os.path.join(repo, 'src', 'deep')
        os.makedirs(sub)
        self.assertEqual(loop.tree_lock_name(repo), loop.tree_lock_name(sub))
        self.assertEqual(loop.tree_lock_name(repo), loop.tree_lock_name(os.path.join(repo, '.')))
        # control: genuinely DIFFERENT worktrees must NOT collapse onto one lock, or every
        # snapshot read would serialise behind the live tree it was created to escape.
        other = os.path.join(s.dir, 'wt2')
        subprocess.run(['git', '-C', repo, 'worktree', 'add', '-q', '--detach', other],
                       check=True, capture_output=True)
        self.assertNotEqual(loop.tree_lock_name(repo), loop.tree_lock_name(other))
        # control: a path in no git tree keeps its own identity rather than borrowing one
        loose = os.path.join(s.dir, 'loose')
        os.makedirs(loose)
        self.assertNotEqual(loop.tree_lock_name(loose), loop.tree_lock_name(repo))

    def test_snapshot_reuse_refuses_a_dirty_worktree(self):
        """Being AT the sha is not the same as MATCHING it.

        The reuse path compared only HEAD, so a snapshot somebody had edited was handed back as the
        pinned revision and every lens read the edit while citing the sha. Round 3 (CORR2) reversed
        the old "untracked files are tolerated" contract: an untracked importable module or an
        AGENTS.md changes what every lens READS with HEAD unchanged, so it refuses too. The one
        carve-out is an install link this command made itself, and it is gated on a LIVE predicate
        (still a symlink, still resolving into the source repo) rather than on the entry's NAME.
        """
        s = sbx(self)
        repo, _ = s.git_repo()
        sha = subprocess.run(['git', '-C', repo, 'rev-parse', 'HEAD'],
                             capture_output=True, text=True).stdout.strip()
        args = ('snapshot', '--arc', s.arc, '--track', 'A', '--round', '1', '--repo', repo, '--sha', sha)
        path = s.run(*args).stdout.strip()
        self.assertTrue(os.path.isdir(path))
        self.assertEqual(s.run(*args).stdout.strip(), path, 'a clean snapshot must still be reused')

        with open(os.path.join(path, 'a.ts'), 'w') as fh:
            fh.write('export const a = 999; // MUTATED BY SOMEONE\n')
        dirty = s.run(*args)
        self.assertEqual(dirty.returncode, loop.RC_FAILCLOSED, dirty.stdout + dirty.stderr)
        self.assertIn('UNCOMMITTED TRACKED CHANGES', dirty.stdout + dirty.stderr)

        subprocess.run(['git', '-C', path, 'checkout', '--', '.'], check=True, capture_output=True)
        with open(os.path.join(path, 'lens-scratch.txt'), 'w') as fh:
            fh.write('a lens wrote this\n')
        untracked = s.run(*args)
        self.assertEqual(untracked.returncode, loop.RC_FAILCLOSED, untracked.stdout + untracked.stderr)
        self.assertIn('UNTRACKED', untracked.stdout + untracked.stderr)
        self.assertIn('lens-scratch.txt', untracked.stdout + untracked.stderr,
                      'the refusal must NAME the entry, or nobody can clear it')

        # POSITIVE CONTROL for the carve-out: with the scratch gone, an install LINK this command
        # made is still tolerated, so the refusal above is about pollution and not about the reuse
        # path having simply stopped working.
        subprocess.run(['git', '-C', path, 'clean', '-fdq'], check=True, capture_output=True)
        installed = sorted(loop.SNAPSHOT_INSTALLED)[0]
        os.mkdir(os.path.join(repo, installed))
        with open(os.path.join(repo, installed, 'marker.txt'), 'w') as fh:
            fh.write('the source repo copy\n')
        os.symlink(os.path.join(repo, installed), os.path.join(path, installed))
        clean = s.run(*args)
        self.assertEqual(clean.returncode, 0, clean.stdout + clean.stderr)
        self.assertEqual(clean.stdout.strip(), path, 'an install link must not refuse the reuse')

        # ...and the carve-out is the LIVE predicate, not the name: a real directory by the same
        # name is pollution like anything else. Derived from the same set as the control above, so
        # neither can drift onto a name the code no longer allowlists.
        os.remove(os.path.join(path, installed))
        os.mkdir(os.path.join(path, installed))
        with open(os.path.join(path, installed, 'evil.js'), 'w') as fh:
            fh.write('module.exports = 1\n')
        named = s.run(*args)
        self.assertEqual(named.returncode, loop.RC_FAILCLOSED, named.stdout + named.stderr)
        self.assertIn(installed, named.stdout + named.stderr)

    def test_tree_detects_in_place_change_of_already_dirty_file(self):
        """porcelain reads ` M f` for both bodies; only the diff content tells them apart."""
        s = sbx(self)
        repo, _ = s.git_repo()
        f = os.path.join(repo, 'f.txt')
        with open(f, 'w') as fh:
            fh.write('tracked\n')
        subprocess.run(['git', '-C', repo, 'add', 'f.txt'], check=True, capture_output=True)
        subprocess.run(['git', '-C', repo, 'commit', '-qm', 'f'], check=True, capture_output=True)
        with open(f, 'w') as fh:
            fh.write('aaaa\n')   # dirty BEFORE the reader starts
        before = subprocess.run(['git', '-C', repo, 'status', '--porcelain'], capture_output=True, text=True).stdout
        out = os.path.join(s.dir, 'v.json')
        r = s.run('run', '--arc', s.arc, '--track', 'A', '--round', '1', '--kind', 'other', '--name', 'mv', '--tree', repo, '--out', out,
                  '--', 'sh', '-c', f'echo verdict > {out}; printf "bbbb\\n" > {f}')
        after = subprocess.run(['git', '-C', repo, 'status', '--porcelain'], capture_output=True, text=True).stdout
        self.assertEqual(before, after, 'fixture: porcelain must be identical for the test to mean anything')
        self.assertEqual(r.returncode, loop.RC_FAILCLOSED, r.stderr)
        self.assertTrue(os.path.exists(out + '.tree-moved'))

    def test_reader_queued_behind_a_writer_reads_the_settled_tree(self):
        """A writer holding the tree commits B while a reader is queued; the reader then runs on B
        and must NOT be quarantined — the snapshot has to be taken once the lock is held.

        The writer commits AFTER the reader is already queued, and that ordering is the whole test.
        An earlier version committed first and then waited, so the tree was identical at both
        candidate snapshot points and the property was unobservable: a mutant moving the snapshot
        before the lock survived, and the mutant that DELETED the snapshot line was killed only by
        the NameError it caused downstream — a crash, not the invariant.
        """
        s = sbx(self)
        repo, _ = s.git_repo()
        m = mdir_of(s)
        wcmd = ['sh', '-c', f'touch "{m}/w.started"; '
                            f'i=0; while [ ! -e "{m}/release" ] && [ $i -lt 600 ]; do sleep 0.05; i=$((i+1)); done; '
                            f'echo b > "{repo}/b.txt"; git -C "{repo}" add b.txt; '
                            f'git -C "{repo}" -c user.email=t@t -c user.name=t commit -qm b']
        pw = s.start('run', '--arc', s.arc, '--track', 'A', '--round', '1', '--kind', 'write', '--name', 'w', '--tree', repo, '--', *wcmd)
        wait_path(os.path.join(m, 'w.started'), procs=(pw,))
        out = os.path.join(s.dir, 'v.json')
        pr = s.start('run', '--arc', s.arc, '--track', 'A', '--round', '1', '--kind', 'other', '--name', 'rd', '--tree', repo, '--out', out,
                     '--', 'sh', '-c', f'echo verdict > {out}')
        wait_event(s.arc, lambda ev: ev.get('ev') == 'queued' and ev.get('name') == 'rd')
        time.sleep(0.3)
        open(os.path.join(m, 'release'), 'w').close()
        pw.wait(timeout=deadline(600.0, 30.0))
        pr.wait(timeout=deadline(600.0, 30.0))
        self.assertEqual(pw.returncode, 0, pw.stderr.read())
        self.assertEqual(pr.returncode, 0, pr.stderr.read())
        j = s.jobs()
        self.assertGreaterEqual(j['rd']['start'], j['w']['end'])
        self.assertFalse(j['rd']['tree_moved'], j['rd'])
        self.assertTrue(os.path.exists(out))
        st = wait_event(s.arc, lambda ev: ev.get('ev') == 'start' and ev.get('name') == 'rd')
        head = subprocess.run(['git', '-C', repo, 'rev-parse', 'HEAD'], capture_output=True, text=True).stdout.strip()
        self.assertEqual(st['reads_sha'], head, 'the reader must record the SHA it actually read (post-writer)')

    def test_tree_detects_in_place_change_of_untracked_file(self):
        s = sbx(self)
        repo, _ = s.git_repo()
        u = os.path.join(repo, 'notes.txt')
        with open(u, 'w') as fh:
            fh.write('aaaa\n')
        out = os.path.join(s.dir, 'v.json')
        r = s.run('run', '--arc', s.arc, '--track', 'A', '--round', '1', '--kind', 'other', '--name', 'mv', '--tree', repo, '--out', out,
                  '--', 'sh', '-c', f'echo verdict > {out}; sleep 0.05; printf "bbbb\\n" > {u}')
        self.assertEqual(r.returncode, loop.RC_FAILCLOSED, r.stderr)

    def test_tree_moved_during_read_fails_and_quarantines(self):
        s = sbx(self)
        repo, _ = s.git_repo()
        out = os.path.join(s.dir, 'v.json')
        r = s.run('run', '--arc', s.arc, '--track', 'A', '--round', '1', '--kind', 'other', '--name', 'mv', '--tree', repo, '--out', out,
                  '--', 'sh', '-c', f'echo verdict > {out}; touch {repo}/newfile')
        self.assertEqual(r.returncode, loop.RC_FAILCLOSED, r.stderr)
        self.assertFalse(os.path.exists(out))
        self.assertTrue(os.path.exists(out + '.tree-moved'))
        j = s.jobs()['mv']
        self.assertTrue(j['tree_moved'])
        self.assertIn('TREE MOVED', j['reason'])

    def test_tree_unmoved_control(self):
        s = sbx(self)
        repo, _ = s.git_repo()
        out = os.path.join(s.dir, 'v.json')
        r = s.run('run', '--arc', s.arc, '--track', 'A', '--round', '1', '--kind', 'other', '--name', 'ok', '--tree', repo, '--out', out,
                  '--', 'sh', '-c', f'echo verdict > {out}')
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertTrue(os.path.exists(out))
        self.assertFalse(s.jobs()['ok']['tree_moved'])

    def test_tree_head_change_is_a_move(self):
        s = sbx(self)
        repo, g = s.git_repo()
        r = s.run('run', '--arc', s.arc, '--track', 'A', '--round', '1', '--kind', 'other', '--name', 'hd', '--tree', repo,
                  '--', 'sh', '-c', 'cd "$0" && git -c user.email=t@t -c user.name=t commit -q --allow-empty -m bump', repo)
        self.assertEqual(r.returncode, loop.RC_FAILCLOSED, r.stderr)
        self.assertIn('HEAD', s.jobs()['hd']['reason'])

    def test_tree_not_a_repo_is_usage(self):
        s = sbx(self)
        r = s.run('run', '--arc', s.arc, '--track', 'A', '--round', '1', '--kind', 'other', '--tree', s.dir, '--', 'true')
        self.assertEqual(r.returncode, loop.RC_USAGE, r.stderr)


class TestVitestFailClosed(unittest.TestCase):
    def test_wide_without_checkpoint_is_refused_before_launch(self):
        s = sbx(self)
        r = s.run('run', '--arc', s.arc, '--track', 'A', '--round', '1', '--kind', 'vitest', '--', 'vitest', 'run', env={'VITEST_STUB_OUT': HAPPY})
        self.assertEqual(r.returncode, loop.RC_WIDE, r.stderr)
        self.assertIn('--checkpoint', r.stderr)
        self.assertEqual(s.jobs(), {}, 'a refused launch is not a job')

    def test_wide_with_checkpoint_runs_heavy_and_records_why(self):
        s = sbx(self)
        r = s.run('run', '--arc', s.arc, '--track', 'A', '--round', '1', '--kind', 'vitest', '--name', 'full', '--checkpoint', 'pre-merge',
                  '--', 'vitest', 'run', env={'VITEST_STUB_OUT': HAPPY})
        self.assertEqual(r.returncode, 0, r.stderr)
        j = s.jobs()['full']
        self.assertEqual((j['cpu'], j['checkpoint'], j['tests']), ('heavy', 'pre-merge', 3))

    def test_name_filter_zero_match_is_misarmed(self):
        s = sbx(self)
        r = s.run('run', '--arc', s.arc, '--track', 'A', '--round', '1', '--kind', 'vitest', '--name', 'nf',
                  '--', 'vitest', 'run', '-t', 'nothing', 'a.test.ts',
                  env={'VITEST_STUB_OUT': 'Test Files  1 passed (1)\nTests  0 passed | 3 skipped (3)'})
        self.assertEqual(r.returncode, loop.RC_FAILCLOSED, r.stderr)
        self.assertIn('MISARMED', s.jobs()['nf']['reason'])

    def test_no_capture_is_refused_for_vitest(self):
        """The zero-test gate is only possible if the scheduler can READ the child's output.

        `vitest_verdict` used to run under `if args.kind == 'vitest' and capture`, so `--no-capture`
        skipped it silently -- and vitest exits 0 when a name filter selects nothing, which is the
        one exit status this scheduler exists not to believe. The refusal is at ENTRY, before any
        job is ledgered, so there is no half-recorded run to reconcile.
        """
        s = sbx(self)
        r = s.run('run', '--arc', s.arc, '--track', 'A', '--round', '1', '--kind', 'vitest',
                  '--name', 'nc', '--no-capture', '--', 'vitest', 'run', '-t', 'nothing', 'a.test.ts',
                  env={'VITEST_STUB_OUT': 'Test Files  1 passed (1)\nTests  0 passed | 3 skipped (3)'})
        self.assertEqual(r.returncode, loop.RC_USAGE, r.stdout + r.stderr)
        self.assertIn('--no-capture', r.stderr)
        self.assertEqual(s.jobs(), {}, 'a refused launch is not a job')
        # The same command WITH capture is the positive control: the gate it protects does fire.
        gated = s.run('run', '--arc', s.arc, '--track', 'A', '--round', '1', '--kind', 'vitest',
                      '--name', 'nc2', '--', 'vitest', 'run', '-t', 'nothing', 'a.test.ts',
                      env={'VITEST_STUB_OUT': 'Test Files  1 passed (1)\nTests  0 passed | 3 skipped (3)'})
        self.assertEqual(gated.returncode, loop.RC_FAILCLOSED, gated.stdout + gated.stderr)
        self.assertIn('MISARMED', s.jobs()['nc2']['reason'])
        # --no-capture stays available to every other kind; this is a vitest-shaped refusal.
        other = s.run('run', '--arc', s.arc, '--track', 'A', '--round', '1', '--kind', 'other',
                      '--name', 'quiet', '--no-capture', '--', 'true')
        self.assertEqual(other.returncode, 0, other.stdout + other.stderr)

    def test_no_test_files_is_failclosed_unless_allowed(self):
        s = sbx(self)
        env = {'VITEST_STUB_OUT': 'No test files found, exiting with code 0'}
        r = s.run('run', '--arc', s.arc, '--track', 'A', '--round', '1', '--kind', 'vitest', '--name', 'none',
                  '--', 'vitest', 'related', '--run', 'x.ts', env=env)
        self.assertEqual(r.returncode, loop.RC_FAILCLOSED, r.stderr)
        self.assertIn('NO-TESTS', s.jobs()['none']['reason'])
        r = s.run('run', '--arc', s.arc, '--track', 'A', '--round', '1', '--kind', 'vitest', '--name', 'allowed', '--allow-no-tests',
                  '--', 'vitest', 'related', '--run', 'x.ts', env=env)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn('no-tests-allowed', s.jobs()['allowed']['reason'])

    def test_no_summary_at_all_is_failclosed(self):
        s = sbx(self)
        r = s.run('run', '--arc', s.arc, '--track', 'A', '--round', '1', '--kind', 'vitest', '--name', 'blank',
                  '--', 'vitest', 'run', 'a.test.ts', env={'VITEST_STUB_OUT': ''})
        self.assertEqual(r.returncode, loop.RC_FAILCLOSED, r.stderr)

    def test_red_child_stays_red(self):
        s = sbx(self)
        r = s.run('run', '--arc', s.arc, '--track', 'A', '--round', '1', '--kind', 'vitest', '--name', 'red',
                  '--', 'vitest', 'run', 'a.test.ts', env={'VITEST_STUB_OUT': HAPPY, 'VITEST_STUB_RC': '1'})
        self.assertEqual(r.returncode, 1, r.stderr)

    def test_happy_scoped_run_is_light_and_counted(self):
        s = sbx(self)
        r = s.run('run', '--arc', s.arc, '--track', 'A', '--round', '1', '--kind', 'vitest', '--name', 'ok',
                  '--', 'vitest', 'run', 'a.test.ts', env={'VITEST_STUB_OUT': HAPPY})
        self.assertEqual(r.returncode, 0, r.stderr)
        j = s.jobs()['ok']
        self.assertEqual((j['cpu'], j['tests'], j['rc']), ('light', 3, 0))
        self.assertTrue(os.path.isdir(os.path.join(s.arc, 'rounds', 'A', 'r1')))


class TestAffected(unittest.TestCase):
    def commit(self, g, repo, files):
        for f, body in files.items():
            with open(os.path.join(repo, f), 'a') as fh:
                fh.write(body)
        subprocess.run(g + ['add', '-A'], check=True)
        subprocess.run(g + ['commit', '-qm', 'change'], check=True)

    def test_include_uncommitted_adds_working_tree_and_untracked_files(self):
        """`--affected RANGE --include-uncommitted` is the flag that makes a scoped run see work
        that is not committed yet. It had no test and no mutant, so deleting the whole branch — the
        exact way a scoped run silently stops covering the edit you are about to review — was free.
        """
        s = sbx(self)
        repo, g = s.git_repo()
        self.commit(g, repo, {'a.ts': 'one\n'})
        self.commit(g, repo, {'b.ts': 'two\n'})
        with open(os.path.join(repo, 'b.ts'), 'a') as fh:
            fh.write('edited, not committed\n')
        with open(os.path.join(repo, 'c.ts'), 'w') as fh:
            fh.write('brand new, untracked\n')
        committed = loop.changed_files(repo, 'HEAD~1..HEAD', False)
        self.assertEqual(committed, ['b.ts'], 'the committed range alone')
        both = loop.changed_files(repo, 'HEAD~1..HEAD', True)
        self.assertEqual(both, ['b.ts', 'c.ts'],
                         'the modified file is not duplicated and the untracked one is included')
        # a renamed entry reports its DESTINATION — the `X -> Y` form of --porcelain
        subprocess.run(g + ['add', 'c.ts'], check=True, capture_output=True)
        subprocess.run(g + ['commit', '-qm', 'add c'], check=True, capture_output=True)
        subprocess.run(g + ['mv', 'c.ts', 'renamed.ts'], check=True, capture_output=True)
        self.assertIn('renamed.ts', loop.changed_files(repo, 'HEAD~1..HEAD', True))

    def test_scoped_related_run_over_changed_files(self):
        s = sbx(self)
        repo, g = s.git_repo()
        self.commit(g, repo, {'a.ts': '// more\n', 'a.test.ts': '// more\n', 'README.md': 'more\n'})
        argf = os.path.join(s.dir, 'args.txt')
        r = s.run('run', '--arc', s.arc, '--track', 'A', '--round', '1', '--kind', 'vitest', '--name', 'aff', '--cwd', repo,
                  '--affected', 'HEAD~1..HEAD', '--vitest-bin', 'vitest', env={'VITEST_STUB_OUT': HAPPY, 'VITEST_STUB_ARGS': argf})
        self.assertEqual(r.returncode, 0, r.stderr)
        with open(argf) as fh:
            self.assertEqual(fh.read().strip(), 'related --run a.test.ts a.ts')
        j = s.jobs()['aff']
        self.assertEqual(j['cpu'], 'light')
        self.assertEqual(j['affected'], ['a.test.ts', 'a.ts'])

    def test_config_change_escalates_to_a_checkpointed_wide_run(self):
        s = sbx(self)
        repo, g = s.git_repo()
        self.commit(g, repo, {'vitest.config.ts': 'export default {}\n'})
        argf = os.path.join(s.dir, 'args.txt')
        r = s.run('run', '--arc', s.arc, '--track', 'A', '--round', '1', '--kind', 'vitest', '--name', 'cfg', '--cwd', repo,
                  '--affected', 'HEAD~1..HEAD', '--vitest-bin', 'vitest', env={'VITEST_STUB_OUT': HAPPY, 'VITEST_STUB_ARGS': argf})
        self.assertEqual(r.returncode, 0, r.stderr)
        with open(argf) as fh:
            self.assertEqual(fh.read().strip(), 'run')
        j = s.jobs()['cfg']
        self.assertEqual(j['cpu'], 'heavy')
        self.assertTrue(j['checkpoint'].startswith('config-changed'), j)

    def test_no_source_change_is_failclosed_unless_allowed(self):
        s = sbx(self)
        repo, g = s.git_repo()
        self.commit(g, repo, {'README.md': 'docs only\n'})
        r = s.run('run', '--arc', s.arc, '--track', 'A', '--round', '1', '--kind', 'vitest', '--cwd', repo,
                  '--affected', 'HEAD~1..HEAD', '--vitest-bin', 'vitest', env={'VITEST_STUB_OUT': HAPPY})
        self.assertEqual(r.returncode, loop.RC_FAILCLOSED, r.stderr)
        r = s.run('run', '--arc', s.arc, '--track', 'A', '--round', '1', '--kind', 'vitest', '--cwd', repo, '--allow-no-tests',
                  '--affected', 'HEAD~1..HEAD', '--vitest-bin', 'vitest', env={'VITEST_STUB_OUT': HAPPY})
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertTrue(any(ev.get('ev') == 'note' and 'allow-no-tests' in ev.get('text', '') for ev in loop.ledger_read(s.arc)))


# ----------------------------------------------------------------- profiler + round gate
class TestProfileAttribution(unittest.TestCase):
    def synthetic(self, s, base):
        R = loop.record_job
        R(s.arc, 'A', 1, 'review', 'lens1', base + 0, base + 100, 0, cpu='none')
        R(s.arc, 'A', 1, 'vitest', 'suite1', base + 50, base + 200, 0, cpu='heavy', checkpoint='pre', reported=150.0)
        R(s.arc, 'A', 1, 'vitest', 'suite2', base + 120, base + 260, 0, cpu='heavy', checkpoint='post', reported=140.0, t_req=base + 110, queued_s=10.0)
        R(s.arc, 'B', 1, 'review', 'lensB', base + 150, base + 250, 0, cpu='none')
        R(s.arc, 'A', 2, 'review', 'lens2', base + 1000, base + 1100, 0, cpu='none')

    def test_round_windows_and_cross_track_overlap(self):
        s = sbx(self)
        base = time.time() - 20000
        self.synthetic(s, base)
        stray = os.path.join(s.arc, 'stray.log')
        with open(stray, 'w') as fh:
            fh.write('Duration  1.00s\n')
        os.utime(stray, (time.time() + 100, time.time() + 100))
        r = s.run('profile', '--arc', s.arc)
        self.assertEqual(r.returncode, 0, r.stderr)
        for label in ('track A round 1', 'track B round 1', 'track A round 2', 'whole arc'):
            self.assertIn(label, r.stdout)
        self.assertIn('[TRIGGERED] L7', r.stdout.split('== whole arc')[1])
        r1 = s.run('profile', '--arc', s.arc, '--round', 'A:1').stdout
        self.assertIn('lensB', r1, 'a B-track job overlapping the window is contention A:1 paid for')
        self.assertNotIn('stray.log', r1, 'an artifact outside the window is not in the round')
        self.assertIn('[quiet    ] L7', r1)
        r2 = s.run('profile', '--arc', s.arc, '--round', 'A:2').stdout
        self.assertNotIn('lensB', r2)
        self.assertNotIn('suite1', r2)
        self.assertIn('lens2', r2)

    def test_close_round_gate_and_disposition(self):
        s = sbx(self)
        base = time.time() - 20000
        self.synthetic(s, base)
        # round 2 review is refused while round 1 is open
        r = s.run('run', '--arc', s.arc, '--track', 'A', '--round', '2', '--kind', 'review', '--name', 'r2', '--', 'true')
        self.assertEqual(r.returncode, loop.RC_GATE, r.stderr)
        self.assertIn('close-round', r.stderr)
        r = s.run('close-round', '--arc', s.arc, '--track', 'A', '--round', '1')
        self.assertEqual(r.returncode, 0, r.stderr)
        levers = json.load(open(os.path.join(s.arc, 'rounds', 'A', 'r1', 'levers.json')))
        trig = {lv['id'] for lv in levers if lv['triggered']}
        self.assertIn('L2', trig, 'two heavy vitest runs in one round')
        self.assertNotIn('L7', trig)
        closes = [ev for ev in loop.ledger_read(s.arc) if ev.get('ev') == 'round-close']
        self.assertEqual(sorted(closes[-1]['triggered']), sorted(trig))
        # still refused: triggered levers lack a disposition
        r = s.run('run', '--arc', s.arc, '--track', 'A', '--round', '2', '--kind', 'review', '--name', 'r2', '--', 'true')
        self.assertEqual(r.returncode, loop.RC_GATE, r.stderr)
        self.assertIn('lever', r.stderr)
        # a disposition needs a note
        r = s.run('lever', '--arc', s.arc, '--track', 'A', '--round', '1', '--id', 'L2', '--state', 'landed', '--note', ' ')
        self.assertEqual(r.returncode, loop.RC_USAGE)
        for lid in sorted(trig):
            r = s.run('lever', '--arc', s.arc, '--track', 'A', '--round', '1', '--id', lid, '--state', 'declined', '--note', 'test disposition')
            self.assertEqual(r.returncode, 0, r.stderr)
        r = s.run('gate', '--arc', s.arc, '--track', 'A', '--round', '2')
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        r = s.run('run', '--arc', s.arc, '--track', 'A', '--round', '2', '--kind', 'review', '--name', 'r2', '--', 'true')
        self.assertEqual(r.returncode, 0, r.stderr)
        # track B is gated independently
        r = s.run('gate', '--arc', s.arc, '--track', 'B', '--round', '2')
        self.assertEqual(r.returncode, loop.RC_GATE)

    def test_close_round_with_nothing_ledgered_needs_empty_ok(self):
        s = sbx(self)
        r = s.run('close-round', '--arc', s.arc, '--track', 'Z', '--round', '3')
        self.assertEqual(r.returncode, loop.RC_FAILCLOSED)
        r = s.run('close-round', '--arc', s.arc, '--track', 'Z', '--round', '3', '--empty-ok')
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertTrue(loop.round_status(loop.ledger_read(s.arc), 'Z', 3)['closed'])

    def test_lever_before_close_is_refused(self):
        s = sbx(self)
        r = s.run('lever', '--arc', s.arc, '--track', 'A', '--round', '1', '--id', 'L1', '--state', 'landed', '--note', 'x')
        self.assertEqual(r.returncode, loop.RC_GATE)

    def test_gap_classification_in_profile(self):
        s = sbx(self)
        base = time.time() - 20000
        loop.record_job(s.arc, 'A', 1, 'review', 'a', base, base + 100, 0, cpu='none')
        loop.record_job(s.arc, 'A', 1, 'review', 'b', base + 4000, base + 4100, 0, cpu='none')

        def gap_row(out):
            lines = out.splitlines()
            heading = next(i for i, line in enumerate(lines) if 'gaps ≥ 30 min' in line)
            return lines[heading + 1]

        out = s.run('profile', '--arc', s.arc, '--round', 'A:1').stdout
        self.assertIn('unknown', gap_row(out))
        tl = os.path.join(s.dir, 'job', 'timeline.jsonl')
        with open(tl, 'w') as fh:
            fh.write(json.dumps(dict(at=loop.dt.datetime.fromtimestamp(base - 50, loop.dt.timezone.utc).isoformat(), state='working')) + '\n')
        out = s.run('profile', '--arc', s.arc, '--round', 'A:1').stdout
        self.assertIn('seat-silent', gap_row(out))
        with open(tl, 'a') as fh:
            fh.write(json.dumps(dict(at=loop.dt.datetime.fromtimestamp(base + 2000, loop.dt.timezone.utc).isoformat(), state='working', detail='editing spec')) + '\n')
        out = s.run('profile', '--arc', s.arc, '--round', 'A:1').stdout
        self.assertIn('seat-active', gap_row(out))
        self.assertIn('editing spec', gap_row(out))
        r = s.run('note', '--arc', s.arc, '--track', 'A', '--round', '1', 'waiting', 'on', 'the user')
        self.assertEqual(r.returncode, 0)
        # the note is stamped now (outside the synthetic gap) — so a declared class needs a note INSIDE the gap
        loop.ledger_append(s.arc, dict(ev='note', t=base + 2500, text='deliberate sleep'))
        out = s.run('profile', '--arc', s.arc, '--round', 'A:1').stdout
        self.assertIn('declared', gap_row(out))
        self.assertIn('deliberate sleep', gap_row(out))


class TestLegacyProfile(unittest.TestCase):
    def test_flat_dir_heuristics_and_unattributed(self):
        s = sbx(self)
        d = os.path.join(s.dir, 'flat')
        os.makedirs(d)
        later = time.time() + 120
        with open(os.path.join(d, 'r1.run.log'), 'w') as fh:
            fh.write('OpenAI Codex v0.146.0\nmodel: gpt-5.6-sol\nreasoning effort: high\n')
        with open(os.path.join(d, 'r1.verdict.json'), 'w') as fh:
            json.dump(dict(findings=[dict(severity='high'), dict(severity='low')]), fh)
        os.utime(os.path.join(d, 'r1.verdict.json'), (later, later))
        with open(os.path.join(d, 'suite.log'), 'w') as fh:
            fh.write('Test Files  5 passed (5)\nTests  40 passed (40)\nDuration  2.50s\n')
        os.utime(os.path.join(d, 'suite.log'), (later, later))
        with open(os.path.join(d, 'T1-tsc.log'), 'w') as fh:
            fh.write('\n')
        os.utime(os.path.join(d, 'T1-tsc.log'), (later, later))
        with open(os.path.join(d, 'big.log'), 'w') as fh:
            fh.write('Duration  2.50s\n')
        os.utime(os.path.join(d, 'big.log'), (time.time() + 5 * 3600, time.time() + 5 * 3600))
        r = s.run('profile', d)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn('gpt-5.6-sol', r.stdout)
        self.assertIn('high=1 low=1', r.stdout)
        self.assertIn('vitest', r.stdout)
        self.assertIn('tsc', r.stdout)
        self.assertIn('measurement-suspect', r.stdout)
        self.assertIn('[TRIGGERED] L7', r.stdout)
        self.assertIn('UNATTR', r.stdout)

    def test_profile_with_no_artifacts(self):
        s = sbx(self)
        r = s.run('profile', s.arc)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn('no timed artifacts', r.stdout)


class TestRecordJob(unittest.TestCase):
    def test_record_job_roundtrips_through_the_profiler_rows(self):
        s = sbx(self)
        t = time.time() - 100
        loop.record_job(s.arc, 'A', 1, 'mutant', 'mutants-x', t, t + 30, 0, cpu='light', mutants=3, unscoped=1, reported=27.0, queued_s=2.0)
        rows, _ = loop.rows_from_ledger(loop.ledger_read(s.arc))
        self.assertEqual(len(rows), 1)
        r = rows[0]
        self.assertEqual((r['kind'], r['mutants'], r['unscoped'], r['reported'], r['queued']), ('mutant', 3, 1, 27.0, 2.0))
        res = loop.analyze(rows)
        l3 = next(lv for lv in res['levers'] if lv['id'] == 'L3')
        self.assertTrue(l3['triggered'], 'one unscoped killed mutant triggers L3')


def main():
    argv = sys.argv[1:]
    prog = unittest.main(module=__name__, argv=[sys.argv[0]] + argv, exit=False, verbosity=1)
    res = prog.result
    failed = len(res.failures) + len(res.errors)
    passed = res.testsRun - failed - len(res.skipped)
    print(f'\nTest Files  {"1 failed" if failed else "1 passed"} (1)')
    print(f'Tests  {passed} passed' + (f' | {failed} failed' if failed else '') + (f' | {len(res.skipped)} skipped' if res.skipped else '') + f' ({res.testsRun})')
    return 1 if failed else 0


class TestLedgerArithmetic(unittest.TestCase):
    def _rows(self, events):
        rows, _ = loop.rows_from_ledger(events, t_now=10_000.0)
        return rows

    def test_round_window_opens_at_the_recorded_request(self):
        ev = [dict(ev='start', t=101.0, job='j1', track='A', round=1, kind='mutant', name='m', t_req=100.0, queued_s=21.0),
              dict(ev='end', t=150.0, job='j1', rc=0)]
        rows = self._rows(ev)
        self.assertEqual(rows[0]['t_req'], 100.0)
        self.assertEqual(loop.round_window(rows, 'A', 1), (100.0, 150.0))

    def test_backwards_clock_interval_is_invalid_not_negative(self):
        ev = [dict(ev='start', t=200.0, job='j1', track='A', round=1, kind='other', name='x'),
              dict(ev='end', t=100.0, job='j1', rc=0)]
        r = self._rows(ev)[0]
        self.assertEqual(r['span'], 0.0)
        self.assertEqual(r['end'], r['start'])
        self.assertIn('CLOCK WENT BACKWARDS', r['note'])
        self.assertEqual(loop.round_window([r], 'A', 1), (200.0, 200.0))

    def test_disposition_before_a_repeated_close_does_not_count(self):
        ev = [dict(ev='round-close', t=10.0, track='A', round=1, triggered=['L1']),
              dict(ev='lever', t=20.0, track='A', round=1, id='L1', state='landed', note='old'),
              dict(ev='round-close', t=20.0, track='A', round=1, triggered=['L1'])]
        st = loop.round_status(ev, 'A', 1)
        self.assertEqual(st['dispositioned'], set(), 'a disposition written before the latest close answers the OLD close')
        ev.append(dict(ev='lever', t=5.0, track='A', round=1, id='L1', state='landed', note='new, backwards clock'))
        st = loop.round_status(ev, 'A', 1)
        self.assertEqual(st['dispositioned'], {'L1'}, 'ledger order decides, not the timestamp')

    def test_ledger_append_retries_a_short_write(self):
        # preflight=False: this test asserts the ledger holds EXACTLY its two records.
        s = sbx(self, preflight=False)
        events = [dict(ev='first', t=1.25, text='alpha'),
                  dict(ev='second', t=2.5, text='omega')]
        real_write = loop.os.write
        calls = []

        def short_first(fd, buf):
            calls.append(len(buf))
            if len(calls) == 1:
                prefix = max(1, len(buf) // 3)
                self.assertLess(prefix, len(buf))
                return real_write(fd, buf[:prefix])
            return real_write(fd, buf)

        loop.os.write = short_first
        try:
            for event in events:
                loop.ledger_append(s.arc, event)
        finally:
            loop.os.write = real_write

        with open(loop.ledger_path(s.arc), 'rb') as fh:
            actual = fh.read()
        lines = actual.splitlines()
        # A splice shows as ONE line that no longer parses (`{"ev": "fir{"ev": "second"...`), so the
        # record count plus a successful parse of each line IS the no-splice assertion. The events
        # are not compared byte-for-byte against what the caller passed, because ledger_append
        # stamps `mono`/`coff` onto every record (LIFE6) — pinning the writer's own fields here
        # would make this test fail on any future stamp without saying anything about splicing.
        self.assertEqual(len(lines), 2, f'expected exactly two complete records, got {actual!r}')
        parsed = [json.loads(line) for line in lines]
        self.assertEqual([(p['ev'], p['t'], p['text']) for p in parsed],
                         [(e['ev'], e['t'], e['text']) for e in events],
                         'a short first write must not splice the next JSON event onto it')
        self.assertEqual(actual, ''.join(json.dumps(p, sort_keys=True) + '\n' for p in parsed).encode('utf-8'),
                         'the bytes on disk must be exactly the two records, with nothing repeated or lost')
        self.assertGreaterEqual(len(calls), 3, 'first event needed a retry and the second needed its own write')

    @staticmethod
    def row(**kw):
        """A profiler row with every key `analyze` reads, so a test names only what it varies.

        Written as a helper rather than a literal per test on purpose: a fixture that pins an
        operand it does not name is how a swept axis stops being swept.
        """
        r = dict(kind='other', start=0.0, end=0.0, span=0.0, reported=None, tests='', path='A/r1/x',
                 note='', source='ledger', track='A', round=1, queued=0.0, cpu='none', job='j',
                 checkpoint=None, rc=0, unscoped=0, mutants=0, t_req=None)
        r.update(kw)
        if r['t_req'] is None:
            r['t_req'] = r['start']
        if r['span'] == 0.0 and r['end'] > r['start']:
            r['span'] = r['end'] - r['start']
        return r

    def test_round_clipping_clips_the_queue_interval_too(self):
        """A wait is an interval, and it has to be clipped against the same window as the run.

        Measured before the fix: a job that waited 40 min before the round opened and ran 10 s
        inside it charged the round all 2400 s of queue, which alone trips L5 for a round that
        queued nothing. The mirror case is a job that waited INSIDE the round and ran after it —
        that one was dropped entirely, losing the wait it really did spend here.
        """
        w = (1000.0, 1100.0)
        # queued 1020 s, of which only the last 20 fall inside the round; then runs inside it
        before = self.row(path='A/r1/early-queue', t_req=0.0, queued=1020.0, start=1020.0, end=1030.0)
        # queued 100 s starting inside the round, then runs entirely after it
        after = self.row(path='A/r1/late-run', t_req=1050.0, queued=100.0, start=1150.0, end=1200.0)
        outside = self.row(path='A/r1/elsewhere', t_req=2000.0, queued=50.0, start=2050.0, end=2100.0)
        # RUNS in-round, but its whole wait happened before the round opened. It is kept (its run is
        # this round's activity) with a clipped queue of 0 — so the INFERRED-queue flag beside that
        # zero has to be cleared too, or L5 fires on a queue this round did not pay for. The flag and
        # the number are one fact and must be clipped together.
        stale_flag = self.row(path='A/r1/pre-round-wait', t_req=0.0, queued=500.0,
                              start=1010.0, end=1020.0, queued_inferred=True)
        clipped = loop.clip_rows([before, after, outside, stale_flag], w)
        by = {r['path']: r for r in clipped}
        self.assertEqual(round(by['A/r1/early-queue']['queued'], 6), 20.0,
                         'only the queue time inside the window belongs to this round')
        self.assertIn('A/r1/late-run', by, 'a job that queued in-round and ran after it still spent this round waiting')
        self.assertEqual(round(by['A/r1/late-run']['queued'], 6), 50.0)
        self.assertEqual(by['A/r1/late-run']['span'], 0.0, 'its RUN is not this round\'s timed activity')
        self.assertEqual(by['A/r1/late-run']['start'], by['A/r1/late-run']['end'])
        self.assertNotIn('A/r1/elsewhere', by, 'neither its run nor its wait touches the window')
        self.assertEqual(by['A/r1/pre-round-wait']['queued'], 0.0)
        self.assertFalse(by['A/r1/pre-round-wait']['queued_inferred'],
                         'a queue clipped away to nothing must not leave its flag behind for L5 to read')
        # and the arithmetic downstream moves with it: L5 sums the CLIPPED queue
        res = loop.analyze(clipped, w, title='t')
        self.assertEqual(round(res['queued'], 6), 70.0)
        l5 = next(lv for lv in res['levers'] if lv['id'] == 'L5')
        self.assertFalse(l5['triggered'], '70 s of in-round queue is not the 300 s that trips L5')
        # control: unclipped, the same rows read as 1170 s of queue and DO trip it
        res_raw = loop.analyze([before, after, outside], (0.0, 2100.0), title='t')
        self.assertEqual(round(res_raw['queued'], 6), 1170.0)
        self.assertTrue(next(lv for lv in res_raw['levers'] if lv['id'] == 'L5')['triggered'])

    def test_a_rows_span_always_equals_the_interval_it_is_drawn_from(self):
        """`busy` unions [start, end]; the totals table sums `span`. If they can disagree, a round
        reports more timed work than its own timeline can account for, and there is no interval for
        clip_rows to clip the excess against.

        The case that produced the disagreement: a log whose own `Duration` exceeds the lifetime of
        the FILE (opened after the process started). The duration is the measurement, so the start
        moves back to meet it — it is not discarded.
        """
        s = sbx(self)
        d = os.path.join(s.dir, 'logs')
        os.makedirs(d)
        p = os.path.join(d, 'suite.log')
        with open(p, 'w') as fh:
            fh.write('Duration  600.00s\n')
        t = time.time()
        os.utime(p, (t, t))          # a file seconds old carrying a ten-minute Duration
        rows, _ = loop.gather_rows(None, [d])
        self.assertEqual(len(rows), 1, rows)
        r = rows[0]
        self.assertEqual(r['reported'], 600.0, 'the run\'s own measurement is kept')
        for r in rows:
            self.assertAlmostEqual(r['span'], r['end'] - r['start'], places=6,
                                   msg=f"{r['path']}: span {r['span']} but interval {r['end'] - r['start']}")

    def test_round_profile_clips_cross_round_jobs(self):
        w = (1000.0, 1010.0)
        rows = [dict(kind='review', start=1000.0, end=1010.0, span=10.0, reported=None, tests='', path='A/r1/x', note='',
                     source='ledger', track='A', round=1, queued=0.0, cpu='none', job='j1', checkpoint=None, rc=0,
                     unscoped=0, mutants=0, t_req=1000.0),
                dict(kind='tsc', start=500.0, end=1500.0, span=1000.0, reported=None, tests='', path='B/r1/big', note='',
                     source='ledger', track='B', round=1, queued=0.0, cpu='heavy', job='j2', checkpoint=None, rc=0,
                     unscoped=0, mutants=0, t_req=500.0)]
        clipped = loop.clip_rows(rows, w)
        self.assertEqual([(r['start'], r['end']) for r in clipped], [(1000.0, 1010.0), (1000.0, 1010.0)])
        self.assertIn('clipped to the round', clipped[1]['note'])
        res = loop.analyze(clipped, w, title='t')
        self.assertGreaterEqual(res['wall'], res['busy'])
        self.assertEqual(res['wall'], 10.0)

    def test_busy_is_the_union_not_the_sum_and_not_the_window(self):
        """`assertGreaterEqual(wall, busy)` was the only assertion on the union, and a union that
        returns 0 — or one that returns the window — satisfies it. This fixture separates all three
        answers: overlapping intervals plus a gap make sum (10) != window (10) != union (8), so the
        two wrong implementations that coincide at 10 are both excluded by one number."""
        w = (1000.0, 1010.0)
        rows = [self.row(path='A/r1/a', start=1000.0, end=1004.0),
                self.row(path='A/r1/b', start=1002.0, end=1006.0),
                self.row(path='A/r1/c', start=1008.0, end=1010.0)]
        res = loop.analyze(rows, w, title='t')
        self.assertEqual(res['wall'], 10.0)
        self.assertEqual(res['busy'], 8.0, 'union of [1000,1006] and [1008,1010]')
        self.assertEqual(sum(r['span'] for r in rows), 10.0, 'the SUM coincides with the window — that is the point')

    def test_an_inferred_queue_trips_l5_by_a_field_not_by_a_word_in_its_note(self):
        """L5's second disjunct fires on any INFERRED queue, however small — a log whose own Duration
        is far shorter than the time its file existed waited for something the scheduler never saw.

        It used to read that off the note's `queued ...` prefix. A text match is not a property: any
        other note beginning with that word turned the lever on, and rewording the note (which is
        human-facing prose) would have turned it off with nothing to redden. The note is now free to
        say anything; the predicate reads the field that the inference itself set.
        """
        s = sbx(self)
        d = os.path.join(s.dir, 'logs')
        os.makedirs(d)
        p = os.path.join(d, 'slow.log')
        with open(p, 'w') as fh:
            fh.write('Duration  10.00s\n')
        t = time.time()
        # macOS st_birthtime is the real creation time and os.utime cannot move it, so a file made
        # to look long-lived must have its MTIME pushed forward, never its atime pulled back.
        os.utime(p, (t + 200, t + 200))   # existed 200 s, ran 10 s: 190 s of it waited
        rows, _ = loop.gather_rows(None, [d])
        r = next(x for x in rows if x['path'].endswith('slow.log'))
        self.assertTrue(r['queued_inferred'])
        self.assertGreater(r['queued'], 100)
        res = loop.analyze(rows, (r['start'], r['end']), title='t')
        self.assertTrue(next(lv for lv in res['levers'] if lv['id'] == 'L5')['triggered'])
        # the note is prose and carries no meaning: reword it and the lever must not move
        r2 = dict(r); r2['note'] = 'this row waited a while'
        res2 = loop.analyze([r2], (r['start'], r['end']), title='t')
        self.assertTrue(next(lv for lv in res2['levers'] if lv['id'] == 'L5')['triggered'],
                        'the lever followed the wording rather than the fact')
        # control: a row with no inferred queue at all leaves L5 quiet
        r3 = dict(r); r3['queued'] = 0.0; r3['queued_inferred'] = False
        res3 = loop.analyze([r3], (r['start'], r['end']), title='t')
        self.assertFalse(next(lv for lv in res3['levers'] if lv['id'] == 'L5')['triggered'])

    def test_l3_slow_per_mutant_boundary_for_scoped_rows(self):
        b = 100000.0
        for per_mutant, expected in ((9.9, False), (10.0, True), (10.1, True)):
            rows = [self.row(kind='mutant', start=b, end=b + per_mutant, reported=per_mutant,
                             mutants=1, unscoped=0)]
            result = loop.analyze(rows, (b, b + per_mutant), title='t')
            l3 = next(lv for lv in result['levers'] if lv['id'] == 'L3')
            self.assertEqual(l3['triggered'], expected, f'{per_mutant}s per scoped mutant')

    def test_l6_unattributed_percentage_boundary_without_a_big_gap(self):
        b = 100000.0
        window = (b, b + 2000.0)
        for unattributed, expected in ((1199.0, False), (1200.0, False), (1201.0, True)):
            busy = 2000.0 - unattributed
            rows = [self.row(start=b, end=b + busy)]
            result = loop.analyze(rows, window, title='t')
            self.assertEqual(result['gaps'], [], 'the percentage branch must stand alone')
            l6 = next(lv for lv in result['levers'] if lv['id'] == 'L6')
            self.assertEqual(l6['triggered'], expected, f'{unattributed / 20:.2f}% unattributed')

    def test_l1_solo_wait_percentage_boundary(self):
        b = 100000.0
        window = (b, b + 1000.0)
        for solo, expected in ((399.0, False), (400.0, False), (401.0, True)):
            rows = [self.row(kind='review', path='A/r1/long', start=b, end=b + 1000.0),
                    self.row(kind='review', path='A/r1/partner', start=b, end=b + 1000.0 - solo)]
            result = loop.analyze(rows, window, title='t')
            self.assertEqual(result['wait_union'], 1000.0)
            self.assertEqual(result['wait_alone'], solo)
            l1 = next(lv for lv in result['levers'] if lv['id'] == 'L1')
            self.assertEqual(l1['triggered'], expected, f'{solo / 10:.1f}% solo wait')

    def test_every_lever_predicate_fires_on_its_own_evidence_and_stays_quiet_without_it(self):
        """A truth table, both directions, for all seven levers.

        Only L2, L3 and L7 had any test at all; the rest were prose in a report nobody could redden.
        Each case is the MINIMAL row set that trips one lever, asserted to trip that lever and to
        leave the other six quiet — a lever that fires on everything is as useless as one that
        never fires, and only the both-directions form catches it."""
        b = 100000.0

        def levers_of(rows, window):
            return {lv['id']: lv['triggered'] for lv in loop.analyze(rows, window, title='t')['levers']}

        cases = {
            # L1: waits serialised — >40% of a >300s wait union had nothing else in flight
            'L1': ([self.row(kind='review', start=b, end=b + 1000)], (b, b + 1000)),
            # L2: two wide vitest runs
            'L2': ([self.row(kind='vitest', cpu='heavy', start=b, end=b + 10),
                    self.row(kind='vitest', reported=90.0, start=b + 20, end=b + 110)], (b, b + 110)),
            # L3: a killed mutant with no `test` name
            'L3': ([self.row(kind='mutant', start=b, end=b + 5, mutants=1, unscoped=1)], (b, b + 5)),
            # L4: a tsc run at or over 20s
            'L4': ([self.row(kind='tsc', start=b, end=b + 25)], (b, b + 25)),
            # L5: 300s of queue
            'L5': ([self.row(kind='other', t_req=b, queued=300.0, start=b + 300, end=b + 310)], (b, b + 310)),
            # L6: a gap of 30 min or more between timed artifacts
            'L6': ([self.row(kind='other', start=b, end=b + 10),
                    self.row(kind='other', start=b + 3000, end=b + 3010)], (b, b + 3010)),
            # L7: a timed artifact with no ledger row
            'L7': ([self.row(kind='other', source='dir', start=b, end=b + 60)], (b, b + 60)),
        }
        for lid, (rows, window) in cases.items():
            got = levers_of(rows, window)
            self.assertTrue(got[lid], f'{lid} did not fire on its own evidence: {rows}')
            for other, fired in got.items():
                if other != lid:
                    self.assertFalse(fired, f'{lid} evidence also fired {other} — the predicate is not specific')

        # the quiet direction: one short, scoped, ledgered, unqueued run trips nothing at all
        quiet = [self.row(kind='vitest', cpu='light', reported=5.0, start=b, end=b + 5)]
        self.assertEqual(set(k for k, v in levers_of(quiet, (b, b + 5)).items() if v), set(),
                         'a clean round must trigger no lever')

        # boundaries, one step either side, for every threshold that is a bare number
        self.assertFalse(levers_of([self.row(kind='tsc', start=b, end=b + 19.9)], (b, b + 19.9))['L4'])
        self.assertTrue(levers_of([self.row(kind='tsc', start=b, end=b + 20.0)], (b, b + 20.0))['L4'])
        one_wide = [self.row(kind='vitest', cpu='heavy', start=b, end=b + 10)]
        self.assertFalse(levers_of(one_wide, (b, b + 10))['L2'], 'one wide run is not a pattern')
        q_lo = [self.row(kind='other', t_req=b, queued=299.0, start=b + 299, end=b + 310)]
        self.assertFalse(levers_of(q_lo, (b, b + 310))['L5'])

        # L1 measures SOLO wait, so the state it asks for must read quiet. A fully parallel panel is
        # the fix landing, not waste — measured on this arc's own round 2, where three lenses ran
        # concurrently for 19m28s and L1 still said TRIGGERED, i.e. "land the lever you just landed".
        panel = [self.row(kind='review', start=b, end=b + 1000),
                 self.row(kind='review', start=b + 1, end=b + 1000),
                 self.row(kind='review', start=b + 2, end=b + 1000)]
        self.assertFalse(levers_of(panel, (b, b + 1000))['L1'],
                         'a parallel panel is the fixed state, not a serialised wait')
        # the mirror: a panel whose neighbours finish early leaves one lens blocking alone, and that
        # tail IS the waste L1 is for.
        tail = [self.row(kind='review', start=b, end=b + 1000),
                self.row(kind='review', start=b, end=b + 100)]
        self.assertTrue(levers_of(tail, (b, b + 1000))['L1'],
                        '900s of one lens blocking with an idle machine behind it is exactly L1')


class TestRefusedWaitSurvivesTheClock(unittest.TestCase):
    """The refusal MEASURES its wait; the profiler must read that measurement, not re-derive one.

    In a live test the monotonic figure and the wall difference agree to a few milliseconds, so
    swapping one for the other is invisible there -- and swapping them is exactly what a clock step
    punishes. Feeding the ledger by hand is the only way to drive the two apart: `queued_s` says
    the process waited 42 s, while the wall stamps around it say an hour, because the clock was
    corrected mid-wait. 42 s is the answer; the hour is an artifact of the correction.
    """

    def rows_for(self, refusal_extra):
        q = dict(ev='queued', t=1000.0, job='j1', track='A', round=1, kind='review', name='lens',
                 cpu='none', coff=0.0)
        end = dict(ev='refused', t=1000.0 + 3600.0, job='j1', track='A', round=1, kind='review',
                   name='lens', reason='lock not available', coff=3558.0)
        end.update(refusal_extra)
        rows, _ = loop.rows_from_ledger([q, end], t_now=1000.0 + 7200.0)
        self.assertEqual(len(rows), 1)
        return rows[0]

    def test_the_profiler_bills_the_measured_wait_not_the_wall_difference(self):
        r = self.rows_for(dict(queued_s=42.0))
        self.assertEqual(r['queued'], 42.0,
                         'the profiler re-derived the wait from two wall stamps taken under '
                         'different clocks instead of reading the measurement it was given')
        self.assertTrue(r['never_started'])

    def test_a_refusal_that_left_no_measurement_still_reports_a_wait(self):
        """Control: the fallback is reached and is not itself broken. A record with no `queued_s`
        (a legacy line, or a kill that never got to write one) must still show up as a wait rather
        than as zero, or a queued job would read as free and L5 would go quiet."""
        r = self.rows_for({})
        self.assertEqual(r['queued'], 3600.0)


class TestKindTupleSweeps(unittest.TestCase):
    """Three tuples decide scheduling behaviour by MEMBERSHIP, and nothing walked any of them.

    A tuple read by exactly one `in` test is the cheapest thing in this file to break: deleting a
    member changes no signature, raises nothing, and every existing test keeps passing because each
    happens to use a different member. Each sweep below walks `loop.KINDS` -- the closed universe --
    and names the expected members as a LITERAL, so both a dropped member and an added one fail.
    """

    WAIT = ('review', 'write', 'codex', 'ci')
    GATED = ('review', 'write', 'mutant')

    def test_every_wait_kind_and_only_a_wait_kind_counts_towards_the_serialised_wait_lever(self):
        # `codex` is in WAIT_KINDS but not in KINDS: it reaches `analyze` from the run-codex.sh
        # rows, not from `loop.py run`, so the universe swept here is KINDS + the tuple itself.
        universe = sorted(set(loop.KINDS) | set(loop.WAIT_KINDS))
        self.assertEqual(sorted(self.WAIT), sorted(loop.WAIT_KINDS),
                         'WAIT_KINDS changed: update this table and say in the commit why the new '
                         'member is (or is not) a blocking wait')
        fired = []
        for kind in universe:
            rows = [TestLedgerArithmetic.row(kind=kind, start=100000.0, end=101000.0)]
            res = loop.analyze(rows, (100000.0, 101000.0), title='t')
            l1 = {lv['id']: lv['triggered'] for lv in res['levers']}['L1']
            if l1:
                fired.append(kind)
            self.assertEqual(res['wait_union'] > 0, kind in self.WAIT,
                             f'{kind}: counted towards the wait union but is not a wait kind (or vice versa)')
        self.assertEqual(sorted(fired), sorted(self.WAIT),
                         'exactly the wait kinds may trigger L1 on one long lone run')

    def test_every_gated_kind_and_only_a_gated_kind_is_refused_before_the_round_gate_passes(self):
        self.assertEqual(sorted(self.GATED), sorted(loop.GATED_KINDS),
                         'GATED_KINDS changed: a kind added here must be one it is SAFE to refuse')
        s = sbx(self, preflight=False)
        repo, _ = s.git_repo()
        # An arc with no efficiency preflight recorded: the gate must hold for exactly the gated
        # kinds. The cheap kinds are deliberately NOT gated -- a tsc or a scoped vitest is how you
        # find out whether the round can be closed at all, so gating them would deadlock the arc.
        # Every run carries a checkpoint so the WIDE-vitest rule (which fires earlier, and is a
        # different refusal with a different exit code) cannot stand in for the gate here.
        for kind in loop.KINDS:
            # A `vitest` kind runs the stub so it reports a real passing summary: `true` exits 0
            # having run no test file, which is the fail-closed NO-TESTS refusal (rc 5) -- a third
            # rule that would otherwise stand in for the gate on exactly one member of the sweep.
            cmd = ('vitest', 'run') if kind == 'vitest' else ('true',)
            r = s.run('run', '--arc', s.arc, '--track', 'A', '--round', '1', '--kind', kind,
                      '--name', f'k-{kind}', '--tree', repo, '--checkpoint', 'gate sweep', '--',
                      *cmd, env={'VITEST_STUB_OUT': HAPPY})
            if kind in self.GATED:
                self.assertEqual(r.returncode, loop.RC_GATE, f'{kind}: {r.stdout}{r.stderr}')
                self.assertIn('GATE REFUSED', r.stdout + r.stderr)
            else:
                self.assertEqual(r.returncode, 0, f'{kind}: {r.stdout}{r.stderr}')

    def test_a_gap_spanning_a_clock_step_is_reported_unpriced_rather_than_billed(self):
        """A 1 h clock correction and 1 h of silence are the same two wall stamps.

        `if spans:` guards the whole reclassification, so `if False:` bills a clock correction to
        the seat as an hour of unexplained silence -- which is the single number this profiler is
        read for. Both directions here: same offset -> the gap keeps its ordinary class.
        """
        b = 100000.0
        gap = 3600.0

        def gaps_for(coff_a, coff_b):
            rows = [TestLedgerArithmetic.row(kind='tsc', start=b, end=b + 10, job='a', coff=coff_a),
                    TestLedgerArithmetic.row(kind='tsc', start=b + 10 + gap, end=b + 20 + gap, job='z', coff=coff_b)]
            return loop.analyze(rows, (b, b + 20 + gap), title='t')['gaps']

        stepped = gaps_for(0.0, 4000.0)
        self.assertEqual(len(stepped), 1, 'a gap of an hour must be reported at all')
        self.assertEqual(stepped[0]['cls'], 'clock-jump')
        self.assertIn('not a measurement', stepped[0]['evidence'])
        self.assertIn('+4000s', stepped[0]['evidence'], 'the gap must name the step it could not price')

        steady = gaps_for(0.0, 0.0)
        self.assertEqual(len(steady), 1, 'the control must reach the same gap, or it controls nothing')
        self.assertNotEqual(steady[0]['cls'], 'clock-jump',
                            'a steady clock must not have its gap written off as unpriced')


class TestSoloWait(unittest.TestCase):
    """`solo_wait` is the number L1 reads, so it is pinned directly and not only through the lever."""

    def test_solo_wait_counts_only_a_lone_wait_with_an_idle_machine_behind_it(self):
        self.assertEqual(loop.solo_wait([(0, 10)], []), 10.0, 'one wait, nothing else: all of it solo')
        self.assertEqual(loop.solo_wait([(0, 10), (0, 10)], []), 0.0,
                         'two waits covering each other are a panel, not a serialised wait')
        self.assertEqual(loop.solo_wait([(0, 10), (0, 4)], []), 6.0,
                         'only the tail after the second lens finished is solo')
        self.assertEqual(loop.solo_wait([(0, 10)], [(0, 10)]), 0.0,
                         'a wait running beside implementation work is not idle time')
        self.assertEqual(loop.solo_wait([(0, 10)], [(4, 6)]), 8.0,
                         'the machine is idle either side of the fix that overlapped it')
        self.assertEqual(loop.solo_wait([(0, 5), (5, 10)], []), 10.0,
                         'back-to-back waits touch but never overlap: both are solo')
        self.assertEqual(loop.solo_wait([], [(0, 10)]), 0.0)


class TestLivenessDeadlines(unittest.TestCase):
    """The suite's own waits used to be bare wall-clock literals, which measure the machine.

    Measured: 64 tests in 22 s alone and 114 s beside this skill's own mutate.py batch, and at that
    5x two lock tests failed on `wait_path`'s fixed 20 s ceiling with nothing wrong in the code.
    A ceiling large enough never to flake is too large to diagnose a hang, so the deadline stopped
    being the failure signal: a dead producer is.
    """

    def test_wait_path_fails_at_once_when_every_producer_has_exited(self):
        """The marker can never appear, so waiting for a clock is pure delay AND a worse message."""
        s = sbx(self)
        marker = os.path.join(s.dir, 'never.started')
        p = subprocess.Popen([sys.executable, '-c', 'import sys; print("boom", file=sys.stderr); sys.exit(7)'],
                             stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        p.wait(timeout=30)
        self.assertEqual(p.returncode, 7, 'the producer is structurally terminal before the wait begins')
        with self.assertRaises(AssertionError) as cm:
            wait_path(marker, procs=(p,))
        self.assertIn('every producer exited', str(cm.exception))
        self.assertIn('rc=7', str(cm.exception), 'the diagnosis must carry the exit status')
        self.assertIn('boom', str(cm.exception), 'and the stderr that explains it')

    def test_a_live_producer_is_waited_for_rather_than_timed_out(self):
        """The mirror: a slow-but-alive producer must NOT be failed early. Without this direction the
        fix above degenerates into 'fail whenever the marker is missing', which passes the test
        above and breaks every real wait."""
        s = sbx(self)
        marker = os.path.join(s.dir, 'late.started')
        p = subprocess.Popen([sys.executable, '-c',
                              f'import time,sys; time.sleep(0.6); open({marker!r}, "w").close(); sys.exit(0)'],
                             stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        self.addCleanup(p.wait)
        wait_path(marker, procs=(p,))          # must return normally, not raise
        self.assertTrue(os.path.exists(marker))

    def test_one_exited_producer_does_not_fail_a_second_live_producer(self):
        s = sbx(self)
        marker = os.path.join(s.dir, 'second.started')
        exited = subprocess.Popen([sys.executable, '-c', 'import sys; sys.exit(9)'],
                                  stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        live = subprocess.Popen([sys.executable, '-c',
                                 f'import time; time.sleep(0.6); open({marker!r}, "w").close()'],
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        self.addCleanup(live.wait)
        exited.wait(timeout=30)
        self.assertEqual(exited.returncode, 9)
        self.assertIsNone(live.poll(), 'the second producer must still be live when waiting begins')
        wait_path(marker, procs=(exited, live))
        self.assertTrue(os.path.exists(marker))

    def test_a_derived_deadline_moves_with_the_machine_and_never_below_its_floor(self):
        """A deadline is `scale x calibration`, floored. Pinning both directions is the point: a
        mutant that drops the scale reads the machine out of the answer, and one that drops the
        floor makes an idle machine's ~30 ms spawn produce a 12 s ceiling on a 30 s job."""
        keep = SPAWN[0]
        self.addCleanup(lambda: SPAWN.__setitem__(0, keep))
        SPAWN[0] = 0.02                        # idle: the floor governs
        self.assertEqual(deadline(400.0, 20.0), 20.0)
        self.assertEqual(deadline(600.0, 30.0), 30.0)
        SPAWN[0] = 0.35                        # measured while the mutant batch ran
        self.assertEqual(deadline(400.0, 20.0), 140.0, 'the ceiling must grow with the machine')
        self.assertEqual(deadline(600.0, 30.0), 210.0)

    def test_calibration_takes_exactly_three_observations_and_rejects_one_outlier(self):
        ticks = iter((0.0, 0.03, 10.0, 15.0, 20.0, 20.031))
        calls = []

        def fake_run(argv, capture_output):
            calls.append((argv, capture_output))

        value = calibrate_spawn(run=fake_run, clock=lambda: next(ticks))
        self.assertEqual(len(calls), 3, 'calibration requires exactly three spawn observations')
        self.assertAlmostEqual(value, 0.031, places=9,
                               msg='the median must reject the single five-second outlier')

    def test_the_sample_rule_rejects_one_outlier_and_keeps_its_floor(self):
        """The two decisions in the calibration that ARE observable, pinned on samples.

        Median-of-three, not max: one 5 s hiccup (a GC pause, a sibling suite starting) must not
        multiply every deadline in the file by 250. And the floor holds on a machine faster than it,
        so an idle box cannot shrink a backstop to nothing.
        """
        self.assertAlmostEqual(reduce_samples([0.03, 0.031, 5.0]), 0.031,
                               msg='one slow sample must not set the calibration')
        self.assertAlmostEqual(reduce_samples([5.0, 0.031, 0.03]), 0.031, msg='order must not matter')
        self.assertAlmostEqual(reduce_samples([0.001, 0.001, 0.001]), 0.02,
                               msg='faster than the floor still floors')
        self.assertAlmostEqual(reduce_samples([0.05, 0.06, 0.07]), 0.06,
                               msg='a genuinely slow machine moves the calibration')


# ------------------------------------------------ round 3: each fix's own killer test
class TestSnapshotUpdatingRunsTakeTheTree(unittest.TestCase):
    """CORR5. A test run that REWRITES snapshots is a writer, and the lock has to know it.

    `cpu_class` reads `-u` as an ordinary scoped run (it is: one file, cheap), so the CPU class
    cannot carry this fact. Before the fix `lock_modes` asked only `kind == 'write'`, so a
    snapshot-updating vitest took a SHARED tree lock and ran beside a reader whose whole contract
    is that the tree does not move underneath it — the reader's SHA assertion then failed and
    quarantined a job that had done nothing wrong, which is the fail-open direction turning into
    noise rather than safety.
    """

    def test_the_writes_tree_axis_is_swept_from_the_call_site(self):
        """Swept through `tree_writing` -> `lock_modes` exactly as cmd_run composes them.

        The flag set is DERIVED from loop.TREE_WRITING_FLAGS rather than named here, so a flag
        added to the module cannot be swept by this test only in the direction it already passes.
        """
        CI_ON = {'CI': '1'}

        def modes(kind, argv, has_tree=True, env=CI_ON):
            return loop.lock_modes(loop.cpu_class(kind, argv), has_tree,
                                   loop.tree_writing(kind, argv, env))

        scoped = ['npx', 'vitest', 'run', 'a.test.ts']
        self.assertFalse(loop.tree_writing('vitest', scoped, CI_ON))
        self.assertEqual(modes('vitest', scoped), ('sh', 'sh'),
                         'a plain scoped run under CI reads the tree and must not exclude other readers')

        # ROUND 4 (CORR1). The SAME command line off CI is a WRITER. Vitest's `update` default
        # resolves to `new` outside CI, so a run with no `-u` still writes an absent external or
        # inline snapshot the first time it meets one -- two of them took shared locks and could
        # write the same file. The environment is the axis, so it is swept from the call site in
        # both directions rather than left to whatever the test process inherited.
        self.assertTrue(loop.tree_writing('vitest', scoped, {}),
                        'off CI a plain run can still write a missing snapshot')
        self.assertEqual(modes('vitest', scoped, env={}), ('ex', 'sh'))
        for off in ('', '0', 'false', 'FALSE', 'no', 'off', '  '):
            self.assertTrue(loop.tree_writing('vitest', scoped, {'CI': off}),
                            f'CI={off!r} is how a runner spells NOT ci and is not proof of anything')
        for on in ('1', 'true', 'TRUE', 'yes', 'github'):
            self.assertFalse(loop.tree_writing('vitest', scoped, {'CI': on}), f'CI={on!r}')
        # ...and the CI escape reaches only vitest's snapshot default: an explicit -u still writes.
        self.assertTrue(loop.tree_writing('vitest', ['npx', 'vitest', 'run', '-u', 'a.test.ts'], CI_ON),
                        'CI does not un-write an explicit --update')

        # Both directions, because a sweep DERIVED from the set is blind to a member LEAVING it:
        # dropping '-u' shrank the loop to zero iterations of the flag it exists to police, and the
        # test still passed (measured — mutant M61 survived the first version of this assertion).
        # So the two spellings vitest itself accepts for snapshot updating are named as a FLOOR,
        # while the loop below still covers anything added to the set later.
        self.assertLessEqual({'-u', '--update'}, loop.TREE_WRITING_FLAGS,
                             "vitest's own snapshot-update spellings must both be in the swept set")
        for flag in sorted(loop.TREE_WRITING_FLAGS):
            for tok in (flag, f'{flag}=true'):
                argv = ['npx', 'vitest', 'run', tok, 'a.test.ts']
                self.assertTrue(loop.tree_writing('vitest', argv, CI_ON), tok)
                self.assertEqual(modes('vitest', argv), ('ex', 'sh'),
                                 f'{tok} rewrites snapshots and must hold the tree exclusively')

        # An UNRECOGNISED command line fails the same direction as cpu_class does: unknown means
        # it might write, and the safe answer is the exclusive lock.
        for unknown in (['npm', 'test'], ['make', 'test'], ['./bin/run-tests']):
            self.assertTrue(loop.tree_writing('vitest', unknown, CI_ON), unknown)
            self.assertEqual(modes('vitest', unknown), ('ex', 'ex'), unknown)

        # controls: the axis is the COMMAND, not the kind — and with no tree there is no tree lock
        self.assertTrue(loop.tree_writing('write', [], CI_ON), 'a write job writes by definition')
        for kind in ('review', 'mutant', 'tsc', 'ci', 'other'):
            self.assertFalse(loop.tree_writing(kind, ['npx', 'vitest', 'run', '-u', 'a.test.ts'], {}), kind)
        self.assertIsNone(modes('vitest', ['npx', 'vitest', 'run', '-u', 'a.test.ts'], has_tree=False)[0])

    def test_a_snapshot_updating_run_waits_while_a_plain_one_overlaps(self):
        """The live proof, with its own control in the same tree and the same holder.

        Both jobs are `--kind vitest` against the same worktree; the ONLY difference is `-u`. The
        plain run overlaps the reader; the updating run is still queued after the reader has held
        for 0.4 s, and starts only once the reader is gone.
        """
        s = sbx(self)
        repo, _ = s.git_repo()
        m = mdir_of(s)   # markers live outside the repo so they cannot move the tree themselves
        # CI=1 is what makes a plain run a READER: it is the one thing that stops vitest writing a
        # missing snapshot. The control needs it for the same reason a real read-only verification
        # run does, so the fixture and the documented escape are the same fact.
        env = dict(VITEST_STUB_OUT=HAPPY, CI='1')
        rd = s.start('run', '--arc', s.arc, '--track', 'A', '--round', '1', '--kind', 'other',
                     '--name', 'rd', '--tree', repo, '--', *hold(m, 'rd'))
        wait_path(os.path.join(m, 'rd.started'), procs=(rd,))

        plain = s.run('run', '--arc', s.arc, '--track', 'B', '--round', '1', '--kind', 'vitest',
                      '--name', 'plain', '--tree', repo, '--', 'vitest', 'run', 'a.test.ts', env=env)
        self.assertEqual(plain.returncode, 0, plain.stdout + plain.stderr)

        # ROUND 4 (CORR1) live: the SAME command line with CI cleared must NOT overlap the reader.
        # This is the half a call-site sweep cannot show -- that the decision actually reaches the
        # lock the scheduler takes -- and it is the exact pair the control above completes.
        noci = s.start('run', '--arc', s.arc, '--track', 'B', '--round', '1', '--kind', 'vitest',
                       '--name', 'noci', '--tree', repo, '--', 'vitest', 'run', 'a.test.ts',
                       env=dict(VITEST_STUB_OUT=HAPPY, CI=''))
        wait_event(s.arc, lambda ev: ev.get('ev') == 'queued' and ev.get('name') == 'noci')
        time.sleep(0.4)
        self.assertEqual([ev for ev in loop.ledger_read(s.arc)
                          if ev.get('ev') == 'start' and ev.get('name') == 'noci'], [],
                         'off CI a plain vitest run may write a snapshot and must wait for the reader')

        upd = s.start('run', '--arc', s.arc, '--track', 'B', '--round', '1', '--kind', 'vitest',
                      '--name', 'upd', '--tree', repo, '--', 'vitest', 'run', '-u', 'a.test.ts', env=env)
        wait_event(s.arc, lambda ev: ev.get('ev') == 'queued' and ev.get('name') == 'upd')
        time.sleep(0.4)   # the reader holds throughout: this is a structural wait, not a race
        started = [ev for ev in loop.ledger_read(s.arc)
                   if ev.get('ev') == 'start' and ev.get('name') == 'upd']
        self.assertEqual(started, [], 'a snapshot-updating run started while a reader held the tree')

        open(os.path.join(m, 'release'), 'w').close()
        rd.wait(timeout=deadline(600.0, 30.0))
        upd.wait(timeout=deadline(600.0, 30.0))
        noci.wait(timeout=deadline(600.0, 30.0))
        self.assertEqual(rd.returncode, 0, rd.stderr.read())
        self.assertEqual(upd.returncode, 0, upd.stderr.read())
        self.assertEqual(noci.returncode, 0, noci.stderr.read())
        j = s.jobs()
        self.assertLess(j['plain']['end'], j['rd']['end'], 'the control never overlapped the reader')
        for name in ('upd', 'noci'):
            self.assertGreaterEqual(j[name]['start'], j['rd']['end'], (name, j))
            self.assertGreaterEqual(j[name]['queued'], 0.4, (name, j))


class TestAdmissionIntoAClosedOrCorruptRound(unittest.TestCase):
    """LIFE2 + LIFE5. A closed round is sealed, and a ledger with a hole in it decides nothing."""

    def test_admission_decision_sweep(self):
        for closed in (False, True):
            for corrupt in (0, 1, 7):
                ok, msg = loop.admission_decision(closed, corrupt)
                self.assertEqual(ok, not closed and not corrupt, (closed, corrupt))
                self.assertEqual(bool(msg), not ok, 'a refusal with no reason cannot be acted on')
                if corrupt:
                    self.assertIn(str(corrupt), msg, 'the refusal must say HOW MANY records are bad')
                elif closed:
                    self.assertIn('CLOSED', msg)

    def test_a_closed_round_admits_nothing_and_the_next_one_admits(self):
        s = sbx(self)
        m = mdir_of(s)
        self.assertEqual(s.run('close-round', '--arc', s.arc, '--track', 'A', '--round', '1',
                               '--empty-ok').returncode, 0)
        late = s.run('run', '--arc', s.arc, '--track', 'A', '--round', '1', '--kind', 'other',
                     '--name', 'late', '--', *touch(m, 'late'))
        self.assertEqual(late.returncode, loop.RC_GATE, late.stdout + late.stderr)
        self.assertIn('CLOSED', late.stderr)
        self.assertFalse(os.path.exists(os.path.join(m, 'late.started')),
                         'a refused job must not run — the refusal is the whole point')
        self.assertNotIn('late', s.jobs(), 'a refused job must not be ledgered as started')
        # control: the SAME job into the next round runs, so the refusal is about the seal
        nxt = s.run('run', '--arc', s.arc, '--track', 'A', '--round', '2', '--kind', 'other',
                    '--name', 'next', '--', *touch(m, 'next'))
        self.assertEqual(nxt.returncode, 0, nxt.stdout + nxt.stderr)
        self.assertTrue(os.path.exists(os.path.join(m, 'next.started')))

    def test_a_corrupt_ledger_refuses_both_admission_and_closure(self):
        """Both directions of the same rule, and a repair that restores both.

        A truncated or interleaved record means the presence of a close — or of a terminal event
        for some job — cannot be established. Deciding either question over that hole is how a
        round gets closed on top of a job still holding a tree.
        """
        s = sbx(self)
        m = mdir_of(s)
        first = s.run('run', '--arc', s.arc, '--track', 'A', '--round', '1', '--kind', 'other',
                      '--name', 'ok', '--', *touch(m, 'ok'))
        self.assertEqual(first.returncode, 0, first.stdout + first.stderr)
        with open(loop.ledger_path(s.arc), 'rb') as fh:
            good = fh.read()

        with open(loop.ledger_path(s.arc), 'ab') as fh:
            fh.write(b'{"ev": "start", "job": "trunc\n')
        self.assertEqual(loop.ledger_corrupt(loop.ledger_read(s.arc)), 1)

        after = s.run('run', '--arc', s.arc, '--track', 'A', '--round', '1', '--kind', 'other',
                      '--name', 'after', '--', *touch(m, 'after'))
        self.assertEqual(after.returncode, loop.RC_GATE, after.stdout + after.stderr)
        self.assertIn('unparseable', after.stderr)
        self.assertFalse(os.path.exists(os.path.join(m, 'after.started')))
        closed = s.run('close-round', '--arc', s.arc, '--track', 'A', '--round', '1')
        self.assertEqual(closed.returncode, loop.RC_FAILCLOSED, closed.stdout + closed.stderr)
        self.assertIn('unparseable', closed.stderr)
        self.assertFalse(loop.round_status(loop.ledger_read(s.arc), 'A', 1)['closed'],
                         'a refused close must not have written a close record')

        # ...and the refusal is about the hole, not about this arc: repair it and both proceed
        with open(loop.ledger_path(s.arc), 'wb') as fh:
            fh.write(good)
        repaired = s.run('run', '--arc', s.arc, '--track', 'A', '--round', '1', '--kind', 'other',
                         '--name', 'after', '--', *touch(m, 'after'))
        self.assertEqual(repaired.returncode, 0, repaired.stdout + repaired.stderr)
        self.assertEqual(s.run('close-round', '--arc', s.arc, '--track', 'A', '--round', '1').returncode, 0)


class TestCloseRoundIsATransaction(unittest.TestCase):
    """LIFE4 + LIFE3. One close per round, and liveness that can see a child outliving its parent."""

    def test_a_second_close_is_refused_and_leaves_the_first_ones_artifacts(self):
        s = sbx(self)
        base = time.time() - 20000
        loop.record_job(s.arc, 'A', 1, 'review', 'a', base, base + 100, 0, cpu='none')
        rdir = os.path.join(s.arc, 'rounds', 'A', 'r1')
        self.assertEqual(s.run('close-round', '--arc', s.arc, '--track', 'A', '--round', '1').returncode, 0)
        def artifacts():
            out = {}
            for n in os.listdir(rdir):
                with open(os.path.join(rdir, n), 'rb') as fh:
                    out[n] = fh.read()
            return out

        before = artifacts()
        self.assertEqual(sorted(before), ['levers.json', 'profile.txt'],
                         'the atomic writes must leave no temp file behind')

        second = s.run('close-round', '--arc', s.arc, '--track', 'A', '--round', '1')
        self.assertEqual(second.returncode, loop.RC_FAILCLOSED, second.stdout + second.stderr)
        self.assertIn('already CLOSED', second.stderr)
        self.assertIn('lever', second.stderr, 'the refusal must name the route that IS still open')
        self.assertEqual(artifacts(), before,
                         'the refused close rewrote the first close\'s artifacts')
        closes = [ev for ev in loop.ledger_read(s.arc) if ev.get('ev') == 'round-close'
                  and ev.get('track') == 'A' and ev.get('round') == 1]
        self.assertEqual(len(closes), 1, 'a second close record makes the FIRST one non-authoritative')

    def test_close_round_sees_a_child_group_that_outlived_its_scheduler(self):
        """LIFE3. `kill -9` on the scheduler leaves the child running under the inherited locks.

        The liveness test used to be the scheduler pid alone, so this job read as dead:
        `--abandon-unfinished` closed the round over a live writer and the gate then admitted the
        next panel into a tree that was still being written.
        """
        s = sbx(self)
        repo, _ = s.git_repo()
        m = mdir_of(s)
        rel = os.path.join(m, 'release')
        holder = ['sh', '-c', f'echo $$ > "{m}/impl.pid"; touch "{m}/impl.started"; i=0; '
                              f'while [ ! -e "{rel}" ] && [ $i -lt 600 ]; do sleep 0.05; i=$((i+1)); done']
        pw = s.start('run', '--arc', s.arc, '--track', 'A', '--round', '1', '--kind', 'write',
                     '--name', 'impl', '--tree', repo, '--', *holder)
        wait_path(os.path.join(m, 'impl.pid'), procs=(pw,))
        with open(os.path.join(m, 'impl.pid')) as fh:
            kid = int(fh.read().strip())
        os.kill(pw.pid, signal.SIGKILL)
        pw.wait(timeout=deadline(600.0, 30.0))
        self.assertTrue(loop.pid_alive(kid), 'the child died with its scheduler — test proves nothing')

        live = s.run('close-round', '--arc', s.arc, '--track', 'A', '--round', '1')
        self.assertEqual(live.returncode, loop.RC_FAILCLOSED, live.stdout + live.stderr)
        self.assertIn('still RUNNING', live.stderr)
        self.assertIn('child group', live.stderr, 'the refusal must name WHAT is still alive')
        # --abandon-unfinished is for a job that is GONE; it may not talk over a live one
        forced = s.run('close-round', '--arc', s.arc, '--track', 'A', '--round', '1',
                       '--abandon-unfinished')
        self.assertEqual(forced.returncode, loop.RC_FAILCLOSED, forced.stdout + forced.stderr)
        self.assertIn('still RUNNING', forced.stderr)
        self.assertFalse(loop.round_status(loop.ledger_read(s.arc), 'A', 1)['closed'])

        open(rel, 'w').close()
        for _ in range(int(deadline(600.0, 30.0) / 0.05)):
            if not loop.pid_alive(kid):
                break
            time.sleep(0.05)
        self.assertFalse(loop.pid_alive(kid), 'the orphaned child never exited')
        done = s.run('close-round', '--arc', s.arc, '--track', 'A', '--round', '1',
                     '--abandon-unfinished', '--empty-ok')
        self.assertEqual(done.returncode, 0, done.stdout + done.stderr)
        close = [ev for ev in loop.ledger_read(s.arc) if ev.get('ev') == 'round-close'][-1]
        self.assertTrue(close['abandoned'], 'the close must RECORD that a job was abandoned')

    def test_a_start_without_a_child_is_never_abandonable_by_the_blanket_flag(self):
        """LIFE3b. Between `start` and `child` the ledger holds a pid and NO process group.

        A SIGKILL of the scheduler inside that window leaves a record whose liveness cannot be
        established at all: `job_alive` asks the scheduler pid (gone with the scheduler) and has no
        pgid to ask about, so it answers "dead" from the ABSENCE of evidence rather than from a
        signal. `--abandon-unfinished` used to compute the started-without-pgid set only on the
        branch it disabled, so passing the flag closed the round over exactly that record -- and
        the child it cannot see is holding the tree and CPU locks through inherited fds.
        """
        s = sbx(self)
        # The premise is PRODUCIBLE, not assumed: a real run's `start` carries a pid and no group,
        # and the `child` event that adds one is a second, later append that a kill can precede.
        ok = s.run('run', '--arc', s.arc, '--track', 'A', '--round', '1', '--kind', 'other',
                   '--name', 'quick', '--', 'true')
        self.assertEqual(ok.returncode, 0, ok.stdout + ok.stderr)
        start = [ev for ev in loop.ledger_read(s.arc) if ev.get('ev') == 'start'][0]
        self.assertIsNone(start.get('pgid'), 'a start event that already carried a group would '
                                             'make this whole failure mode unreachable')
        self.assertTrue(start.get('pid'), 'the start event must name the scheduler it can outlive')

        gone = subprocess.Popen(['true'])
        gone.wait()
        loop.ledger_append(s.arc, dict(ev='start', job='j-orphan', track='A', round=2, kind='write',
                                       name='impl', pid=gone.pid))

        plain = s.run('close-round', '--arc', s.arc, '--track', 'A', '--round', '2', '--empty-ok')
        self.assertEqual(plain.returncode, loop.RC_FAILCLOSED, plain.stdout + plain.stderr)
        forced = s.run('close-round', '--arc', s.arc, '--track', 'A', '--round', '2', '--empty-ok',
                       '--abandon-unfinished')
        self.assertEqual(forced.returncode, loop.RC_FAILCLOSED, forced.stdout + forced.stderr)
        self.assertIn('never a child', forced.stderr)
        self.assertIn('--abandon-unverifiable=impl', forced.stderr,
                      'the refusal must print the exact route that IS open')
        self.assertFalse(loop.round_status(loop.ledger_read(s.arc), 'A', 2)['closed'])

        wrong = s.run('close-round', '--arc', s.arc, '--track', 'A', '--round', '2', '--empty-ok',
                      '--abandon-unfinished', '--abandon-unverifiable=some-other-job')
        self.assertEqual(wrong.returncode, loop.RC_FAILCLOSED, wrong.stdout + wrong.stderr)
        self.assertFalse(loop.round_status(loop.ledger_read(s.arc), 'A', 2)['closed'],
                         'naming a DIFFERENT job must not cover this one')

        done = s.run('close-round', '--arc', s.arc, '--track', 'A', '--round', '2', '--empty-ok',
                     '--abandon-unfinished', '--abandon-unverifiable=impl')
        self.assertEqual(done.returncode, 0, done.stdout + done.stderr)
        close = [ev for ev in loop.ledger_read(s.arc)
                 if ev.get('ev') == 'round-close' and ev.get('round') == 2][-1]
        self.assertEqual(close['unverifiable'], ['j-orphan'],
                         'a close taken on an operator\'s word must SAY so in the record')


class TestClockDiscontinuity(unittest.TestCase):
    """LIFE6. A gap measured across a clock step is not a measurement, in either direction."""

    @staticmethod
    def rows(*offsets):
        return [dict(job=f'j{i}', start=float(i), coff=o) for i, o in enumerate(offsets)]

    def test_a_jump_is_found_in_both_directions_and_a_steady_clock_is_silent(self):
        self.assertEqual(loop.clock_discontinuity(self.rows(10.0, 10.0, 10.0)), [],
                         'one continuous clock has no jump to report')
        fwd = loop.clock_discontinuity(self.rows(10.0, 4010.0))
        self.assertEqual(len(fwd), 1)
        self.assertAlmostEqual(fwd[0]['delta'], 4000.0)
        self.assertEqual((fwd[0]['before'], fwd[0]['after'], fwd[0]['at']), ('j0', 'j1', 1.0))
        back = loop.clock_discontinuity(self.rows(4010.0, 10.0))
        self.assertEqual(len(back), 1, 'a clock set BACKWARDS is the same loss of ordering')
        self.assertAlmostEqual(back[0]['delta'], -4000.0)

    def test_the_tolerance_is_a_boundary_and_cannot_be_driven_negative(self):
        self.assertEqual(loop.clock_discontinuity(self.rows(0.0, 2.0)), [],
                         'exactly the tolerance is not yet a jump')
        self.assertEqual(len(loop.clock_discontinuity(self.rows(0.0, 2.001))), 1)
        self.assertEqual(loop.clock_discontinuity(self.rows(0.0, 0.0), tol_s=-5.0), [],
                         'a negative tolerance would make every identical offset a finding')

    def test_rows_without_an_offset_are_skipped_rather_than_guessed_at(self):
        mixed = [dict(job='a', start=0.0, coff=0.0), dict(job='b', start=1.0),
                 dict(job='c', start=2.0, coff=4000.0)]
        j = loop.clock_discontinuity(mixed)
        self.assertEqual([(e['before'], e['after']) for e in j], [('a', 'c')],
                         'a legacy record carries no evidence and must not break the chain')

    def test_the_sweep_follows_wall_ORDER_not_ledger_order(self):
        unsorted = [dict(job='late', start=9.0, coff=4000.0), dict(job='early', start=1.0, coff=0.0)]
        j = loop.clock_discontinuity(unsorted)
        self.assertEqual([(e['before'], e['after']) for e in j], [('early', 'late')])



class TestClockStepInsideOneRun(unittest.TestCase):
    """The longest window in an arc is one job, so that is where a clock step most likely lands.

    `rows_from_ledger` has always carried `coff_end` beside `coff`; until round 4 nothing read it,
    so a step during a 20-minute lens moved no offset the detector compared and the profiler billed
    the difference to the seat as real elapsed time.
    """

    def row(self, **kw):
        r = dict(kind='review', start=1000.0, end=1000.0 + 3600.0, span=3600.0, path='A/r1/lens',
                 job='j1', track='A', round=1, coff=0.0)
        r.update(kw)
        return r

    def test_a_clock_step_inside_one_long_run_is_seen(self):
        js = loop.clock_discontinuity([self.row(coff_end=4000.0)])
        self.assertEqual(len(js), 1, 'the step moved coff_end and nothing else; it must still be found')
        self.assertAlmostEqual(js[0]['delta'], 4000.0)
        self.assertEqual((js[0]['before'], js[0]['after']), ('A/r1/lens', 'A/r1/lens'),
                         'a step inside one run is attributed to that run on both sides')
        self.assertAlmostEqual(js[0]['at'], 1000.0 + 3600.0, msg='reported where it was observed: the end stamp')

    def test_a_run_whose_clock_never_moved_reports_nothing(self):
        """The control: the same row shape, same two stamps, offsets that agree."""
        self.assertEqual(loop.clock_discontinuity([self.row(coff_end=0.0)]), [])

    def test_a_row_that_never_recorded_an_end_offset_is_still_skipped_not_guessed(self):
        self.assertEqual(loop.clock_discontinuity([self.row()]), [])


class TestEveryMutantIsStillArmable(unittest.TestCase):
    """Can each mutant in the batteries still FIND the code it exists to break?

    `loop.stranded_mutant_anchors` is the rule; this class tests it on synthetic mutants where
    the right answer is arithmetic, and then runs it over the REAL batteries in the checkout.
    The synthetic half is what pins the rule (a copy of the source under mutation has no
    batteries beside it, so the real half cannot judge anything there); the real half is what
    turns a rewrite that strands a mutant into a red unit test instead of a MISARMED forty
    minutes into a battery.
    """

    BATTERIES = (('loop.mutants.json', 'loop.py'), ('loop_test.mutants.json', 'loop_test.py'))

    def test_a_mutant_whose_anchor_appears_once_is_armable(self):
        self.assertEqual(loop.stranded_mutant_anchors([dict(label='A', old='needle')], 'a needle b'), [])

    def test_a_mutant_whose_anchor_was_rewritten_away_is_reported(self):
        out = loop.stranded_mutant_anchors([dict(label='A', old='needle')], 'no such thing')
        self.assertEqual(len(out), 1)
        self.assertIn('A', out[0])
        self.assertIn('0 occurrence', out[0], 'the report must say WHICH way the anchor is bad')

    def test_a_mutant_whose_anchor_appears_twice_is_reported_too(self):
        out = loop.stranded_mutant_anchors([dict(label='A', old='needle')], 'needle needle')
        self.assertEqual(len(out), 1, 'a non-unique anchor rewrites every site, so the kill does '
                                      'not isolate the line the label names')
        self.assertIn('2 occurrence', out[0])

    def test_a_mutant_with_no_anchor_at_all_is_reported_as_matching_NOTHING(self):
        # '' is a substring of every string, so counting it reports len(src)+1 matches -- a number
        # that grows with the file and says nothing about the mutant. An empty anchor arms nothing,
        # so it must be reported as ZERO, which is also what makes the reported count actionable.
        out = loop.stranded_mutant_anchors([dict(label='A', old='')], 'xyz')
        self.assertEqual(len(out), 1, 'an empty anchor must never read as armable')
        self.assertIn('0 occurrence', out[0],
                      'an empty anchor matches nothing; reporting len(src)+1 would be a count of the file')

    def test_the_real_batteries_all_still_arm(self):
        stranded = []
        for battery, source in self.BATTERIES:
            bpath = os.path.join(HERE, battery)
            spath = os.path.join(HERE, source)
            if not os.path.exists(bpath):
                # A mutation COPY holds only the sources mutate.py copied, never the batteries.
                # There is no checkout there to scan, so skip LOUDLY rather than pass -- a skip is
                # visible in the runner's output, and the shell suite pins that an in-repo run
                # reports these as PASSED, never skipped.
                self.skipTest('no %s beside %s -- not a checkout (mutation copy?)' % (battery, source))
            with io.open(bpath, encoding='utf-8') as fh:
                mutants = json.load(fh)
            with io.open(spath, encoding='utf-8') as fh:
                src = fh.read()
            self.assertTrue(mutants, '%s is empty -- an empty battery satisfies every check vacuously' % battery)
            stranded += ['%s :: %s' % (battery, line) for line in loop.stranded_mutant_anchors(mutants, src)]
        self.assertEqual(stranded, [], 'these mutants can no longer arm the code they name:\n  '
                                       + '\n  '.join(stranded))

    def test_every_real_mutant_actually_changes_its_source(self):
        inert = []
        for battery, _source in self.BATTERIES:
            bpath = os.path.join(HERE, battery)
            if not os.path.exists(bpath):
                self.skipTest('no %s -- not a checkout (mutation copy?)' % battery)
            with io.open(bpath, encoding='utf-8') as fh:
                for m in json.load(fh):
                    if m['new'] == m['old']:
                        inert.append('%s :: %s' % (battery, m['label']))
        self.assertEqual(inert, [], 'a mutant whose replacement equals its original arms nothing and '
                                    'is reported SURVIVED for a reason unrelated to the tests')

    def test_every_real_mutant_names_an_expectation_and_a_test_to_judge_it_by(self):
        malformed = []
        for battery, _source in self.BATTERIES:
            bpath = os.path.join(HERE, battery)
            if not os.path.exists(bpath):
                self.skipTest('no %s -- not a checkout (mutation copy?)' % battery)
            with io.open(bpath, encoding='utf-8') as fh:
                for m in json.load(fh):
                    if m.get('expect') not in ('killed', 'survived', 'unobservable'):
                        malformed.append('%s :: %s -- expect=%r' % (battery, m['label'], m.get('expect')))
                    elif m['expect'] == 'killed' and not (m.get('test') or '').strip():
                        malformed.append('%s :: %s -- expect=killed with no named test' % (battery, m['label']))
        self.assertEqual(malformed, [], 'a mutant with no expectation, or a kill with no named test, '
                                        'runs the WHOLE suite and passes on any red')


class TestPreflight(unittest.TestCase):
    """The round-1 efficiency gate: what it refuses, what it records, and what it must not wedge.

    Every test here builds its arc with `preflight=False` on purpose. If it used the default it
    would be asserting against an arc that is already preflighted, and the refusing path -- the
    whole point of the gate -- would stop being tested the moment the default changed.
    """

    def _ok(self, **over):
        a = dict(critical_path='the codex review of pipeline.ts blocks every fix',
                 parallel='the three lenses run concurrently in their own worktrees',
                 batch='tsc and vitest batch into one run; the mutants stay isolated',
                 scope='only pipeline.ts is re-reviewed; cli.ts was not touched',
                 stop='round 3 is the LAST panel for this region, then census-close',
                 drivers='mutation battery is 70% of wall-clock; cut it to the fold rules')
        a.update(over)
        return [x for f, v in a.items() for x in (f'--{f.replace("_", "-")}', v)]

    # ---------------------------------------------------------------- the gate refuses, then passes
    def test_a_fresh_arc_cannot_launch_a_review_until_it_is_preflighted(self):
        s = sbx(self, preflight=False)
        repo, _ = s.git_repo()
        r = s.run('run', '--arc', s.arc, '--track', 'A', '--round', '1', '--kind', 'review',
                  '--name', 'panel', '--tree', repo, '--', 'true')
        self.assertEqual(r.returncode, loop.RC_GATE, r.stdout + r.stderr)
        self.assertIn('preflight', r.stdout + r.stderr)
        self.assertEqual([ev for ev in loop.ledger_read(s.arc) if ev.get('ev') == 'queued'], [],
                         'a refused launch must not write a queued event -- it would grandfather itself on retry')

        p = s.run('preflight', '--arc', s.arc, *self._ok(), '--codex-unavailable', 'codex is down in this test')
        self.assertEqual(p.returncode, 0, p.stdout + p.stderr)
        r = s.run('run', '--arc', s.arc, '--track', 'A', '--round', '1', '--kind', 'review',
                  '--name', 'panel', '--tree', repo, '--', 'true')
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)

    def test_a_mutation_battery_is_gated_and_a_scoped_test_run_is_not(self):
        """Her trigger list names mutation batteries; a scoped vitest is not a process commitment."""
        s = sbx(self, preflight=False)
        repo, _ = s.git_repo()
        # The property is GATED vs NOT GATED, so it is asserted on the gate's own signals: the RC and
        # whether the launch reached the ledger. Asserting rc==0 for the ungated kinds instead would
        # couple this test to every unrelated guard downstream of the gate -- the WIDE-run checkpoint
        # rule and the fail-closed no-tests rule both fired here, neither having anything to do with
        # the preflight. --checkpoint is passed on every leg so the legs differ in KIND alone.
        for kind in ('mutant', 'vitest', 'tsc', 'other'):
            r = s.run('run', '--arc', s.arc, '--track', 'A', '--round', '1', '--kind', kind,
                      '--name', f'j-{kind}', '--tree', repo,
                      '--checkpoint', 'unit-test fixture: the command is `true`', '--', 'true')
            out = r.stdout + r.stderr
            queued = [ev for ev in loop.ledger_read(s.arc)
                      if ev.get('ev') == 'queued' and ev.get('name') == f'j-{kind}']
            if kind == 'mutant':
                self.assertEqual(r.returncode, loop.RC_GATE, f'{kind} was not gated: {out}')
                self.assertIn('preflight', out)
                self.assertEqual(queued, [], 'a gated refusal must not reach the ledger')
            else:
                self.assertNotEqual(r.returncode, loop.RC_GATE, f'{kind} was gated: {out}')
                self.assertNotIn('no efficiency preflight on record', out)
                self.assertEqual(len(queued), 1, f'{kind} should have passed the gate and queued: {out}')

    def test_a_job_refused_at_the_lock_does_not_grandfather_the_arc(self):
        """`queued` lands before the lock wait, so a lock-refused job left evidence it never earned."""
        q = dict(ev='queued', job='j1', kind='review')
        self.assertEqual(loop.paid_review_jobs([q, dict(ev='refused', job='j1')]), 0)
        self.assertEqual(loop.paid_review_jobs([q, dict(ev='start', job='j1'), dict(ev='refused', job='j1')]), 1,
                         'a job that STARTED and later failed did pay')
        self.assertEqual(loop.paid_review_jobs(
            [dict(ev='queued', job='m', kind='mutant'), dict(ev='start', job='m')]), 0,
            'a mutant is gated but never pays -- it is the expense the preflight asks about')

    def test_an_arc_already_running_review_jobs_is_grandfathered(self):
        """Derived from the ledger, never a list of arc names: live seat 0d22215b was exactly this."""
        self.assertEqual(loop.preflight_decision(1, False, 0)[0], False)
        self.assertEqual(loop.preflight_decision(1, False, 14)[0], True)
        self.assertEqual(loop.preflight_decision(1, True, 0)[0], True)
        self.assertEqual(loop.preflight_decision(2, False, 0)[0], True, 'later rounds are close-round\'s job')

    # ---------------------------------------------------------------- what is not an answer
    def test_a_filled_in_blank_is_not_an_answer(self):
        for bad in ('', '   ', 'n/a', 'N/A.', 'tbd', 'none', '-', 'same', 'yes'):
            self.assertIsNotNone(thin := loop.thin_answer(bad), f'{bad!r} was accepted as an answer')
            self.assertTrue(thin)
        self.assertIsNone(loop.thin_answer('the three lenses run concurrently in their own worktrees'))

    def test_six_copies_of_one_sentence_are_not_six_answers(self):
        same = {f: 'not applicable here' for f in loop.PREFLIGHT_FIELDS}
        why = loop.repeated_answers(same)
        self.assertIsNotNone(why, 'six identical answers cleared every field check')
        self.assertIn('different questions', why)
        self.assertIsNone(loop.repeated_answers({f: f'a distinct answer about {f}' for f in loop.PREFLIGHT_FIELDS}))
        # re-punctuating a paste must not defeat it
        near = {f: 'Not applicable here.' if i % 2 else 'not applicable here'
                for i, f in enumerate(loop.PREFLIGHT_FIELDS)}
        self.assertIsNotNone(loop.repeated_answers(near))

    def test_an_open_ended_stop_is_not_excused_by_a_stray_digit(self):
        """The bug: STOP_BOUND_RE ran FIRST, so any digit anywhere returned None before the ban."""
        for bad in ('repeat until no findings remain',
                    'repeat until no findings remain, across 3 tracks',
                    'keep going until it is clean (round 2 onward)',
                    'until only lows remain, 3 tracks',
                    'until converged'):
            self.assertIsNotNone(loop.unbounded_stop(bad), f'{bad!r} passed as a bounded stop')
        for good in ('another round needs a new production-risk finding',
                     'round 3 is the LAST panel for this region, then census-close',
                     'until only lows remain, max 5 rounds',
                     'at most 2 rounds, then ship'):
            self.assertIsNone(loop.unbounded_stop(good), f'{good!r} was refused')

    def test_the_stop_field_is_gated_on_the_bound_end_to_end(self):
        s = sbx(self, preflight=False)
        r = s.run('preflight', '--arc', s.arc, *self._ok(stop='repeat until no findings remain'),
                  '--codex-unavailable', 'down')
        self.assertNotEqual(r.returncode, 0)
        self.assertIn('bounded stopping condition', r.stdout + r.stderr)
        self.assertIsNone(loop.preflight_of(loop.ledger_read(s.arc)), 'a refused preflight must record nothing')

    # ---------------------------------------------------------------- the codex consultation
    def test_the_critique_is_recorded_or_its_absence_is(self):
        s = sbx(self, preflight=False)
        neither = s.run('preflight', '--arc', s.arc, *self._ok())
        self.assertNotEqual(neither.returncode, 0, 'skipping the critique silently must not be possible')

        empty = os.path.join(s.dir, 'empty.json')
        open(empty, 'w').close()
        r = s.run('preflight', '--arc', s.arc, *self._ok(), '--codex', empty)
        self.assertNotEqual(r.returncode, 0, 'a zero-byte file is not a process critique')

        both = s.run('preflight', '--arc', s.arc, *self._ok(), '--codex', empty, '--codex-unavailable', 'x')
        self.assertNotEqual(both.returncode, 0)

        r = s.run('preflight', '--arc', s.arc, *self._ok(), '--codex-unavailable', 'codex 500s all afternoon')
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        rec = loop.preflight_of(loop.ledger_read(s.arc))
        self.assertEqual(rec['codex_unavailable'], 'codex 500s all afternoon')
        self.assertIsNone(rec['codex'], 'an outage is RECORDED, never silently skipped')

    def test_a_second_preflight_supersedes_and_never_erases(self):
        s = sbx(self, preflight=False)
        first = s.run('preflight', '--arc', s.arc, *self._ok(), '--codex-unavailable', 'first')
        self.assertEqual(first.returncode, 0, first.stdout + first.stderr)
        second = s.run('preflight', '--arc', s.arc, *self._ok(drivers='the fold pipeline now dominates'),
                       '--codex-unavailable', 'second')
        self.assertEqual(second.returncode, 0, second.stdout + second.stderr)
        recs = [ev for ev in loop.ledger_read(s.arc) if ev.get('ev') == 'preflight']
        self.assertEqual(len(recs), 2, 'the ledger is append-only; a revision must not overwrite')
        self.assertEqual(loop.preflight_of(loop.ledger_read(s.arc))['drivers'], 'the fold pipeline now dominates')
        self.assertEqual(recs[1]['supersedes'], recs[0]['t'])

    def test_the_preflight_record_does_not_disturb_the_rest_of_the_ledger(self):
        s = sbx(self, preflight=False)
        r = s.run('preflight', '--arc', s.arc, *self._ok(), '--codex-unavailable', 'down')
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        evs = loop.ledger_read(s.arc)
        self.assertEqual(loop.ledger_corrupt(evs), 0)
        self.assertFalse(loop.round_status(evs, 'A', 1)['closed'])
        self.assertEqual(loop.paid_review_jobs(evs), 0, 'recording a preflight is not paying for a job')


class TestARefusalIsTerminal(unittest.TestCase):
    """CORR6. A job REFUSED while queued is finished, and its wait is a measurement.

    Only `end` counted as terminal, so a refusal left the queue open-ended: `rows_from_ledger` closed
    it against the PROFILER's clock, which grows every time the profile is re-run, and `round_window`
    closed the round at max(end) -- a zero-length point at the instant the job asked. Clipping then
    deleted the entire wait, so a 400 s queue read as 0 s and L5 stayed false: close-round recorded no
    triggered lever and the gate let the next panel in over the contention that caused the wait.
    """

    QUEUED = 1000.0
    REFUSED = 1400.0   # a 400 s wait, over L5's 300 s trigger on its own

    def events(self):
        skel = dict(job='j1', track='A', round=1, kind='review', name='rev', cpu='none')
        return [dict(ev='queued', t=self.QUEUED, **skel),
                dict(ev='refused', t=self.REFUSED, reason='max-queue', **skel)]

    def test_the_wait_is_measured_to_the_refusal_not_to_the_profilers_clock(self):
        # t_now is deliberately far in the future: an open-ended queue would grow with it, so the
        # SAME ledger read twice would report two different waits.
        for t_now in (self.REFUSED + 10.0, self.REFUSED + 100000.0):
            rows, _ = loop.rows_from_ledger(self.events(), t_now=t_now)
            self.assertEqual(len(rows), 1, rows)
            r = rows[0]
            self.assertAlmostEqual(r['queued'], self.REFUSED - self.QUEUED, msg=f't_now={t_now}')
            self.assertTrue(r['never_started'])
            self.assertEqual(r['span'], 0.0, 'a job that never ran must not join the busy union')
            self.assertIn('refused', r['note'], r['note'])

    def test_the_round_window_covers_the_wait_so_clipping_cannot_delete_it(self):
        rows, _ = loop.rows_from_ledger(self.events(), t_now=self.REFUSED + 10.0)
        w = loop.round_window(rows, 'A', 1)
        self.assertEqual(w, (self.QUEUED, self.REFUSED),
                         'the window collapsed onto the request instant, so the wait falls outside it')
        kept = loop.clip_rows(rows, w)
        self.assertEqual(len(kept), 1, 'the only row in the round was clipped away entirely')
        self.assertAlmostEqual(kept[0]['queued'], self.REFUSED - self.QUEUED)

    def test_the_refused_wait_reaches_the_lever_that_exists_to_see_it(self):
        rows, _ = loop.rows_from_ledger(self.events(), t_now=self.REFUSED + 10.0)
        w = loop.round_window(rows, 'A', 1)
        res = loop.analyze(loop.clip_rows(rows, w), w, title='t')
        l5 = next(lv for lv in res['levers'] if lv['id'] == 'L5')
        self.assertTrue(l5['triggered'],
                        'a 400 s measured queue must trigger L5 — the whole point of measuring it')
        self.assertIn('rev', l5['evidence'], l5['evidence'])

    def test_an_end_and_a_refusal_are_the_same_terminality(self):
        """The control: the same shape finished by `end` must give the same answer.

        If it did not, this test would be measuring the difference between two ledger shapes rather
        than the rule that both shapes are terminal.
        """
        skel = dict(job='j1', track='A', round=1, kind='review', name='rev', cpu='none')
        ended = [dict(ev='queued', t=self.QUEUED, **skel),
                 dict(ev='end', t=self.REFUSED, rc=1, **skel)]
        a, _ = loop.rows_from_ledger(self.events(), t_now=self.REFUSED + 5000.0)
        b, _ = loop.rows_from_ledger(ended, t_now=self.REFUSED + 5000.0)
        self.assertAlmostEqual(a[0]['queued'], b[0]['queued'])
        self.assertEqual(loop.round_window(a, 'A', 1), loop.round_window(b, 'A', 1))
        self.assertNotEqual(a[0]['note'], b[0]['note'], 'the two shapes must still be distinguishable')


if __name__ == '__main__':
    sys.exit(main())
