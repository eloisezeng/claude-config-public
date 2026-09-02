#!/usr/bin/env python3
"""loop.py — scheduler, ledger, profiler and round gate for the codex-converge loop.

Why this exists (measured 2026-09-01/02 on one arc, `profile-arc.txt`): 7h34m of review
and `--write` waiting ran with NOTHING else in flight, two full vitest suites and a tsc
fought each other on one machine, and a 1h14m gap had no artifact at all.  The profiler
could SEE all of that after the fact, and every lever it printed stayed advice, because
the loop had no scheduler: each job was a background shell launched into a flat tmp/.
This module makes the levers mechanical.

  run           launch ONE job under (a) a CPU lock class so heavy suites serialise and
                light ones overlap, (b) a per-tree lock so a `--write` never runs under a
                reader of the same worktree, (c) a fail-closed test-count check so a run
                that executed nothing can never read as green, and (d) an append-only
                ledger attributing the job to arc → track → round.
  snapshot      a detached worktree pinned to a SHA, so a review of a frozen commit
                starts the moment the commit exists instead of behind the next `--write`.
  profile       where the wall-clock went — exact from the ledger; heuristic for artifacts
                launched around it, which are reported UNATTRIBUTED (lever L7) — with
                every gap ≥ 30 min classified from evidence the system actually has.
  close-round   profile one (track, round), write its levers, record the close.
  lever         disposition one TRIGGERED lever: landed | declined, with a note.
  gate          pass iff the previous round is closed and every TRIGGERED lever has a
                disposition.  `run --kind review|write` calls it, so the next panel
                cannot launch on top of an unmeasured round.
  note          record a declared reason for a stretch of wall-clock (a human wait, a
                deliberate sleep) so the profiler can class the gap as `declared`.

Fail-closed rules (each pinned in loop_test.py; mutants in tests/codex-loop.test.sh):
  * a vitest `-t` filter that selects 0 tests            → rc 5 MISARMED, never 0
  * a vitest run with no `Test Files` line, or `No test files found`, that exited 0
                                                          → rc 5 NO-TESTS (unless
                                                            --allow-no-tests, recorded)
  * a wide vitest run (whole suite / directory / --coverage) without --checkpoint REASON
                                                          → rc 4, not launched
  * a read job whose tree HEAD or status changed while it ran
                                                          → rc 5, output quarantined
  * the gate refuses (rc 6) rather than guessing when the previous round is not closed
  * a lock dir that cannot be created refuses (rc 7) rather than running unlocked

Lock classes (`cpu_class`): review / write / ci → none (a wait, not CPU); tsc → heavy;
vitest wide → heavy; vitest scoped (≤ 8 named files, `vitest related`) → light; mutant →
light; other → --cpu, default light.  A heavy job takes the CPU lock exclusive; a light
job shares it; heavy waits for every light and vice versa.  Locks are `flock(2)` files
under $CC_LOCK_DIR (default ~/.claude/ops/locks), so a holder that dies releases them.
Limitation: a vitest run that `codex --write` spawns INSIDE its sandbox is not wrapped
and therefore not locked — it shows up as queue-free contention on the profile.

Ledger: `<arc>/jobs.jsonl`, one JSON object per line, events start | end | note |
round-close | lever.  `<arc>` defaults to $CC_ARC, then $CLAUDE_JOB_DIR/tmp.
"""
from __future__ import annotations

import argparse
import datetime as dt
import fcntl
import glob
import hashlib
import json
import os
import re
import shlex
import signal
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
KINDS = ('review', 'write', 'vitest', 'tsc', 'mutant', 'ci', 'other')
WAIT_KINDS = ('review', 'write', 'codex', 'ci')
CPU_CLASSES = ('heavy', 'light', 'none')
LEVER_IDS = ('L1', 'L2', 'L3', 'L4', 'L5', 'L6', 'L7')
GAP_MIN_S = 1800
SCOPED_MAX_FILES = 8
LEDGER = 'jobs.jsonl'

RC_USAGE, RC_WIDE, RC_FAILCLOSED, RC_GATE, RC_LOCK = 2, 4, 5, 6, 7


# ----------------------------------------------------------------------------- time
def now() -> float:
    return time.time()


def hms(s: float) -> str:
    s = max(0.0, s)
    if s < 60:
        return f'{s:6.1f}s'
    m, sec = divmod(int(round(s)), 60)
    if m < 60:
        return f'{m:3d}m{sec:02d}s'
    h, m = divmod(m, 60)
    return f'{h}h{m:02d}m{sec:02d}s'


def hm(s: float) -> str:
    return hms(s).strip()


def clock(ts: float) -> str:
    return dt.datetime.fromtimestamp(ts).strftime('%m-%d %H:%M:%S')


def iso_to_epoch(s: str) -> float | None:
    try:
        s = s.strip()
        if s.endswith('Z'):
            s = s[:-1] + '+00:00'
        return dt.datetime.fromisoformat(s).timestamp()
    except (ValueError, AttributeError):
        return None


# ----------------------------------------------------------------- pure: test output
def tests_ran(out: str) -> int:
    """How many tests actually EXECUTED, from vitest's `Tests ...` summary line.

    Skipped tests do not count: a `-t` filter that matches nothing reports them as
    skipped and exits 0, and that must not be readable as a surviving mutant or a green
    run.  Returns 0 when no summary line is present (no run happened at all).
    """
    line = next((ln.strip() for ln in out.splitlines() if ln.strip().startswith('Tests ')), None)
    if line is None:
        return 0
    return sum(int(n) for n in re.findall(r'(\d+)\s+(?:passed|failed)', line))


def test_files_ran(out: str) -> int | None:
    """How many test FILES vitest ran, from its `Test Files ...` line; None when absent.

    `vitest related <file>` with no importing test prints `No test files found, exiting
    with code 0` and no summary at all — measured 2026-09-02 — so absence is the
    fail-open case and the caller must treat None as 0.
    """
    line = next((ln.strip() for ln in out.splitlines() if ln.strip().startswith('Test Files')), None)
    if line is None:
        return None
    return sum(int(n) for n in re.findall(r'(\d+)\s+(?:passed|failed)', line))


def no_tests_found(out: str) -> bool:
    return 'No test files found' in out


def vitest_verdict(rc: int, out: str, name_filtered: bool, allow_no_tests: bool) -> tuple[int, str]:
    """Turn a vitest child's exit status into the scheduler's, failing closed.

    A red child stays red (its own rc).  A GREEN child is believed only when the output
    proves something ran: a name filter that executed 0 tests is MISARMED; a run with no
    `Test Files` summary, or `No test files found`, is NO-TESTS — unless the caller
    recorded the decision with --allow-no-tests, in which case the child's rc stands
    and the reason says so.
    """
    if rc != 0:
        return rc, f'child rc={rc}'
    if name_filtered and tests_ran(out) == 0:
        return RC_FAILCLOSED, 'MISARMED: the name filter selected 0 tests (vitest exits 0 on a zero match)'
    files = test_files_ran(out)
    if no_tests_found(out) or files is None or files == 0:
        if allow_no_tests:
            return 0, 'no-tests-allowed: the caller recorded that no test file was expected'
        return RC_FAILCLOSED, 'NO-TESTS: exit 0 with no test file executed (vitest reports this as success)'
    return 0, f'{files} test file(s), {tests_ran(out)} test(s)'


# ------------------------------------------------------------- pure: cpu classification
VALUE_FLAGS = {
    '-t', '--testNamePattern', '-c', '--config', '-r', '--root', '--dir', '--reporter',
    '--outputFile', '--pool', '--maxWorkers', '--minWorkers', '--environment',
    '--project', '--shard', '--testTimeout', '--hookTimeout', '--exclude', '--mode',
    '--coverage.reporter', '--sequence.seed', '--retry', '--bail', '--maxConcurrency',
}
WIDE_FLAGS = {'--coverage', '--changed', '--watch', '-w'}
FILE_RE = re.compile(r'\.[cm]?[jt]sx?$')
GLOB_RE = re.compile(r'[*?\[{]')   # a glob selects an unbounded set of files: never light
VITEST_SUBCMDS = {'run', 'related', 'watch', 'dev', 'bench', 'list', 'typecheck', 'init'}


