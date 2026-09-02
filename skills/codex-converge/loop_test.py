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


def wait_path(path, timeout=20):
    t0 = time.time()
    while not os.path.exists(path):
        if time.time() - t0 > timeout:
            raise AssertionError(f'{path} did not appear within {timeout}s')
        time.sleep(0.02)


def wait_event(arc, pred, timeout=20):
    """Poll the ledger until an event satisfies pred (the ledger is the synchronisation point)."""
    t0 = time.time()
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
        if time.time() - t0 > timeout:
            raise AssertionError('ledger event not seen within %ss' % timeout)
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
        wait_path(os.path.join(m, 'a.started'))
        pb = s.start('run', '--arc', s.arc, '--track', 'A', '--round', '1', '--kind', kind_b, '--name', 'b', *extra.get('b', []), '--', *touch(m, 'b'))
        wait_event(s.arc, lambda ev: ev.get('ev') == 'queued' and ev.get('name') == 'b')
        time.sleep(hold_s)   # b is provably waiting throughout: a holds until we release it
        self.assertFalse(os.path.exists(os.path.join(m, 'b.started')), 'b ran while a held the lock')
        open(os.path.join(m, 'release'), 'w').close()
        pa.wait(timeout=30)
        pb.wait(timeout=30)
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
        wait_path(os.path.join(m, 'a.started'))
        pb = s.start('run', '--arc', s.arc, '--track', 'B', '--round', '1', '--kind', kind_b, '--name', 'b', *extra.get('b', []), '--', *hold(m, 'b'))
        wait_path(os.path.join(m, 'b.started'))   # b started while a still holds: structural overlap
        open(os.path.join(m, 'release'), 'w').close()
        pa.wait(timeout=30)
        pb.wait(timeout=30)
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
        wait_path(os.path.join(m, 'a.started'))
        r = s.run('run', '--arc', s.arc, '--track', 'A', '--round', '1', '--kind', 'tsc', '--name', 'b', '--max-queue', '0.3', '--', *touch(m, 'b'))
        t_refused = time.time()
        self.assertEqual(r.returncode, loop.RC_LOCK, r.stderr)
        self.assertFalse(os.path.exists(os.path.join(m, 'b.started')), 'a refused job must not run')
        open(os.path.join(m, 'release'), 'w').close()
        pa.wait(timeout=30)
        j = s.jobs()
        self.assertNotIn('b', j, 'a refused job must not be ledgered as started')
        self.assertGreaterEqual(j['a']['end'], t_refused, 'the holder was still holding when b was refused')
        ref = wait_event(s.arc, lambda ev: ev.get('ev') == 'refused' and ev.get('name') == 'b', timeout=1)
        self.assertIn('lock not available', ref['reason'])

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
        wait_path(os.path.join(m, 'rd.started'))
        pb = s.start('run', '--arc', s.arc, '--track', 'A', '--round', '1', '--kind', 'write', '--name', 'wr', '--tree', repo, '--', *touch(m, 'wr'))
        wait_event(s.arc, lambda ev: ev.get('ev') == 'queued' and ev.get('name') == 'wr')
        time.sleep(0.3)
        self.assertFalse(os.path.exists(os.path.join(m, 'wr.started')), 'the write ran while a reader held the tree')
        open(os.path.join(m, 'release'), 'w').close()
        pa.wait(timeout=30)
        pb.wait(timeout=30)
        self.assertEqual(pa.returncode, 0, pa.stderr.read())
        j = s.jobs()
        self.assertGreaterEqual(j['wr']['start'], j['rd']['end'], j)
        self.assertGreaterEqual(j['wr']['queued'], 0.3)

    def test_two_readers_of_same_tree_overlap(self):
        s = sbx(self)
        repo, _ = s.git_repo()
        m = mdir_of(s)
        pa = s.start('run', '--arc', s.arc, '--track', 'A', '--round', '1', '--kind', 'other', '--name', 'r1', '--tree', repo, '--', *hold(m, 'r1'))
        wait_path(os.path.join(m, 'r1.started'))
        pb = s.start('run', '--arc', s.arc, '--track', 'B', '--round', '1', '--kind', 'other', '--name', 'r2', '--tree', repo, '--', *hold(m, 'r2'))
        wait_path(os.path.join(m, 'r2.started'))
        open(os.path.join(m, 'release'), 'w').close()
        pa.wait(timeout=30)
        pb.wait(timeout=30)
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
        wait_path(os.path.join(m, 'impl.started'))
        pr = s.start('run', '--arc', s.arc, '--track', 'B', '--round', '1', '--kind', 'review', '--name', 'lens',
                     '--tree', snap, '--', *hold(m, 'lens'))
        # the review must START while the write still holds the live tree exclusively
        wait_path(os.path.join(m, 'lens.started'))
        self.assertTrue(os.path.exists(os.path.join(m, 'impl.started')))
        open(os.path.join(m, 'release'), 'w').close()
        pw.wait(timeout=30)
        pr.wait(timeout=30)
        self.assertEqual(pr.returncode, 0, pr.stderr.read())
        j = s.jobs()
        self.assertTrue(overlap(j['impl'], j['lens']), j)
        self.assertLess(j['lens']['queued'], 1.0, 'the review queued behind the write')

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
        and must NOT be quarantined — the snapshot has to be taken once the lock is held."""
        s = sbx(self)
        repo, _ = s.git_repo()
        m = mdir_of(s)
        wcmd = ['sh', '-c', f'touch "{m}/w.started"; echo b > "{repo}/b.txt"; git -C "{repo}" add b.txt; '
                            f'git -C "{repo}" -c user.email=t@t -c user.name=t commit -qm b; '
                            f'i=0; while [ ! -e "{m}/release" ] && [ $i -lt 600 ]; do sleep 0.05; i=$((i+1)); done']
        pw = s.start('run', '--arc', s.arc, '--track', 'A', '--round', '1', '--kind', 'write', '--name', 'w', '--tree', repo, '--', *wcmd)
        wait_path(os.path.join(m, 'w.started'))
        out = os.path.join(s.dir, 'v.json')
        pr = s.start('run', '--arc', s.arc, '--track', 'A', '--round', '1', '--kind', 'other', '--name', 'rd', '--tree', repo, '--out', out,
                     '--', 'sh', '-c', f'echo verdict > {out}')
        wait_event(s.arc, lambda ev: ev.get('ev') == 'queued' and ev.get('name') == 'rd')
        time.sleep(0.3)
        open(os.path.join(m, 'release'), 'w').close()
        pw.wait(timeout=30)
        pr.wait(timeout=30)
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


if __name__ == '__main__':
    sys.exit(main())
