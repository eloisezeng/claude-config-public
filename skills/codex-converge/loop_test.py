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


def sbx(test):
    s = Sandbox()
    test.addCleanup(s.cleanup)
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

    def test_affected_plan(self):
        self.assertEqual(loop.affected_plan(['a.ts', 'vitest.config.ts']), ('wide', ['vitest.config.ts']))
        self.assertEqual(loop.affected_plan(['package-lock.json']), ('wide', ['package-lock.json']))
        self.assertEqual(loop.affected_plan(['.github/workflows/ci.yml']), ('wide', ['.github/workflows/ci.yml']))
        self.assertEqual(loop.affected_plan(['tsconfig.build.json']), ('wide', ['tsconfig.build.json']))
        self.assertEqual(loop.affected_plan(['a.ts', 'b.test.ts', 'README.md', 'x/y.mjs']), ('scoped', ['a.ts', 'b.test.ts', 'x/y.mjs']))
        self.assertEqual(loop.affected_plan(['README.md']), ('scoped', []))
        self.assertEqual(loop.affected_plan(['sub/vitest.config.ts']), ('scoped', ['sub/vitest.config.ts']),
                         'only a ROOT config escalates; a nested file named like one is a source file')


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

    def test_gate_cli_round_1_passes_without_history(self):
        s = sbx(self)
        r = s.run('gate', '--arc', s.arc, '--track', 'A', '--round', '1')
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)


    def test_gate_refuses_rounds_below_one(self):
        """`rnd <= 1` waved round 0 and every negative round through unconditionally.

        A typo'd `--round 0` therefore bought a free launch AND recorded itself against round -1,
        which nothing ever closes — the gate's whole job, silently skipped. Rounds are 1-based.
        """
        s = sbx(self)
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


def calibrate_spawn() -> float:
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
        t0 = time.time()
        subprocess.run([sys.executable, '-c', 'pass'], capture_output=True)
        samples.append(time.time() - t0)
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
        self.assertTrue(overlap(j['impl'], j['lens']), j)
        self.assertLess(j['lens']['queued'], 1.0, 'the review queued behind the write')

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
        pinned revision and every lens read the edit while citing the sha. Untracked files are
        tolerated on purpose — the node_modules symlink and a lens's own scratch are untracked and
        change nothing under review.
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
        clean = s.run(*args)
        self.assertEqual(clean.returncode, 0, clean.stdout + clean.stderr)
        self.assertEqual(clean.stdout.strip(), path, 'an untracked file must not refuse the reuse')

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
        out = s.run('profile', '--arc', s.arc, '--round', 'A:1').stdout
        self.assertIn('unknown', out)
        tl = os.path.join(s.dir, 'job', 'timeline.jsonl')
        with open(tl, 'w') as fh:
            fh.write(json.dumps(dict(at=loop.dt.datetime.fromtimestamp(base - 50, loop.dt.timezone.utc).isoformat(), state='working')) + '\n')
        out = s.run('profile', '--arc', s.arc, '--round', 'A:1').stdout
        self.assertIn('seat-silent', out)
        with open(tl, 'a') as fh:
            fh.write(json.dumps(dict(at=loop.dt.datetime.fromtimestamp(base + 2000, loop.dt.timezone.utc).isoformat(), state='working', detail='editing spec')) + '\n')
        out = s.run('profile', '--arc', s.arc, '--round', 'A:1').stdout
        self.assertIn('seat-active', out)
        self.assertIn('editing spec', out)
        r = s.run('note', '--arc', s.arc, '--track', 'A', '--round', '1', 'waiting', 'on', 'the user')
        self.assertEqual(r.returncode, 0)
        # the note is stamped now (outside the synthetic gap) — so a declared class needs a note INSIDE the gap
        loop.ledger_append(s.arc, dict(ev='note', t=base + 2500, text='deliberate sleep'))
        out = s.run('profile', '--arc', s.arc, '--round', 'A:1').stdout
        self.assertIn('declared', out)
        self.assertIn('deliberate sleep', out)


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
        t0 = time.time()
        with self.assertRaises(AssertionError) as cm:
            wait_path(marker, procs=(p,))
        elapsed = time.time() - t0
        self.assertLess(elapsed, 5.0, 'it waited on the clock instead of on the producer')
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

    def test_calibration_is_a_real_measurement_and_cheap_enough_to_take(self):
        """`profile every round` must not become the new bottleneck — so the calibration is three
        trivial spawns, and this pins BOTH that it costs about that and that it returns a plausible
        spawn cost rather than a constant."""
        t0 = time.time()
        v = calibrate_spawn()
        cost = time.time() - t0
        self.assertGreaterEqual(v, 0.02, 'clamped at a floor so a zero can never collapse a deadline')
        self.assertLess(v, 10.0)
        self.assertLess(cost, 15.0, 'the calibration itself must stay cheap')
        # it is a measurement, not a literal: a deliberately loaded probe must not read faster
        self.assertGreater(v, 0.0)

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


if __name__ == '__main__':
    sys.exit(main())