def vitest_shape(argv: list[str]) -> dict:
    """Classify a vitest command line: {sub, files, dirs, wide_flag, name_filter}."""
    argv = list(argv)
    vi = next((i for i, a in enumerate(argv) if a == 'vitest' or a.endswith('/vitest')), None)
    if vi is None:
        return dict(sub=None, files=[], dirs=[], wide_flag=False, name_filter=False, known=False)
    rest = argv[vi + 1:]
    sub = 'run'
    if rest and rest[0] in VITEST_SUBCMDS:
        sub = rest[0]
        rest = rest[1:]
    files, dirs = [], []
    wide_flag = name_filter = False
    skip = False
    for tok in rest:
        if skip:
            skip = False
            continue
        # `--flag=value` is one token: classify by the flag name, and its value is already attached
        flag, has_val = tok, False
        if tok.startswith('-') and '=' in tok:
            flag, _, _ = tok.partition('=')
            has_val = True
        if flag in ('-t', '--testNamePattern'):
            name_filter = True
        if flag in WIDE_FLAGS:
            wide_flag = True
        if tok.startswith('-'):
            if flag in VALUE_FLAGS and not has_val:
                skip = True
            continue
        (files if FILE_RE.search(tok) and not GLOB_RE.search(tok) else dirs).append(tok)
    return dict(sub=sub, files=files, dirs=dirs, wide_flag=wide_flag, name_filter=name_filter, known=True)


def has_name_filter(argv: list[str]) -> bool:
    return vitest_shape(argv)['name_filter']


def cpu_class(kind: str, argv: list[str], explicit: str | None = None) -> str:
    """The lock class a job takes.  Misreads fail towards `heavy` (more serialisation)."""
    if kind in ('review', 'write', 'ci'):
        return 'none'
    if kind == 'tsc':
        return 'heavy'
    if kind == 'mutant':
        return 'light'
    if kind == 'vitest':
        if argv[:2] in (['npm', 'test'], ['npm', 't'], ['npm', 'run']) or argv[:1] == ['npm']:
            return 'heavy'
        sh = vitest_shape(argv)
        if not sh['known']:
            return 'heavy'
        if sh['wide_flag'] or sh['sub'] in ('watch', 'dev', 'bench', 'typecheck', 'init'):
            return 'heavy'
        # `related` is NOT a free pass: its operands are source files and the same bounds apply
        # (nine operands, a directory, or no operand at all is a wide run).
        if sh['dirs'] or not sh['files']:
            return 'heavy'
        return 'light' if len(sh['files']) <= SCOPED_MAX_FILES else 'heavy'
    if explicit in CPU_CLASSES:
        return explicit
    return 'light'


def needs_checkpoint(kind: str, cpu: str, checkpoint: str | None) -> bool:
    return kind == 'vitest' and cpu == 'heavy' and not (checkpoint or '').strip()


CONFIG_RE = re.compile(
    r'^(vitest\.config\.[cm]?[jt]s|vitest\.workspace\.[cm]?[jt]s|vite\.config\.[cm]?[jt]s'
    r'|package(-lock)?\.json|tsconfig[^/]*\.json|\.github/workflows/[^/]+)$')


def affected_plan(changed: list[str]) -> tuple[str, list[str]]:
    """('wide', [config files]) when a test/tooling config changed, else ('scoped', files)."""
    cfg = [f for f in changed if CONFIG_RE.match(f)]
    if cfg:
        return 'wide', cfg
    return 'scoped', [f for f in changed if FILE_RE.search(f)]


# ------------------------------------------------------------------------- ledger
def arc_dir(explicit: str | None) -> str | None:
    d = explicit or os.environ.get('CC_ARC')
    if not d and os.environ.get('CLAUDE_JOB_DIR'):
        d = os.path.join(os.environ['CLAUDE_JOB_DIR'], 'tmp')
    return os.path.abspath(d) if d else None


def ledger_path(arc: str) -> str:
    return os.path.join(arc, LEDGER)


def ledger_append(arc: str, ev: dict) -> None:
    os.makedirs(arc, exist_ok=True)
    ev = dict(ev)
    ev.setdefault('t', now())
    line = json.dumps(ev, sort_keys=True) + '\n'
    fd = os.open(ledger_path(arc), os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o644)
    try:
        os.write(fd, line.encode('utf-8'))
    finally:
        os.close(fd)


def ledger_read(arc: str) -> list[dict]:
    p = ledger_path(arc)
    if not os.path.exists(p):
        return []
    out = []
    with open(p, encoding='utf-8', errors='replace') as fh:
        for ln in fh:
            ln = ln.strip()
            if not ln:
                continue
            try:
                out.append(json.loads(ln))
            except json.JSONDecodeError:
                out.append({'ev': 'corrupt', 'raw': ln[:200]})
    return out


def record_job(arc: str, track: str, rnd: int, kind: str, name: str, t_start: float, t_end: float,
               rc: int, **extra) -> str:
    """Ledger a job that ran outside `run` (mutate.py uses this): start + end events."""
    job = f'{track}.r{rnd}.{name}.{int(t_start * 1000)}'
    ledger_append(arc, dict(ev='start', t=t_start, job=job, track=track, round=rnd, kind=kind, name=name,
                            cpu=extra.pop('cpu', 'light'), t_req=extra.pop('t_req', t_start),
                            queued_s=extra.pop('queued_s', 0.0), **extra))
    ledger_append(arc, dict(ev='end', t=t_end, job=job, rc=rc, reason=extra.get('reason', '')))
    return job


# -------------------------------------------------------------------------- locks
def lock_dir() -> str:
    return os.environ.get('CC_LOCK_DIR') or os.path.expanduser('~/.claude/ops/locks')


def tree_lock_name(tree: str) -> str:
    real = os.path.realpath(tree)
    return 'tree-' + hashlib.sha1(real.encode('utf-8')).hexdigest()[:16] + '.lock'


class Locks:
    """Acquire the job's locks in a fixed order (tree, then cpu); release on exit.

    tree_mode / cpu_mode ∈ {'ex', 'sh', None}.  Uses flock(2): a holder that dies releases.
    """

    def __init__(self, tree: str | None, tree_mode: str | None, cpu_mode: str | None,
                 holder: str = '', max_queue_s: float | None = None):
        self.specs = []
        if tree and tree_mode:
            self.specs.append((os.path.join(lock_dir(), tree_lock_name(tree)), tree_mode))
        if cpu_mode:
            self.specs.append((os.path.join(lock_dir(), 'cpu-heavy.lock'), cpu_mode))
        self.holder = holder
        self.max_queue_s = max_queue_s
        self.fds: list[int] = []
        self.queued_s = 0.0

    def acquire(self) -> float:
        os.makedirs(lock_dir(), exist_ok=True)
        t0 = time.monotonic()
        for path, mode in self.specs:
            fd = os.open(path, os.O_RDWR | os.O_CREAT, 0o644)
            op = fcntl.LOCK_EX if mode == 'ex' else fcntl.LOCK_SH
            while True:
                try:
                    fcntl.flock(fd, op | fcntl.LOCK_NB)
                    break
                except BlockingIOError:
                    if self.max_queue_s is not None and now() - t0 > self.max_queue_s:
                        os.close(fd)
                        self.release()
                        raise TimeoutError(f'{os.path.basename(path)} ({mode}) held by {self._holder_of(path)!r} '
                                           f'for > {self.max_queue_s:.0f}s')
                    time.sleep(0.2)
            self.fds.append(fd)
            if mode == 'ex' and self.holder:
                try:
                    os.ftruncate(fd, 0)
                    os.write(fd, self.holder.encode('utf-8'))
                except OSError:
                    pass
        self.queued_s = time.monotonic() - t0
        return self.queued_s

    @staticmethod
    def _holder_of(path: str) -> str:
        try:
            with open(path, encoding='utf-8', errors='replace') as fh:
                return fh.read(200).strip()
        except OSError:
            return ''

    def release(self) -> None:
        for fd in self.fds:
            try:
                fcntl.flock(fd, fcntl.LOCK_UN)
                os.close(fd)
            except OSError:
                pass
        self.fds = []

    def __enter__(self):
        self.acquire()
        return self

    def __exit__(self, *exc):
        self.release()


def lock_modes(kind: str, cpu: str, has_tree: bool) -> tuple[str | None, str | None]:
    tree_mode = None
    if has_tree:
        tree_mode = 'ex' if kind == 'write' else 'sh'
    cpu_mode = {'heavy': 'ex', 'light': 'sh', 'none': None}[cpu]
    return tree_mode, cpu_mode


# ----------------------------------------------------------------------- tree state
def git(cwd: str, *args: str) -> str:
    return subprocess.run(['git', '-C', cwd, *args], capture_output=True, text=True, check=True).stdout


def tree_state(path: str) -> tuple[str, str] | None:
    """(HEAD sha, digest of what a reader can see) or None when not a git tree.

    The digest covers `git status --porcelain -uall`, the CONTENT of every tracked change
    (`git diff HEAD --binary`), and the size + mtime of every untracked non-ignored file.
    Porcelain alone cannot see an in-place edit of an already-dirty file — ` M a.ts` reads the
    same for any two dirty bodies — and that is exactly the edit a --write job makes under a
    reader, so the diff bytes are part of the state.
    """
    try:
        head = git(path, 'rev-parse', 'HEAD').strip()
        status = git(path, 'status', '--porcelain', '--untracked-files=all')
        diff = subprocess.run(['git', '-C', path, 'diff', 'HEAD', '--no-ext-diff', '--binary', '--no-color'],
                              capture_output=True, check=True).stdout
        others = git(path, 'ls-files', '--others', '--exclude-standard', '-z')
    except (subprocess.CalledProcessError, FileNotFoundError):
        return None
    h = hashlib.sha256()
    h.update(status.encode('utf-8'))
    h.update(diff)
    for rel in filter(None, others.split('\0')):
        try:
            st = os.lstat(os.path.join(path, rel))
            h.update(f'{rel}\0{st.st_size}\0{st.st_mtime_ns}\n'.encode('utf-8'))
        except OSError:
            h.update(f'{rel}\0gone\n'.encode('utf-8'))
    return head, h.hexdigest()


# -------------------------------------------------------------------- gate (pure)
def gate_decision(prev_closed: bool, triggered: set, dispositioned: set) -> tuple[bool, set]:
    """Pass iff the previous round is closed and every TRIGGERED lever is dispositioned."""
    missing = set(triggered) - set(dispositioned)
    return (prev_closed and not missing), missing


def round_status(events: list[dict], track: str, rnd: int) -> dict:
    close, close_idx = None, -1
    for i, ev in enumerate(events):
        if ev.get('ev') == 'round-close' and ev.get('track') == track and ev.get('round') == rnd:
            close, close_idx = ev, i
    if close is None:
        return dict(closed=False, close_t=None, triggered=set(), dispositioned=set(), notes={})
    disp, notes = set(), {}
    # ordered by LEDGER POSITION, not timestamp: a disposition written before a repeated close
    # answers the old close, and equal or backwards clocks cannot promote it
    for i, ev in enumerate(events):
        if (ev.get('ev') == 'lever' and ev.get('track') == track and ev.get('round') == rnd
                and i > close_idx and ev.get('state') in ('landed', 'declined')):
            disp.add(ev.get('id'))
            notes[ev.get('id')] = f"{ev.get('state')}: {ev.get('note', '')}"
    return dict(closed=True, close_t=close.get('t'), triggered=set(close.get('triggered') or []),
                dispositioned=disp, notes=notes)


def gate(arc: str, track: str, rnd: int) -> tuple[bool, str]:
    if rnd <= 1:
        return True, 'round 1: nothing to close yet'
    st = round_status(ledger_read(arc), track, rnd - 1)
    ok, missing = gate_decision(st['closed'], st['triggered'], st['dispositioned'])
    if ok:
        return True, f"round {rnd - 1} closed at {clock(st['close_t'])}; triggered {sorted(st['triggered']) or 'none'} all dispositioned"
    if not st['closed']:
        return False, (f'round {rnd - 1} of track {track} is not closed — run:\n'
                       f'  python3 {HERE}/loop.py close-round --arc {shlex.quote(arc)} --track {shlex.quote(track)} --round {rnd - 1}')
    lines = [f'round {rnd - 1} of track {track} has TRIGGERED levers without a disposition: {sorted(missing)} — land each, then record it:']
    for lid in sorted(missing):
        lines.append(f'  python3 {HERE}/loop.py lever --arc {shlex.quote(arc)} --track {shlex.quote(track)} '
                     f'--round {rnd - 1} --id {lid} --state landed|declined --note "<what you did, or why not>"')
    return False, '\n'.join(lines)


# ----------------------------------------------------------------------- profiler
DUR_RE = re.compile(r'^\s*Duration\s+([\d.]+)(m?s)\b', re.M)
DUR_MIN_RE = re.compile(r'^\s*Duration\s+(\d+)m\s*([\d.]+)s', re.M)
TF_RE = re.compile(r'^\s*Test Files\s+(.*?)\s*$', re.M)
T_RE = re.compile(r'^\s*Tests\s+(.*?)\s*$', re.M)


def birth(st) -> float | None:
    b = getattr(st, 'st_birthtime', None)
    if b is None or b == 0:
        return None
    return b


def read_head_tail(p: str, n: int = 200_000) -> str:
    try:
        size = os.path.getsize(p)
        with open(p, 'rb') as f:
            if size <= 2 * n:
                data = f.read()
            else:
                data = f.read(n)
                f.seek(size - n)
                data += b'\n...\n' + f.read(n)
        return data.decode('utf-8', 'replace')
    except OSError:
        return ''


def reported_duration(text: str) -> float | None:
    m = DUR_MIN_RE.search(text)
    if m:
        return int(m.group(1)) * 60 + float(m.group(2))
    m = DUR_RE.search(text)
    if m:
        return float(m.group(1)) / (1000.0 if m.group(2) == 'ms' else 1.0)
    return None


def rows_from_dir(d: str, seen_paths: set) -> list[dict]:
    """The legacy heuristic scan of a flat artifact dir (birth → mtime spans)."""
    rows = []
    seen = set(seen_paths)
    for v in sorted(glob.glob(os.path.join(d, '*.verdict.json'))):
        if os.path.abspath(v) in seen:
            continue
        stem = v[:-len('.verdict.json')]
        run = stem + '.run.log'
        prompt = stem + '.prompt.txt'
        end = os.stat(v).st_mtime
        start = None
        if os.path.exists(run):
            start = birth(os.stat(run))
            seen.add(os.path.abspath(run))
        if start is None and os.path.exists(prompt):
            start = os.stat(prompt).st_mtime
        if start is None:
            start = birth(os.stat(v)) or end
        model = ''
        if os.path.exists(run):
            m = re.search(r'^model:\s*(\S+)', read_head_tail(run, 4000)[:4000], re.M)
            if m:
                model = m.group(1)
        sev = ''
        try:
            with open(v) as fh:
                j = json.load(fh)
            f = j.get('findings') or []
            if isinstance(f, list):
                counts: dict = {}
                for x in f:
                    s = (x.get('severity') or '?').lower() if isinstance(x, dict) else '?'
                    counts[s] = counts.get(s, 0) + 1
                sev = ' '.join(f'{k}={n}' for k, n in sorted(counts.items()))
        except Exception:
            pass
        rows.append(dict(kind='review', start=start, end=end, span=end - start, reported=None, tests=sev,
                         path=os.path.join(os.path.basename(d), os.path.basename(v)), note=model,
                         source='dir', track=None, round=None, queued=0.0, cpu=None, job=None, checkpoint=None))
        seen.add(os.path.abspath(v))
    for p in sorted(glob.glob(os.path.join(d, '*.log')) + glob.glob(os.path.join(d, '*.out'))):
        ap = os.path.abspath(p)
        if ap in seen or p.endswith('.run.log') or p.endswith('.launcher.log'):
            continue
        base = os.path.basename(p)
        if 'launch' in base or base.startswith('panel'):
            continue
        st = os.stat(p)
        b = birth(st)
        if b is None:
            continue
        span = st.st_mtime - b
        text = read_head_tail(p) if st.st_size else ''
        reported = reported_duration(text)
        tests = ''
        tf = TF_RE.search(text)
        t = T_RE.search(text)
        if tf:
            tests = 'files: ' + re.sub(r'\s+', ' ', tf.group(1))
        if t:
            tests += ('; ' if tests else '') + 'tests: ' + re.sub(r'\s+', ' ', t.group(1))
        if text[:200].startswith('OpenAI Codex') or re.search(r'^model:\s*gpt-', text[:4000], re.M):
            kind, reported = 'codex', None
        elif base.startswith('ci-') or 'gh run watch' in text[:400]:
            kind = 'ci'
        elif 'tsc' in base:
            kind = 'tsc'
        elif reported is not None:
            kind = 'mutant' if 'mut' in base else 'vitest'
        elif 'mut' in base:
            kind = 'mutant'
        else:
            kind = 'other'
        if kind == 'other' and span < 1:
            continue
        note = ''
        queued = 0.0
        if reported is not None and reported > span:
            span = reported
        if reported is not None and span > reported * 1.5 and span - reported > 5:
            queued = span - reported
            note = f'queued ~{queued:.0f}s beyond its own Duration (inferred: birth→mtime minus Duration)'
        if reported is not None and span > 10 * reported and span > 3600:
            note = (f'measurement-suspect: span {hms(span)} vs Duration {hms(reported)} — a log appended to long '
                    'after its run (birth→mtime is not this run)')
        rows.append(dict(kind=kind, start=b, end=st.st_mtime, span=span, reported=reported, tests=tests,
                         path=os.path.join(os.path.basename(d), base), note=note, source='dir',
                         track=None, round=None, queued=queued, cpu=None, job=None, checkpoint=None))
    return rows


def rows_from_ledger(events: list[dict], t_now: float | None = None) -> tuple[list[dict], set]:
    t_now = t_now or now()
    starts: dict = {}
    ends: dict = {}
    for ev in events:
        if ev.get('ev') == 'start' and ev.get('job'):
            starts[ev['job']] = ev
        elif ev.get('ev') == 'end' and ev.get('job'):
            ends[ev['job']] = ev
    rows, paths = [], set()
    for job, s in starts.items():
        e = ends.get(job)
        start = float(s.get('t', 0))
        end = float(e['t']) if e else t_now
        note = '' if e else 'unfinished (no end event)'
        if end < start:
            # a wall-clock correction mid-job: the interval is INVALID evidence, never a duration
            note = f'CLOCK WENT BACKWARDS ({start - end:.0f}s): interval invalid, counted as 0'
            end = start
        if e and e.get('reason'):
            note = str(e['reason'])[:90]
        if e and e.get('tree_moved'):
            note = 'TREE MOVED during read — quarantined; ' + note
        for k in ('log', 'out'):
            if s.get(k):
                paths.add(os.path.abspath(s[k]))
        label = f"{s.get('track')}/r{s.get('round')}/{s.get('name')}"
        rows.append(dict(kind=s.get('kind', 'other'), start=start, end=end, span=end - start,
                         reported=s.get('reported'), tests=(e or {}).get('tests_text', ''),
                         path=label, note=note, source='ledger', track=s.get('track'), round=s.get('round'),
                         queued=float(s.get('queued_s') or 0.0), cpu=s.get('cpu'), job=job,
                         t_req=float(s.get('t_req') or start),
                         checkpoint=s.get('checkpoint'), rc=(e or {}).get('rc'), unscoped=s.get('unscoped', 0),
                         mutants=s.get('mutants', 0)))
    return rows, paths


def union(intervals):
    total = 0.0
    cur_s = cur_e = None
    for s, e in sorted(intervals):
        if cur_e is None or s > cur_e:
            if cur_e is not None:
                total += cur_e - cur_s
            cur_s, cur_e = s, e
        else:
            cur_e = max(cur_e, e)
    if cur_e is not None:
        total += cur_e - cur_s
    return total


def subtract(a_list, b_list):
    """Length of union(a) not covered by union(b)."""
    pts = []
    for s, e in a_list:
        pts.append((s, 1, 'a'))
        pts.append((e, -1, 'a'))
    for s, e in b_list:
        pts.append((s, 1, 'b'))
        pts.append((e, -1, 'b'))
    pts.sort()
    a = b = 0
    prev = None
    lone = 0.0
    for t, d, w in pts:
        if prev is not None and a > 0 and b == 0:
            lone += t - prev
        if w == 'a':
            a += d
        else:
            b += d
        prev = t
    return lone


def gaps_of(intervals, min_s=GAP_MIN_S):
    merged: list = []
    for s_, e_ in sorted(intervals):
        if merged and s_ <= merged[-1][1]:
            merged[-1][1] = max(merged[-1][1], e_)
        else:
            merged.append([s_, e_])
    gaps = [(merged[i + 1][0] - merged[i][1], merged[i][1], merged[i + 1][0]) for i in range(len(merged) - 1)]
    return sorted((g for g in gaps if g[0] >= min_s), reverse=True)


def load_timeline(arc: str | None, explicit: str | None = None) -> list[tuple[float, str, str]] | None:
    """The job harness's heartbeat (`<job>/timeline.jsonl`, one line per ~minute of seat
    activity).  Returns None when no such file exists — the profiler then says `unknown`
    rather than inventing a cause."""
    cands = [explicit] if explicit else []
    if arc:
        cands.append(os.path.join(arc, '..', 'timeline.jsonl'))
        cands.append(os.path.join(arc, 'timeline.jsonl'))
    for p in cands:
        if p and os.path.exists(p):
            out = []
            with open(p, encoding='utf-8', errors='replace') as fh:
                for ln in fh:
                    try:
                        j = json.loads(ln)
                    except json.JSONDecodeError:
                        continue
                    t = iso_to_epoch(str(j.get('at', '')))
                    if t is not None:
                        out.append((t, str(j.get('state', '')), str(j.get('detail', ''))[:80]))
            return out
    return None


def classify_gap(a: float, b: float, notes: list[dict], timeline: list | None) -> tuple[str, str]:
    """Evidence-only classes.  `declared`: a note event lies in the gap.  `seat-blocked`: the
    harness heartbeat recorded a `blocked` state inside it (a usage limit, an approval prompt,
    a question waiting on the human — the detail says which).  `seat-active`: it recorded
    other activity.  `seat-silent`: a heartbeat file exists and recorded nothing inside it.
    `unknown`: no evidence source at all.  Nothing here guesses a cause it cannot show."""
    declared = [n for n in notes if a <= float(n.get('t', 0)) <= b]
    if declared:
        return 'declared', '; '.join(str(n.get('text', ''))[:80] for n in declared[:2])
    if timeline is None:
        return 'unknown', 'no timeline.jsonl beside the arc — nothing recorded what the seat did'
    inside = [e for e in timeline if a <= e[0] <= b]
    if inside:
        states: dict = {}
        for _, s, _ in inside:
            states[s] = states.get(s, 0) + 1
        summary = f"{len(inside)} heartbeat(s) {', '.join(f'{k}×{n}' for k, n in sorted(states.items()))}"
        blocked = [d for _, st, d in inside if st == 'blocked']
        if blocked:
            first = next((d for d in blocked if d), '')
            return 'seat-blocked', summary + (f'; first block: {first[:100]}' if first else '')
        last = inside[-1][2]
        return 'seat-active', summary + (f'; last detail: {last}' if last else '')
    return 'seat-silent', 'heartbeat file present, nothing recorded inside the gap'


def analyze(rows: list[dict], window: tuple[float, float] | None = None, notes=(), timeline=None,
            title: str = '') -> dict:
    """The profile of one row set.  Returns {'text': str, 'levers': [dict], ...}."""
    out: list[str] = []
    P = out.append
    if not rows:
        P(f'== {title or "profile"} ==  no timed artifacts')
        return dict(text='\n'.join(out), levers=[], rows=[])
    rows = sorted(rows, key=lambda r: -r['span'])
    P(f'== {title or "ranked by wall-clock span"} ==')
    P(f"{'#':>3} {'span':>9} {'queued':>8} {'kind':7} {'reported':>9}  {'started':14}  {'src':6} path  [tests / model / note]")
    for i, r in enumerate(rows, 1):
        rep = hms(r['reported']) if r.get('reported') is not None else '-'
        q = hms(r['queued']) if r.get('queued') else '-'
        extra = ' · '.join(x for x in (r.get('tests') or '', r.get('note') or '') if x)
        src = 'ledger' if r['source'] == 'ledger' else 'UNATTR'
        P(f"{i:>3} {hms(r['span']):>9} {q:>8} {r['kind']:7} {rep:>9}  {clock(r['start'])}  {src:6} {r['path']}  {('[' + extra + ']') if extra else ''}")
    P('')
    P('== totals by kind ==')
    by: dict = {}
    for r in rows:
        k = by.setdefault(r['kind'], [0.0, 0])
        k[0] += r['span']
        k[1] += 1
    tot = sum(v[0] for v in by.values()) or 1.0
    for k, (s, n) in sorted(by.items(), key=lambda kv: -kv[1][0]):
        P(f'  {k:7} {hms(s):>9}  {n:3d} artifact(s)  {100 * s / tot:5.1f}% of timed span')
    ivs = sorted((r['start'], r['end']) for r in rows)
    first = window[0] if window else ivs[0][0]
    last = window[1] if window else max(e for _, e in ivs)
    wall = last - first
    busy = union(ivs)
    waits = [(r['start'], r['end']) for r in rows if r['kind'] in WAIT_KINDS]
    others = [(r['start'], r['end']) for r in rows if r['kind'] not in WAIT_KINDS]
    wait_union = union(waits) if waits else 0.0
    wait_alone = subtract(waits, others) if waits else 0.0
    big_gaps = gaps_of(ivs)
    queued_total = sum(r.get('queued') or 0.0 for r in rows)
    P('')
    P('== timeline ==')
    P(f'  window          {hms(wall):>9}   {clock(first)} → {clock(last)}')
    P(f'  timed activity  {hms(busy):>9}   union of every interval above')
    P(f'  unattributed    {hms(wall - busy):>9}   editing / reading / thinking — not in any artifact')
    if waits:
        P(f'  waits           {hms(wait_union):>9}   {len(waits)} review / codex --write / CI-watch run(s)')
        P(f'  waits ALONE     {hms(wait_alone):>9}   a wait in flight with no other timed artifact running')
    if queued_total:
        P(f'  queued          {hms(queued_total):>9}   measured time jobs spent waiting on a lock (the serialiser working)')
    gap_rows = []
    if big_gaps:
        P(f'  gaps ≥ 30 min   {len(big_gaps)}')
        for g, a, b in big_gaps[:8]:
            cls, ev = classify_gap(a, b, list(notes), timeline)
            gap_rows.append(dict(span=g, start=a, end=b, cls=cls, evidence=ev))
            P(f'                  {hms(g):>9}   {clock(a)} → {clock(b)}   {cls:11} {ev}')
    levers: list[dict] = []

    def lever(lid, name, triggered, evidence, fix, failopen):
        levers.append(dict(id=lid, name=name, triggered=bool(triggered), evidence=evidence, fix=fix, failopen=failopen))

    lever('L1', 'Waits (panel / codex --write / CI) serialised with the fixes',
          bool(waits) and wait_alone > 0.4 * wait_union and wait_union > 300,
          f'{hm(wait_alone)} of {hm(wait_union)} wait time had nothing else timed in flight' if waits else 'no review / codex / CI runs',
          'commit the fix, `loop.py snapshot --sha <that sha>`, and launch the micro-review / next lens on the snapshot '
          'the moment the sha exists; run mutants + spec edits on a copy meanwhile',
          'a lens reading a tree that then moves fails its tree check (rc 5, output quarantined) — that is the guard, keep it')
    wide = [r for r in rows if r['kind'] == 'vitest' and (r.get('cpu') == 'heavy' or (r.get('reported') or 0) >= 60)]
    lever('L2', 'Wide vitest runs standing in for a scoped question',
          len(wide) >= 2,
          (f'{len(wide)} wide/≥60s vitest run(s): ' + ', '.join(
              f"{os.path.basename(r['path'])} {hm(r.get('reported') or r['span'])}"
              + (f" [checkpoint: {r['checkpoint']}]" if r.get('checkpoint') else '') for r in wide[:6])) if wide else 'no wide vitest run',
          'run `loop.py run --kind vitest --affected BASE..HEAD` per commit; keep the full suite for a --checkpoint '
          '(pre-merge, config change) and give every mutant a `test` name via mutate.py',
          'a scoped run that executes 0 test files exits 0 — loop.py counts the `Test Files` line and refuses (rc 5)')
    muts = [r for r in rows if r['kind'] == 'mutant']
    unscoped = sum(int(r.get('unscoped') or 0) for r in muts)
    def per_mutant(r):
        return (r['reported'] if r.get('reported') is not None else r['span']) / max(1, int(r.get('mutants') or 1))
    slow_muts = [r for r in muts if per_mutant(r) >= 10]
    lever('L3', 'Mutant runs paying for the whole file',
          unscoped >= 1 or len(slow_muts) >= 1,
          (f"{len(muts)} mutant run(s); {unscoped} killed mutant(s) without a `test` name (whole-file runs); "
           f"{len(slow_muts)} run(s) averaging ≥ 10 s per mutant (an unattributed run counts as one mutant)") if muts else
          'no mutant runs (were mutants run at all? a round with fixes and no mutant run has not earned "mutation-verified")',
          'set `test` on every `expect: killed` mutant so mutate.py runs the ONE test that must kill it',
          'a `-t` filter matching zero tests exits 0 — mutate.py reports MISARMED; a hand-rolled loop does not')
    tscs = [r for r in rows if r['kind'] == 'tsc']
    slow_tsc = [r for r in tscs if r['span'] >= 20]
    contended = []
    for r in slow_tsc:
        overl = [o for o in rows if o is not r and o['kind'] not in WAIT_KINDS and o['start'] < r['end'] and o['end'] > r['start']]
        if overl:
            contended.append((r, overl))
    lever('L4', 'tsc slower than incremental',
          len(slow_tsc) >= 1,
          (f"{len(tscs)} tsc run(s), slowest {hm(max((r['span'] for r in tscs), default=0))}; "
           f"{len(contended)} of the slow ones overlapped another CPU job "
           + ('(' + ', '.join(f"{os.path.basename(r['path'])} with {len(o)} other" for r, o in contended[:3]) + ')' if contended else '')) if tscs else 'no tsc runs',
          ('re-run the contended one ALONE first (it measured the machine, not the code); ' if contended else '')
          + 'only a slow LONE run justifies touching tsconfig "incremental" / tsBuildInfoFile',
          'a tsc that shared the machine with a vitest child measures the machine — never change compiler config on that reading')
    queued_rows = [r for r in rows if (r.get('queued') or 0) >= 5 or (r.get('note') or '').startswith('queued')]
    lever('L5', 'Runs queued behind each other on one machine',
          queued_total >= 300 or any((r.get('note') or '').startswith('queued') for r in rows),
          (f"{len(queued_rows)} run(s) waited; queue total {hm(queued_total)} (ledgered rows measured, unattributed ones inferred from Duration): "
           + ', '.join(f"{os.path.basename(r['path'])} {hm(r.get('queued') or 0)}" for r in queued_rows[:6])) if queued_rows else 'no run waited on another',
          'the serialiser is doing its job — shrink the queue by scoping (fewer wide runs, --affected per commit) or by '
          'moving the wide ones to checkpoints; never bypass the lock to "speed up"',
          'an unscheduled run beside a scheduled one is contention the lock cannot see — see L7')
    lever('L6', 'Wall-clock not in any artifact',
          wall > 0 and (((wall - busy) > 0.6 * wall and wall > 1800) or bool(big_gaps)),
          (f'{hm(wall - busy)} of {hm(wall)} ({100 * (wall - busy) / wall:.0f}%) has no timed artifact'
           + (f'; {len(big_gaps)} gap(s) ≥ 30 min, largest {hm(big_gaps[0][0])} classed {gap_rows[0]["cls"]}' if big_gaps else '')) if wall > 0 else 'n/a',
          'each gap above carries its evidence class: `declared` = the seat said why (loop.py note); `seat-active` = the seat '
          'was working with no ledgered job (launch that work through loop.py run so it is timed); `seat-silent` = nothing '
          'ran and the seat wrote nothing (a stall or a human wait — say which in the scorecard); `unknown` = no evidence',
          'time spent reproducing a reviewer claim is NOT waste — the fail-open is fixing an unreproduced finding, not measuring one')
    strays = [r for r in rows if r['source'] == 'dir' and r['span'] >= 30]
    lever('L7', 'Jobs launched outside the scheduler',
          len(strays) >= 1,
          (f'{len(strays)} timed artifact(s) with no ledger entry: ' + ', '.join(os.path.basename(r['path']) for r in strays[:6])) if strays else 'every timed artifact is ledgered',
          'launch every review / vitest / tsc / mutant through `loop.py run --track T --round N --kind K -- <cmd>` '
          '(run-codex.sh does this itself when given --arc/--track/--round)',
          'an unscheduled heavy job fights the scheduled ones and its outcome is not fail-closed-counted')
    P('')
    P('== levers (evaluated; TRIGGERED = land it before the next panel) ==')
    for lv in levers:
        flag = 'TRIGGERED' if lv['triggered'] else 'quiet    '
        P(f"  [{flag}] {lv['id']} {lv['name']}")
        P(f"             evidence : {lv['evidence']}")
        if lv['triggered']:
            P(f"             do       : {lv['fix']}")
        P(f"             fail-open: {lv['failopen']}")
    P('')
    P('A lever that changes WHAT is verified is not a speedup (memory: optimize-the-loop-unprompted).')
    return dict(text='\n'.join(out), levers=levers, rows=rows, wall=wall, busy=busy, wait_union=wait_union,
                wait_alone=wait_alone, gaps=gap_rows, queued=queued_total)


def gather_rows(arc: str | None, dirs: list[str]) -> tuple[list[dict], list[dict]]:
    events = ledger_read(arc) if arc else []
    rows, seen = rows_from_ledger(events)
    scan = list(dirs)
    if arc and arc not in [os.path.abspath(d) for d in scan]:
        scan.append(arc)
    for d in scan:
        if not os.path.isdir(d):
            print(f'!! not a directory: {d}', file=sys.stderr)
            continue
        rows.extend(rows_from_dir(d, seen))
    notes = [ev for ev in events if ev.get('ev') == 'note']
    return rows, notes


def round_window(rows: list[dict], track: str, rnd: int) -> tuple[float, float] | None:
    mine = [r for r in rows if r['source'] == 'ledger' and r['track'] == track and r['round'] == rnd]
    if not mine:
        return None
    # the RECORDED request time opens the window — never start minus an aggregate queue total
    # (mutate.py sums the waits of every mutant into one row, which would open it far too early)
    return min(r['t_req'] for r in mine), max(r['end'] for r in mine)


def clip_rows(rows, window):
    """The rows overlapping `window`, clipped to it, so a job that straddles the boundary contributes
    only its inside part to this round's busy/wait/gap arithmetic (a 1000 s job overlapping a
    10 s round otherwise reads as -990 s unattributed).

    Selection and clipping are ONE predicate on purpose: a row whose clipped end precedes its clipped
    start is exactly a row that does not overlap the window. Splitting them into a filter feeding a
    clipper made the clipper silently mask a broken filter — measured, a mutant that made the filter
    return every row SURVIVED, because the clip re-filtered them on the way out."""
    a, b = window
    out = []
    for r in rows:
        c = dict(r)
        c['start'] = max(r['start'], a)
        c['end'] = min(r['end'], b)
        if c['end'] < c['start']:
            continue
        if (c['start'], c['end']) != (r['start'], r['end']):
            c['span'] = c['end'] - c['start']
            c['note'] = (f"clipped to the round ({hms(r['end'] - r['start'])} in full); " + (r.get('note') or '')).rstrip('; ')
        out.append(c)
    return out


def profile_text(arc: str | None, dirs: list[str], track: str | None = None, rnd: int | None = None,
                 timeline_path: str | None = None) -> tuple[str, dict]:
    rows, notes = gather_rows(arc, dirs)
    timeline = load_timeline(arc, timeline_path)
    if track is not None and rnd is not None:
        w = round_window(rows, track, rnd)
        if w is None:
            txt = f'== track {track} round {rnd} ==  no ledgered job for this round (nothing launched through loop.py run)'
            return txt, dict(levers=[], empty=True)
        res = analyze(clip_rows(rows, w), w, notes, timeline, title=f'track {track} round {rnd}  {clock(w[0])} → {clock(w[1])}')
        return res['text'], res
    parts = []
    tr = sorted({(r['track'], r['round']) for r in rows if r['source'] == 'ledger'}, key=lambda x: (str(x[0]), x[1] or 0))
    summary = {}
    for t, n in tr:
        w = round_window(rows, t, n)
        res = analyze(clip_rows(rows, w), w, notes, timeline, title=f'track {t} round {n}  {clock(w[0])} → {clock(w[1])}')
        parts.append(res['text'])
        summary[f'{t}/r{n}'] = res
    whole = analyze(rows, None, notes, timeline, title='whole arc' if tr else 'ranked by wall-clock span (birth → last write)')
    parts.append(whole['text'])
    if tr:
        unattr = [r for r in rows if r['source'] == 'dir']
        parts.append(f'\nledger: {sum(1 for r in rows if r["source"] == "ledger")} job(s) in {len(tr)} (track, round) pair(s); '
                     f'{len(unattr)} unattributed artifact(s)')
    return '\n\n'.join(parts), dict(rounds=summary, whole=whole)


# ------------------------------------------------------------------------ commands
def die(msg: str, rc: int = RC_USAGE) -> int:
    print(f'loop.py: {msg}', file=sys.stderr)
    return rc


def need_arc(args) -> str | None:
    arc = arc_dir(getattr(args, 'arc', None))
    if not arc:
        print('loop.py: --arc DIR (or CC_ARC / CLAUDE_JOB_DIR) is required', file=sys.stderr)
    return arc


def changed_files(cwd: str, rng: str, include_uncommitted: bool) -> list[str]:
    files = [f for f in git(cwd, 'diff', '--name-only', rng).splitlines() if f.strip()]
    if include_uncommitted:
        for ln in git(cwd, 'status', '--porcelain', '--untracked-files=all').splitlines():
            if len(ln) > 3:
                files.append(ln[3:].strip().split(' -> ')[-1])
    return sorted(set(files))


def cmd_run(args) -> int:
    arc = need_arc(args)
    if not arc:
        return RC_USAGE
    if args.kind not in KINDS:
        return die(f'--kind must be one of {KINDS}')
    cmd = list(args.cmd)
    if cmd and cmd[0] == '--':
        cmd = cmd[1:]
    cwd = os.path.abspath(args.cwd or args.tree or os.getcwd())
    name = args.name or args.kind
    checkpoint = args.checkpoint
    affected_files: list[str] = []
    if args.affected:
        if args.kind != 'vitest':
            return die('--affected applies to --kind vitest only')
        if cmd:
            return die('--affected composes the vitest command itself; do not pass one')
        try:
            changed = changed_files(cwd, args.affected, args.include_uncommitted)
        except subprocess.CalledProcessError as e:
            return die(f'--affected: git failed: {e.stderr.strip()}')
        mode, picked = affected_plan(changed)
        if mode == 'wide':
            checkpoint = checkpoint or f'config-changed: {", ".join(picked[:4])}'
            cmd = shlex.split(args.vitest_bin) + ['run']
            print(f'loop.py: {picked} changed → escalating to the full suite (checkpoint: {checkpoint})', file=sys.stderr)
        else:
            affected_files = picked
            if not picked:
                if args.allow_no_tests:
                    ledger_append(arc, dict(ev='note', track=args.track, round=args.round,
                                            text=f'{name}: --affected {args.affected} touched no source file; --allow-no-tests recorded'))
                    print(f'loop.py: --affected {args.affected} touched no source/test file; recorded --allow-no-tests', file=sys.stderr)
                    return 0
                return die(f'--affected {args.affected} touched no source/test file — nothing to run '
                           '(pass --allow-no-tests to record that decision)', RC_FAILCLOSED)
            cmd = shlex.split(args.vitest_bin) + ['related', '--run'] + picked
    if not cmd:
        return die('no command given (after --)')
    cpu = cpu_class(args.kind, cmd, args.cpu)
    if needs_checkpoint(args.kind, cpu, checkpoint):
        return die(f'a WIDE vitest run ({shlex.join(cmd)}) needs --checkpoint "<why the whole suite, here>" — '
                   'scope it (--affected BASE..HEAD, or name ≤ 8 files) or state the checkpoint', RC_WIDE)
    if args.kind in ('review', 'write'):
        ok, msg = gate(arc, args.track, args.round)
        if not ok:
            print(f'loop.py: GATE REFUSED launching {args.kind} for track {args.track} round {args.round}:\n{msg}', file=sys.stderr)
            return RC_GATE
    tree = os.path.abspath(args.tree) if args.tree else None
    if tree and tree_state(tree) is None:
        return die(f'--tree {tree} is not a git worktree')
    tree_mode, cpu_mode = lock_modes(args.kind, cpu, bool(tree))
    t_req = now()
    job = f'{args.track}.r{args.round}.{name}.{int(t_req * 1000)}'
    capture = args.kind in ('vitest', 'tsc', 'mutant', 'other') if args.capture is None else args.capture
    log = args.log
    if capture and not log:
        rdir = os.path.join(arc, 'rounds', str(args.track), f'r{args.round}')
        os.makedirs(rdir, exist_ok=True)
        log = os.path.join(rdir, f'{name}.{int(t_req)}.log')
    locks = Locks(tree, tree_mode, cpu_mode, holder=job, max_queue_s=args.max_queue)
    # The queued event lands BEFORE the wait, so a job killed or refused while waiting on a lock
    # is still visible in the ledger (and the inner launcher can verify who started it).
    ledger_append(arc, dict(ev='queued', t=t_req, job=job, track=args.track, round=args.round, kind=args.kind,
                            name=name, cpu=cpu, tree=tree, pid=os.getpid()))
    try:
        queued = locks.acquire()
    except TimeoutError as e:
        ledger_append(arc, dict(ev='refused', t=now(), job=job, track=args.track, round=args.round, kind=args.kind,
                                name=name, reason=f'lock not available: {e}'))
        return die(f'lock not available: {e}', RC_LOCK)
    except OSError as e:
        return die(f'cannot take locks under {lock_dir()}: {e} (refusing to run unlocked)', RC_LOCK)
    # Snapshot the tree only once we HOLD it: a writer that ran while we were queued has finished
    # and its result is the tree our child reads, not a "move" (it is the same reason the closing
    # snapshot is taken before release, below).
    tree_before = tree_state(tree) if tree else None
    t_start = now()
    m_start = time.monotonic()
    start_ev = dict(ev='start', t=t_start, job=job, track=args.track, round=args.round, kind=args.kind, name=name,
                    cpu=cpu, tree=tree, reads_sha=(tree_before[0] if tree_before else args.reads_sha),
                    t_req=t_req, queued_s=queued, cmd=cmd, cwd=cwd, log=log, out=args.out, checkpoint=checkpoint,
                    affected=affected_files or None, pid=os.getpid(), tree_status=(tree_before[1] if tree_before else None))
    ledger_append(arc, start_ev)
    print(f'loop.py: [{job}] {args.kind}/{cpu} queued {queued:.1f}s → running: {shlex.join(cmd)}'
          + (f'  (log: {log})' if log else ''), file=sys.stderr)
    rc = -1
    reason = ''
    fh = open(log, 'ab') if capture else None
    child = None
    try:
        # The inner handshake: run-codex.sh honours CC_LOOP_JOB only when the ledger shows this
        # job started by ITS parent pid, so the marker cannot be forged by passing a flag.
        child_env = dict(os.environ, CC_LOOP_JOB=job, CC_LOOP_ARC=arc)
        child = subprocess.Popen(cmd, cwd=cwd, stdout=fh or None, stderr=(subprocess.STDOUT if fh else None), env=child_env)

        def forward(signum, _frame):
            if child and child.poll() is None:
                child.send_signal(signum)

        for sig in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
            signal.signal(sig, forward)
        rc = child.wait()
        reason = f'child rc={rc}'
    finally:
        if fh:
            fh.close()
        # still holding the tree: a writer queued behind us cannot move it between the child's
        # exit and this comparison
        after = tree_state(tree) if (tree and args.kind != 'write') else None
        locks.release()
    t_end = now()
    span_s = max(0.0, time.monotonic() - m_start)
    end_ev: dict = dict(ev='end', t=t_end, job=job, rc=rc, tree_moved=False)
    if args.kind == 'vitest' and capture:
        out = read_head_tail(log)
        rc, reason = vitest_verdict(rc, out, has_name_filter(cmd), args.allow_no_tests)
        end_ev.update(tests=tests_ran(out), test_files=test_files_ran(out), reported=reported_duration(out),
                      tests_text=f'files: {test_files_ran(out)}; tests: {tests_ran(out)}')
    if tree and args.kind != 'write':
        if after != tree_before:
            end_ev['tree_moved'] = True
            reason = (f'TREE MOVED during the read: HEAD {tree_before[0][:12]}→{(after or ("?", ""))[0][:12]}, '
                      f'content/status {"changed" if after and after[1] != tree_before[1] else "same"}; ' + reason)
            rc = RC_FAILCLOSED
            if args.out and os.path.exists(args.out):
                os.replace(args.out, args.out + '.tree-moved')
                reason += f' — output quarantined to {args.out}.tree-moved'
    end_ev.update(rc=rc, reason=reason, span_s=span_s)
    ledger_append(arc, end_ev)
    print(f'loop.py: [{job}] done rc={rc} in {hms(t_end - t_start)} — {reason}', file=sys.stderr)
    return rc


def cmd_gate(args) -> int:
    arc = need_arc(args)
    if not arc:
        return RC_USAGE
    ok, msg = gate(arc, args.track, args.round)
    print(('GATE PASS: ' if ok else 'GATE REFUSED: ') + msg)
    return 0 if ok else RC_GATE


def cmd_close_round(args) -> int:
    arc = need_arc(args)
    if not arc:
        return RC_USAGE
    txt, res = profile_text(arc, args.dirs, args.track, args.round, args.timeline)
    if res.get('empty') and not args.empty_ok:
        print(txt)
        return die(f'no ledgered job in track {args.track} round {args.round}; pass --empty-ok to close it anyway '
                   '(the close then records that nothing was measured)', RC_FAILCLOSED)
    rdir = os.path.join(arc, 'rounds', str(args.track), f'r{args.round}')
    os.makedirs(rdir, exist_ok=True)
    ppath, lpath = os.path.join(rdir, 'profile.txt'), os.path.join(rdir, 'levers.json')
    with open(ppath, 'w', encoding='utf-8') as fh:
        fh.write(txt + '\n')
    levers = res.get('levers', [])
    with open(lpath, 'w', encoding='utf-8') as fh:
        json.dump(levers, fh, indent=1)
    triggered = [lv['id'] for lv in levers if lv['triggered']]
    ledger_append(arc, dict(ev='round-close', track=args.track, round=args.round, triggered=triggered,
                            profile=ppath, levers=lpath, empty=bool(res.get('empty'))))
    print(txt)
    print(f'\nround {args.round} of track {args.track} CLOSED; TRIGGERED: {triggered or "none"}')
    if triggered:
        print('before launching round %d, land each and record it:' % (args.round + 1))
        for lid in triggered:
            print(f'  python3 {HERE}/loop.py lever --arc {shlex.quote(arc)} --track {shlex.quote(str(args.track))} '
                  f'--round {args.round} --id {lid} --state landed|declined --note "..."')
    return 0


def cmd_lever(args) -> int:
    arc = need_arc(args)
    if not arc:
        return RC_USAGE
    if args.id not in LEVER_IDS:
        return die(f'--id must be one of {LEVER_IDS}')
    if not args.note.strip():
        return die('--note must say what was landed, or why the lever is declined')
    st = round_status(ledger_read(arc), args.track, args.round)
    if not st['closed']:
        return die(f'round {args.round} of track {args.track} is not closed; close it first', RC_GATE)
    if args.id not in st['triggered']:
        print(f'note: {args.id} was not TRIGGERED at the close of round {args.round}; recording anyway', file=sys.stderr)
    ledger_append(arc, dict(ev='lever', track=args.track, round=args.round, id=args.id, state=args.state, note=args.note))
    print(f'recorded {args.id} {args.state} for track {args.track} round {args.round}')
    return 0


def cmd_note(args) -> int:
    arc = need_arc(args)
    if not arc:
        return RC_USAGE
    ledger_append(arc, dict(ev='note', track=args.track, round=args.round, text=' '.join(args.text)))
    return 0


def cmd_profile(args) -> int:
    dirs = [os.path.abspath(d.rstrip('/')) for d in args.dirs]
    # The arc is what was ASKED for: --arc, else the given dir (the one holding a ledger, else
    # the first), and only with no dirs at all the environment.  Resolving the environment
    # first made `profile <other job's dir>` read this job's heartbeat for that job's gaps.
    if args.arc:
        arc = os.path.abspath(args.arc)
    elif dirs:
        arc = next((d for d in dirs if os.path.exists(os.path.join(d, LEDGER))), dirs[0])
    else:
        arc = arc_dir(None)
    if arc is None:
        return die('give an artifact dir, --arc, or set CC_ARC / CLAUDE_JOB_DIR')
    track, rnd = None, None
    if args.round:
        t, _, n = args.round.rpartition(':')
        if not t or not n.isdigit():
            return die('--round must be TRACK:N')
        track, rnd = t, int(n)
        if not os.path.exists(ledger_path(arc)):
            return die(f'--round needs a ledger ({LEDGER}) in {arc}')
    txt, res = profile_text(arc, dirs, track, rnd, args.timeline)
    if not txt.strip():
        print('no timed artifacts found (need *.verdict.json / *.log / *.out with birth times, or a jobs.jsonl)')
        return 0
    print(txt)
    if args.json:
        with open(args.json, 'w', encoding='utf-8') as fh:
            json.dump(dict(levers=res.get('levers') or (res.get('whole') or {}).get('levers'),
                           rounds={k: v['levers'] for k, v in (res.get('rounds') or {}).items()}), fh, indent=1)
    return 0


def cmd_snapshot(args) -> int:
    arc = need_arc(args)
    if not arc:
        return RC_USAGE
    repo = os.path.abspath(args.repo)
    wt_root = os.path.join(arc, 'wt')
    if args.prune:
        for d in sorted(glob.glob(os.path.join(wt_root, '*'))):
            subprocess.run(['git', '-C', repo, 'worktree', 'remove', '--force', d], capture_output=True)
            print(f'removed {d}')
        return 0
    try:
        sha = git(repo, 'rev-parse', '--verify', args.sha + '^{commit}').strip()
    except subprocess.CalledProcessError:
        return die(f'{args.sha} is not a commit in {repo}')
    path = os.path.join(wt_root, sha[:12])
    if os.path.isdir(path):
        head = tree_state(path)
        if head and head[0] == sha:
            print(path)
            return 0
        return die(f'{path} exists but is not at {sha[:12]}', RC_FAILCLOSED)
    os.makedirs(wt_root, exist_ok=True)
    r = subprocess.run(['git', '-C', repo, 'worktree', 'add', '--detach', path, sha], capture_output=True, text=True)
    if r.returncode != 0:
        return die(f'git worktree add failed: {r.stderr.strip()}')
    nm = os.path.join(repo, 'node_modules')
    if os.path.isdir(nm) and not os.path.exists(os.path.join(path, 'node_modules')):
        os.symlink(nm, os.path.join(path, 'node_modules'))
    ledger_append(arc, dict(ev='note', track=args.track, round=args.round, text=f'snapshot {sha[:12]} → {path}'))
    print(path)
    return 0


def build_parser() -> argparse.ArgumentParser:
    ap = argparse.ArgumentParser(prog='loop.py', description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest='cmd', required=True)

    def common(p, track=True):
        p.add_argument('--arc', help='arc dir holding jobs.jsonl (default $CC_ARC, then $CLAUDE_JOB_DIR/tmp)')
        if track:
            p.add_argument('--track', required=True, help='track label, e.g. A')
            p.add_argument('--round', required=True, type=int, help='round number within the track')

    p = sub.add_parser('run', help='launch one job under the locks, the gate, the fail-closed checks and the ledger')
    common(p)
    p.add_argument('--kind', required=True, choices=KINDS)
    p.add_argument('--name', help='job name (default: the kind)')
    p.add_argument('--tree', help='worktree the job reads (review/vitest/tsc) or writes (write): takes its lock and pins its state')
    p.add_argument('--reads-sha', help='sha the job reads, when --tree is not given (informational)')
    p.add_argument('--cpu', choices=CPU_CLASSES, help='lock class for --kind other (default light); ignored for classified kinds')
    p.add_argument('--checkpoint', help='why a WIDE vitest run is justified here (required for one)')
    p.add_argument('--affected', metavar='BASE..HEAD', help='compose `vitest related --run <changed files>` over this git range')
    p.add_argument('--include-uncommitted', action='store_true', help='with --affected, also include working-tree changes')
    p.add_argument('--vitest-bin', default='npx vitest', help='vitest command prefix for --affected (default: npx vitest)')
    p.add_argument('--allow-no-tests', action='store_true', help='record that a vitest run executing 0 test files is acceptable here')
    p.add_argument('--out', help='the job\'s verdict/output path (quarantined on tree-moved)')
    p.add_argument('--log', help='log path; captured output goes here (default: <arc>/rounds/<track>/r<N>/<name>.<t>.log)')
    p.add_argument('--capture', dest='capture', action='store_true', default=None, help='capture the child\'s output into --log')
    p.add_argument('--no-capture', dest='capture', action='store_false', help='let the child inherit stdout/stderr (--log is then a pointer)')
    p.add_argument('--cwd', help='working directory for the command (default: --tree, else cwd)')
    p.add_argument('--max-queue', type=float, help='seconds to wait for a lock before refusing (default: wait)')
    p.add_argument('cmd', nargs=argparse.REMAINDER, help='-- command...')
    p.set_defaults(fn=cmd_run)

    p = sub.add_parser('gate', help='may round N of this track launch?')
    common(p)
    p.set_defaults(fn=cmd_gate)

    p = sub.add_parser('close-round', help='profile the round, write its levers, record the close')
    common(p)
    p.add_argument('--empty-ok', action='store_true')
    p.add_argument('--timeline', help='heartbeat file for gap classification (default: <arc>/../timeline.jsonl)')
    p.add_argument('dirs', nargs='*', help='extra artifact dirs to scan heuristically')
    p.set_defaults(fn=cmd_close_round)

    p = sub.add_parser('lever', help='disposition a TRIGGERED lever')
    common(p)
    p.add_argument('--id', required=True)
    p.add_argument('--state', required=True, choices=('landed', 'declined'))
    p.add_argument('--note', required=True)
    p.set_defaults(fn=cmd_lever)

    p = sub.add_parser('note', help='declare why a stretch of wall-clock has no job (a human wait, a sleep)')
    p.add_argument('--arc')
    p.add_argument('--track')
    p.add_argument('--round', type=int)
    p.add_argument('text', nargs='+')
    p.set_defaults(fn=cmd_note)

    p = sub.add_parser('profile', help='where did the wall-clock go?')
    p.add_argument('--arc')
    p.add_argument('--round', metavar='TRACK:N', help='profile one round only')
    p.add_argument('--json', help='write the levers as JSON here')
    p.add_argument('--timeline')
    p.add_argument('dirs', nargs='*')
    p.set_defaults(fn=cmd_profile)

    p = sub.add_parser('snapshot', help='a detached worktree at a sha, under <arc>/wt/<sha12>')
    p.add_argument('--arc')
    p.add_argument('--track')
    p.add_argument('--round', type=int)
    p.add_argument('--repo', required=True, help='any worktree of the repo')
    p.add_argument('--sha', help='commit to pin')
    p.add_argument('--prune', action='store_true', help='remove every snapshot worktree under <arc>/wt')
    p.set_defaults(fn=cmd_snapshot)
    return ap


def main(argv: list[str] | None = None) -> int:
    ap = build_parser()
    args = ap.parse_args(argv)
    if args.cmd == 'snapshot' and not args.prune and not args.sha:
        return die('snapshot needs --sha (or --prune)')
    return args.fn(args)


if __name__ == '__main__':
    sys.exit(main())
