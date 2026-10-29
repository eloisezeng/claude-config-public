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
import contextlib
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
from collections.abc import Mapping, Sequence

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
# The finding-outcome store validates `outcome` against this skill's one closed set of six
# (§5.3). Imported rather than re-declared: two copies of a closed set is the shape where a
# seventh value is accepted by one reader and refused by another, and the two stores here would
# then disagree about what a countable outcome is. The two files ship together in this directory,
# so a missing sibling is a broken install rather than a configuration to degrade around.
import review_eval  # noqa: E402
KINDS = ('review', 'write', 'vitest', 'tsc', 'mutant', 'ci', 'other')
WAIT_KINDS = ('review', 'write', 'codex', 'ci')
CPU_CLASSES = ('heavy', 'light', 'none')
LEVER_IDS = ('L1', 'L2', 'L3', 'L4', 'L5', 'L6', 'L7')

# The six questions the efficiency PREFLIGHT must answer before round 1 launches. See
# `preflight_decision` for why this gate exists at all and why it cannot live at a round boundary.
PREFLIGHT_FIELDS = ('critical_path', 'parallel', 'batch', 'scope', 'stop', 'drivers')
PREFLIGHT_FILLER = frozenset(
    ('n/a', 'na', 'none', 'nothing', 'tbd', 'todo', '-', '--', '?', 'x', 'no', 'yes', 'same',
     'default', 'unknown', 'as usual', 'standard', 'normal'))
#: The reserved track `run-codex.sh --one-off` schedules into. A one-off is scheduled for its
#: TREE LOCK and its movement check, never for round accounting: NOTHING ever closes a round on
#: this track, which is what lets a one-off neither block nor be blocked by a real arc.
#: `run-codex.sh` reads this value back (`loop.py one-off-track`) rather than spelling it a second
#: time, because two spellings of a reserved name is the shape where the exemption in
#: `review_name_collision` covers a track the launcher has stopped using.
ONE_OFF_TRACK = 'one-off'
GAP_MIN_S = 1800
REAP_GRACE_S = 10.0   # per signal: how long a killed process group gets to actually go away
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
# The prefix is `[^A-Za-z]*`, not `\W*`: node's counter glyph U+2139 (INFORMATION SOURCE) is
# Alphabetic in Unicode, so Python's `\w` MATCHES it and `\W` does not — a `\W+` prefix matches
# nothing at all here and every counter line reads as absent.
NODE_COUNTER_RE = re.compile(r'^[^A-Za-z]*(tests|suites|pass|fail|cancelled|skipped|todo)'
                             r'\s+(\d+)$')


def node_test_counts(out: str) -> dict[str, int] | None:
    """The `node --test` runner's end-of-run counters, or None when `out` holds none.

    The second supported runner.  `node --test` prints no single `Tests ...` line; it
    prints one counter per line, each behind an information glyph, so the real bytes of
    a green run are `\x1b[34m\u2139 pass 9\x1b[39m`.  A parser that only knows vitest
    reads that as NO SUMMARY, `tests_ran` returns 0, and the run is refused as
    `BASELINE NOT GREEN: the suite executed ZERO tests` with nine passing tests in the
    very output being quoted — measured 2026-10-07 against a `node --test` repository.
    Fail-closed made it survivable, as with the ANSI class above, but a harness that
    cannot see a pass cannot verify a mutant on that runner at all.

    `pass` and `fail` are the executed count; `skipped` and `todo` are deliberately not,
    for the same reason skipped tests do not count on vitest.
    """
    counts: dict[str, int] = {}
    for line in _plain_lines(out):
        match = NODE_COUNTER_RE.match(line)
        if match:
            counts[match.group(1)] = int(match.group(2))
    # `pass` and `fail` are both always printed, so requiring both rejects a stray line
    # of prose that happens to end in a number.
    if 'pass' not in counts or 'fail' not in counts:
        return None
    return counts


def tests_ran(out: str) -> int:
    """How many tests actually EXECUTED, on either supported runner.

    Skipped tests do not count: a `-t` filter that matches nothing reports them as
    skipped and exits 0, and that must not be readable as a surviving mutant or a green
    run.  Returns 0 when no summary is present at all (no run happened).

    Reads vitest's single `Tests ...` summary line first, then `node --test`'s
    per-counter block; see `node_test_counts`.
    """
    line = next((ln for ln in _plain_lines(out) if ln.startswith('Tests ')), None)
    if line is not None:
        return sum(int(n) for n in re.findall(r'(\d+)\s+(?:passed|failed)', line))
    counts = node_test_counts(out)
    if counts is None:
        return 0
    return counts['pass'] + counts['fail']


ANSI_RE = re.compile(r'\x1b(?:\[[0-?]*[ -/]*[@-~]|\][^\x07\x1b]*(?:\x07|\x1b\\)|[@-Z\\-_])')


def strip_ansi(text: str) -> str:
    """`text` with every ANSI escape removed.

    This is a CAPTURE-SITE rule, not a cosmetic one.  vitest's default reporter
    colourises even when its stdout is a pipe, so its summary line really arrives as
    `\x1b[2m Test Files \x1b[22m...`.  `line.strip().startswith('Test Files')` therefore
    matched NOTHING, and the fail-closed count read every genuinely green scoped run as
    `rc 5 NO-TESTS` — measured 2026-10-03 on a run whose own log says
    `Test Files  2 passed (2)` / `Tests  32 passed (32)`.

    Fail-closed is why this was survivable rather than silent, but a check that cannot
    see a pass is not a check: it makes the per-task gate unusable for a whole arc, and
    the obvious repair is `--allow-no-tests` everywhere, which switches the gate off.
    """
    return ANSI_RE.sub('', text)


def _plain_lines(out: str) -> list[str]:
    """`out`'s lines, escapes removed and edges trimmed, ready to match on."""
    return [ln.strip() for ln in strip_ansi(out).splitlines()]


def test_files_ran(out: str) -> int | None:
    """How many test FILES vitest ran, from its `Test Files ...` line; None when absent.

    `vitest related <file>` with no importing test prints `No test files found, exiting
    with code 0` and no summary at all — measured 2026-09-02 — so absence is the
    fail-open case and the caller must treat None as 0.
    """
    line = next((ln for ln in _plain_lines(out) if ln.startswith('Test Files')), None)
    if line is None:
        return None
    return sum(int(n) for n in re.findall(r'(\d+)\s+(?:passed|failed)', line))


def no_tests_found(out: str) -> bool:
    return 'No test files found' in strip_ansi(out)


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
# Vitest operands that WRITE INTO the tree they run in (snapshot files). They are not wide --
# `vitest run one.test.ts -u` still executes one file -- so the CPU class is right to call them
# light; what was wrong (round 3, CORR5) is the LOCK. Two `-u` runs on one tree were each given
# a SHARED tree lock, so both could rewrite the same .snap concurrently, and the post-run
# movement check can only redden the results afterwards -- it cannot un-corrupt the worktree.
# `--update=false` is read as writing too: the direction of a misread has to be more
# serialisation, never less.
TREE_WRITING_FLAGS = {'-u', '--update'}
FILE_RE = re.compile(r'\.[cm]?[jt]sx?$')
GLOB_RE = re.compile(r'[*?\[{]')   # a glob selects an unbounded set of files: never light
VITEST_SUBCMDS = {'run', 'related', 'watch', 'dev', 'bench', 'list', 'typecheck', 'init'}


def vitest_shape(argv: list[str]) -> dict:
    """Classify a vitest command line: {sub, files, dirs, wide_flag, name_filter}."""
    argv = list(argv)
    vi = next((i for i, a in enumerate(argv) if a == 'vitest' or a.endswith('/vitest')), None)
    if vi is None:
        return dict(sub=None, files=[], dirs=[], wide_flag=False, name_filter=False,
                    writes_tree=False, known=False)
    rest = argv[vi + 1:]
    sub = 'run'
    if rest and rest[0] in VITEST_SUBCMDS:
        sub = rest[0]
        rest = rest[1:]
    files, dirs = [], []
    wide_flag = name_filter = writes_tree = False
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
        if flag in TREE_WRITING_FLAGS:
            writes_tree = True
        if tok.startswith('-'):
            if flag in VALUE_FLAGS and not has_val:
                skip = True
            continue
        # A token that names an existing regular file selects exactly ONE file however it is spelled —
        # Next.js route folders are literally called `[slug]`, which GLOB_RE would otherwise read as a
        # character class and push a four-file run into the wide class. A token absent from disk keeps
        # the glob reading, so the misread still fails towards heavy.
        is_one_file = FILE_RE.search(tok) and (os.path.isfile(tok) or not GLOB_RE.search(tok))
        (files if is_one_file else dirs).append(tok)
    return dict(sub=sub, files=files, dirs=dirs, wide_flag=wide_flag, name_filter=name_filter,
                writes_tree=writes_tree, known=True)


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


def ci_snapshots_frozen(env: dict | None = None) -> bool:
    """Does the environment PROVE vitest will refuse to write a missing snapshot?

    Vitest resolves `update` to `new` whenever it is not running in CI, so a plain `vitest run`
    with no `-u` still WRITES an absent external or inline snapshot into the source tree the first
    time it meets one. Only CI turns that off. `''`, `'0'`, `'false'`, `'no'` and `'off'` are how
    the major runners spell "not CI", so none of them is proof.
    """
    v = (os.environ if env is None else env).get('CI', '')
    return str(v).strip().lower() not in ('', '0', 'false', 'no', 'off')


def tree_writing(kind: str, argv: list[str], env: dict | None = None) -> bool:
    """Does this job MUTATE the tree it was handed, so that it needs an EXCLUSIVE tree lock?

    A `write` job does by definition. A vitest run does when it carries a snapshot-updating
    operand. An UNKNOWN vitest command line does too: `cpu_class` already fails such a line
    towards `heavy`, and the lock has to fail the same direction.

    A KNOWN vitest command line with no update operand is a writer too, unless CI is set. The
    flag is not what makes vitest write: outside CI its default `update` is `new`, so the first
    run that meets a missing snapshot writes one. Two such runs took SHARED locks and could write
    the same snapshot file, or let a review read a half-updated tree — and the post-run
    tree-moved check can only refuse the verdict afterwards, never un-write the file. The escape
    for a run that really is read-only is to set `CI=1`, which is also what makes a missing
    snapshot FAIL rather than appear.
    """
    if kind == 'write':
        return True
    if kind == 'vitest':
        sh = vitest_shape(argv)
        if bool(sh['writes_tree']) or not sh['known']:
            return True
        return not ci_snapshots_frozen(env)
    return False


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


def ledger_lock_path(arc: str) -> str:
    return ledger_path(arc) + '.lock'


def tail_is_incomplete(fd: int) -> bool:
    """Does the ledger end mid-record — a final line with no newline?

    Only ever true after a writer died between two `os.write` calls of one record. Appending onto
    such a line would splice our event onto its tail and corrupt BOTH; starting a fresh line leaves
    the broken record broken (`ledger_read` reports it, and the lifecycle checks fail closed on it)
    and keeps ours intact.
    """
    try:
        size = os.fstat(fd).st_size
        return size > 0 and os.pread(fd, 1, size - 1) != b'\n'
    except OSError:
        return False


def _jsonl_append(path: str, lock_path: str, rec: dict) -> None:
    """Append one JSON object as one line, atomically against every other appender.

    Extracted from `ledger_append` when the outcome store of §5.2 became the second append-only
    JSONL file in the arc directory. A second copy of this would have been a second copy of the
    LIFE5 fix below, and the two would have drifted on the first repair to either.
    """
    with _jsonl_locked(path, lock_path) as fd:
        _jsonl_write(fd, rec)


@contextlib.contextmanager
def _jsonl_locked(path: str, lock_path: str):
    """Hold the file's exclusive lock and yield an append-mode fd on it.

    Round 3 (LIFE5). O_APPEND makes each os.write land at the end atomically, but it says nothing
    about the write LOOP: a short write in process A, followed by a complete record from process
    B, followed by A's suffix, produces one malformed line out of two good events — and
    `_jsonl_read` turns malformed JSON into a non-terminal `corrupt` record, so the casualty is a
    start/end/close silently DISAPPEARING from a lifecycle decision rather than failing it closed.
    An exclusive lock over the whole record makes the append atomic between processes; the
    readers' half of the fix is `ledger_corrupt`, which the admission and close paths refuse on.

    It is a context manager rather than part of the append because the outcome store needs a
    read-decide-append TRANSACTION under the same lock (§5.4): without one, two concurrent
    recorders both read "no prior row for this key" and both append, producing from the writer
    that enforces the key the very duplicate the key exists to prevent. A second lock file for
    the transaction would not do — these locks are per open file description, so a second fd on
    one lock path from one process deadlocks against itself.
    """
    lfd = os.open(lock_path, os.O_RDWR | os.O_CREAT, 0o644)
    fd = os.open(path, os.O_RDWR | os.O_CREAT | os.O_APPEND, 0o644)
    try:
        fcntl.flock(lfd, fcntl.LOCK_EX)
        yield fd
    finally:
        os.close(fd)
        try:
            fcntl.flock(lfd, fcntl.LOCK_UN)
        finally:
            os.close(lfd)


def _jsonl_write(fd: int, rec: dict) -> None:
    """One record, one line, onto an fd whose lock the caller already holds."""
    buf = (json.dumps(rec, sort_keys=True) + '\n').encode('utf-8')
    if tail_is_incomplete(fd):
        buf = b'\n' + buf
    while buf:
        buf = buf[os.write(fd, buf):]


def _jsonl_read(path: str) -> list[dict]:
    """Every parseable record, with an unparseable line reported as `corrupt` rather than dropped.

    Dropping it would make a hole indistinguishable from an absence, and every reader here asks
    presence/absence questions.
    """
    if not os.path.exists(path):
        return []
    out = []
    with open(path, encoding='utf-8', errors='replace') as fh:
        for ln in fh:
            ln = ln.strip()
            if not ln:
                continue
            try:
                out.append(json.loads(ln))
            except json.JSONDecodeError:
                out.append({'ev': 'corrupt', 'raw': ln[:200]})
    return out


def ledger_append(arc: str, ev: dict) -> None:
    os.makedirs(arc, exist_ok=True)
    ev = dict(ev)
    ev.setdefault('t', now())
    # Round 3 (LIFE6): stamp the clock OFFSET this record was written under. `mono` is uptime and
    # `coff` = wall - uptime, which is a CONSTANT for as long as one boot's clock runs untouched.
    # A change in it is an NTP step, a manual clock set, or a reboot -- and across any of those,
    # comparing two jobs' wall stamps establishes nothing about which ran first. Stamped HERE, at
    # the one chokepoint every writer goes through (loop.py and mutate.py both), so no caller can
    # forget it. `clock_discontinuity` is the reader's half.
    # Both are read from THIS process's clocks at write time, never derived from ev['t']: a caller
    # may anchor a record at any moment it likes (record_job backdates a whole span, mutate.py
    # anchors its row at the first mutant), and `t - monotonic` on a backdated stamp is not a clock
    # offset at all -- it is the backdating, and it would read as a clock jump on every such row.
    _mono = time.monotonic()
    ev.setdefault('mono', round(_mono, 3))
    ev.setdefault('coff', round(now() - _mono, 3))
    _jsonl_append(ledger_path(arc), ledger_lock_path(arc), ev)


def ledger_read(arc: str) -> list[dict]:
    return _jsonl_read(ledger_path(arc))


def verdict_keep_path(arc: str, job: str) -> str:
    """Where this arc keeps its own copy of one paid review verdict."""
    return os.path.join(arc, 'verdicts', f'{job}.json')


def keep_verdict(arc: str, job: str, out: str) -> str:
    """Snapshot a paid review verdict into the arc. Returns where it landed, or `''`.

    `close-round` has to know how many findings a round reported, and it used to read that off
    the verdict path the CALLER passed on the command line. That path is not ours: a later launch
    on ANOTHER track may legitimately reuse it (`review_name_collision` is scoped to one track and
    one round, so it does not speak for that case), and the caller may delete it between runs to
    tell "this launch landed a verdict" from "it did not". MEASURED 2026-10-26: the suite's own
    `launch()` does exactly that, track A round 1 became unclosable with `RC_FAILCLOSED`, and the
    refusal told the operator to "restore the verdict (this loop keeps a durable copy of every
    paid verdict)" -- a recovery that did not exist, since `shutil` appeared nowhere in this file.

    So the loop now keeps the copy its own refusal promised, taken at `end` where the run has been
    paid for and the verdict is on disk. A failure to snapshot never fails the run -- rc is about
    the review, not about our bookkeeping -- but it is printed, because the round may later refuse
    to close over it.
    """
    dest = verdict_keep_path(arc, job)
    try:
        os.makedirs(os.path.dirname(dest), exist_ok=True)
        with open(out, encoding='utf-8') as fh:
            text = fh.read()
        write_atomic(dest, text)
    # ValueError as well as OSError: a verdict holding invalid UTF-8 raises `UnicodeDecodeError`,
    # which is a ValueError, and letting it out would crash a run that has ALREADY been paid for
    # over a failure to keep a copy of its result. That is the one thing this handler exists to
    # prevent, so it must cover both ways the copy can fail rather than only the filesystem's.
    except (OSError, ValueError) as exc:
        print(f'loop.py: WARNING could not keep a copy of {out} at {dest}: '
              f'{type(exc).__name__}: {exc} — `close-round` will have to read the caller\'s copy, '
              'and will refuse the round if that is gone too', file=sys.stderr)
        return ''
    return dest


def write_atomic(path: str, text: str) -> None:
    """Replace `path` with `text` in one step: write a sibling temp file, fsync, rename.

    `open(path, 'w')` truncates first, so a reader arriving mid-write sees an empty or half-written
    artifact and a crash leaves it that way permanently. The rename is atomic within a directory,
    so the file is either the old content or the new one.
    """
    tmp = f'{path}.tmp.{os.getpid()}'
    with open(tmp, 'w', encoding='utf-8') as fh:
        fh.write(text)
        fh.flush()
        os.fsync(fh.fileno())
    os.replace(tmp, path)


def ledger_corrupt(events: list[dict]) -> int:
    """How many ledger records could not be parsed.

    Any non-zero answer means at least one event's CONTENT is unknown, and every lifecycle
    decision here is a question about the presence or absence of an event (is this round closed?
    did this job end?). An unreadable record cannot be assumed harmless, so admission and closure
    refuse on it instead of deciding over a hole.
    """
    return sum(1 for ev in events if ev.get('ev') == 'corrupt')


# ------------------------------------------------------------------- finding outcomes (§5)
# Decision 5: every review finding gets exactly one finding outcome, saved where it can be
# counted. The store is a second append-only JSONL beside `jobs.jsonl` rather than a new tool,
# because this module already owns the arc → track → round identity every outcome is filed under
# and a separate store would carry its own copy of that identity and could disagree with it.
#
# "Exactly one" is enforced here and not stated: `(arc, track, round, findingId)` is a uniqueness
# key, a byte-identical retry is idempotent, and a conflicting one refuses. An append-only file
# whose writer does not enforce its key accepts the retry's second row and double-counts it,
# which is how a decision becomes prose.
OUTCOMES = 'outcomes.jsonl'

#: The record of §5.3, in full. Every field is required: a store whose shape is optional cannot be
#: counted by severity or by file, which is what decision 5 asked for.
OUTCOME_FIELDS = ('arc', 'track', 'round', 'findingId', 'severity', 'file',
                  'lineStart', 'lineEnd', 'outcome', 'note')

#: The uniqueness key of §5.4. `findingId` alone is not it: the same finding id recurs across
#: rounds of one track by design, and the same round number recurs across tracks.
OUTCOME_KEY_FIELDS = ('arc', 'track', 'round', 'findingId')

#: Stamped on every row and deliberately OUTSIDE the key and outside the identity comparison: a
#: retry is the same decision recorded again, and a clock reading is not part of the decision. In
#: the ledger's unit (epoch seconds, as `t` is) so a report can order an outcome against the job
#: that produced the finding without converting between two time formats.
OUTCOME_STAMP = 'recordedAt'


def canonical_arc(arc: str) -> str:
    """The ONE spelling of an arc path that every store keys on, written AND read through it.

    `os.path.abspath` normalises `.`, `..` and a relative prefix and stops there: it does not
    resolve a symlink. Three stores here key rows on the arc, and all three used to compare
    `abspath` against an `abspath` of whatever spelling the writer happened to pass. A caller that
    reserved three case launches through a symlinked arc and then read the store through its real
    path saw NO rows, and the spend gate — which counts rows — handed out a fourth launch. The hole
    is in the KEY, so it is closed in the key: canonicalise at the boundary, store that value, and
    compare that value.
    """
    return os.path.realpath(os.path.abspath(arc))


def outcomes_path(arc: str) -> str:
    return os.path.join(arc, OUTCOMES)


def outcome_key(rec: Mapping) -> tuple:
    """The uniqueness key of §5.4, read out of a record.

    `round` is normalised to a string because the CLI parses it as an int while a hand-written or
    JSON-round-tripped row may carry either, and a key that compares 3 against '3' as different
    keys would let the same finding be recorded twice — the exact hole this key exists to close.
    """
    return tuple('' if rec.get(f) is None else str(rec.get(f)) for f in OUTCOME_KEY_FIELDS)


#: The declared fields that are not part of the key. These are what two rows for one finding can
#: disagree ABOUT, which is the whole of a conflict.
OUTCOME_VALUE_FIELDS = tuple(f for f in OUTCOME_FIELDS if f not in OUTCOME_KEY_FIELDS)


def outcome_identity(rec: Mapping) -> dict:
    """The part of a record that can CONFLICT: the declared fields outside the key.

    The key fields are deliberately absent. `outcome_admission` only ever compares rows whose
    keys are equal, so re-comparing them here cannot find a real difference — but it can find a
    spurious one, and did: `outcome_key` normalises `round` to a string so 3 and '3' are one
    finding, while a raw comparison of the same field called them a conflict. A row that
    round-tripped through JSON would then have refused its own retry, reporting a disagreement
    about the very field that identified it as the same record.
    """
    return {f: rec.get(f) for f in OUTCOME_VALUE_FIELDS}


def store_admission(existing: Sequence[Mapping], new: Mapping, key_fields: Sequence[str],
                    value_fields: Sequence[str]) -> tuple[str, Mapping | None, list[str]]:
    """The ONE identity rule both append-only stores in this module obey.

    Returns `(verdict, the conflicting prior row or None, the fields it differs on)`, where
    `verdict` is `'append' | 'idempotent' | 'refuse'`. The MESSAGE is composed by the caller, not
    here: each store's refusal names its own subject in its own words, and generalising the
    sentence would have made two stores share a message that describes neither. What is shared is
    the decision, which is the part that must not drift — the finding store and the run-summary
    store both claim "exactly one row per key", and two copies of that claim is the shape where a
    retry is idempotent in one store and a duplicate in the other.

    Pure, so the rule is exercisable without a filesystem and so a mutant that drops the key check
    is killed by an assertion about the DECISION rather than about a file's line count.

    Three answers and not two. `idempotent` is a success that appends nothing, which is what makes
    a retried record safe; collapsing it into `append` would double-count and collapsing it into
    `refuse` would make every interrupted recorder look like a conflict.

    A conflict is ANY difference in the declared value fields, not only in the one field a reader
    happens to care about. Two rows disagreeing about a severity, a file, a line range or a set of
    caught cases are two readings of one thing, and a report would answer from whichever it read
    first.

    The comparison runs against EVERY prior row for the key, not the last one: a file that already
    holds two conflicting rows (written by hand, or by a writer that predates this key) must not be
    made to look settled by a third row that happens to match one of them.

    `round` and every other key part are compared AS STRINGS, because the CLI parses some of them
    as ints while a JSON-round-tripped row may carry either, and a key that called 3 and '3'
    different keys would let one record be written twice — the exact hole the key closes.
    """
    def key_of(rec: Mapping) -> tuple:
        return tuple('' if rec.get(f) is None else str(rec.get(f)) for f in key_fields)

    def identity_of(rec: Mapping) -> dict:
        return {f: rec.get(f) for f in value_fields}

    key = key_of(new)
    prior = [r for r in existing if key_of(r) == key]
    if not prior:
        return 'append', None, []
    want = identity_of(new)
    differing = [r for r in prior if identity_of(r) != want]
    if not differing:
        return 'idempotent', None, []
    was = differing[0]
    return 'refuse', was, sorted(f for f in value_fields if was.get(f) != want.get(f))


def outcome_admission(existing: Sequence[Mapping], new: Mapping) -> tuple[str, str]:
    """May this finding outcome be appended? Returns `('append' | 'idempotent' | 'refuse', reason)`.

    The rule is `store_admission`; this composes the refusal decision 5 owes a reader.
    """
    verdict, was, fields = store_admission(existing, new, OUTCOME_KEY_FIELDS, OUTCOME_VALUE_FIELDS)
    if verdict == 'append':
        return 'append', ''
    if verdict == 'idempotent':
        return 'idempotent', (
            'finding {} of track {} round {} already carries outcome {!r} with identical '
            'details; recorded once, so this retry appends nothing'
            .format(new.get('findingId'), new.get('track'), new.get('round'), new.get('outcome'))
        )
    return 'refuse', (
        'finding {} of track {} round {} already carries outcome {!r}; this record says {!r} and '
        'differs on {}. Exactly one outcome per finding (decision 5), so the stored record stands '
        'and a correction is a deliberate edit of the store, never a second append.'
        .format(new.get('findingId'), new.get('track'), new.get('round'),
                was.get('outcome'), new.get('outcome'), ', '.join(fields))
    )


def outcome_duplicate_keys(records: Sequence[Mapping]) -> list[tuple]:
    """Keys appearing on more than one row, in the order they first appear.

    ANY repeat, identical rows included. `outcome_admission` never produces one, so a repeat here
    means something else wrote the file, and a store whose writer cannot be identified is not a
    store `close-round` may close over. Every report reads validated unique findings rather than
    counting rows, which is the other half of the same rule.
    """
    return store_duplicate_keys(records, OUTCOME_KEY_FIELDS)


def outcomes_read(arc: str) -> list[dict]:
    return _jsonl_read(outcomes_path(arc))


def outcomes_for_round(records: Sequence[Mapping], arc: str, track: str, rnd) -> list[dict]:
    """The rows filed under one (arc, track, round). Reads rows; counts nothing a run returned."""
    want = (canonical_arc(arc), str(track), str(rnd))
    return [dict(r) for r in records
            if (canonical_arc(str(r.get('arc') or '')), str(r.get('track')),
                str(r.get('round'))) == want]


def finding_id(job_name: str, index: int) -> str:
    """A finding's id: its verdict file's job name and its INDEX in that file's `findings` array.

    The review-output schema gives a finding no id of its own, and `facts-from-verdict.py` already
    dispositions findings by that index, so this is the id the loop already uses rather than a new
    one. Deriving it means the round's finding set comes from the artifacts the round produced; a
    hand-typed list of ids would be a second list that could simply omit the finding nobody wanted
    to disposition, which is the hole §5.5 closes.
    """
    return f'{job_name}#{index}'


def round_findings(events: Sequence[Mapping], track: str, rnd: int) -> tuple[list[str], list[str]]:
    """Every finding this round's reviewers reported, and every verdict that could not be read.

    Returns `(finding_ids, unreadable)`. `unreadable` is the fail-closed half: a review job that
    ended rc=0 and recorded a verdict path which is now missing or unparseable means the round's
    finding count is UNKNOWN, and unknown must not read as zero — zero is the one value that makes
    §5.5's requirement vacuous.

    Only review jobs that ended rc=0 are consulted. A review that failed or was quarantined wrote
    no verdict, and `close-round` already refuses over a job with no terminal event, so this adds
    no second opinion about liveness.
    """
    ends = {ev.get('job'): ev for ev in events if ev.get('ev') == 'end'}
    ids: list[str] = []
    unreadable: list[str] = []
    for ev in events:
        if ev.get('ev') != 'start' or ev.get('kind') != 'review':
            continue
        if str(ev.get('track')) != str(track) or str(ev.get('round')) != str(rnd):
            continue
        end = ends.get(ev.get('job'), {})
        if end.get('rc') != 0:
            continue
        # The arc's OWN copy first (`keep_verdict`, recorded on the end event), and the caller's
        # path only as the fallback for a ledger written before this loop kept one. The caller's
        # path is not ours to depend on: a later launch on another track may reuse it, and the
        # caller may delete it between runs. A row with neither readable is the fail-closed case
        # below, and it is now a genuinely lost verdict rather than a tidy caller.
        out = end.get('verdict') or ev.get('out')
        if not out:
            continue
        try:
            with open(out, encoding='utf-8') as fh:
                verdict = json.load(fh)
            findings = verdict['findings']
            if not isinstance(findings, list):
                raise TypeError('findings is not a list')
        except (OSError, ValueError, KeyError, TypeError) as exc:
            unreadable.append(f'{out} ({exc.__class__.__name__}: {exc})')
            continue
        name = str(ev.get('name'))
        ids.extend(finding_id(name, i) for i in range(len(findings)))
    # One id names one finding, so the set is what this returns. `review_name_collision` is what
    # keeps two DIFFERENT findings from ever sharing an id, and it refuses at launch rather than
    # here: since it also refuses a same-path re-run after a SUCCESSFUL review, at most one rc=0
    # review per name per round can exist and this deduplication is now defence over a ledger
    # written before that rule, not the thing standing between a rerun and a lost finding. It
    # cannot be the latter — a rerun overwrites the file, so the lost finding is not in `ids` to
    # deduplicate.
    return list(dict.fromkeys(ids)), unreadable


def unledgered_verdicts(arc: str, events: Sequence[Mapping]) -> list[str]:
    """Review verdicts sitting in the arc directory that no ledgered review names.

    MEASURED 2026-10-28 on arc `jobs/66648556/tmp`: 86 findings across the verdict files on disk,
    80 across the reviews the ledger recorded. The 6 were `process-critique.verdict.json`, launched
    with `run-codex.sh --one-off` -- which schedules into a THROWAWAY arc, so the real arc's ledger
    never heard of it. Every gate here reads the ledger, so a verdict the ledger never heard of is
    not undispositioned, it is ABSENT: nothing counts it and nothing can hold a round open over it.
    The write path (`review record`) only helps a session that calls it; this is the read that
    notices the session that did not.

    A verdict is identified by CONTENT, never by file name: any top-level `*.json` in the arc that
    parses as an object carrying a `findings` list, because that is exactly what `round_findings`
    counts and a naming convention is something a caller can skip. It is LEDGERED when a `review`
    start event on a real (non-one-off) track names it as `out`. A one-off-track event does not
    count: `arc_rounds` excludes that track, so its findings reach no gate either and it is the
    same hole by another route.

    Bound, stated rather than glossed: only the arc directory itself is scanned (not `verdicts/`,
    which holds the loop's own kept copies, and not subdirectories), so a verdict written somewhere
    else entirely is still invisible. The arc directory is where `run-codex.sh` and every arc in
    this skill write, which is what makes this the cheap read that catches the measured case.
    """
    # Only the start event's `out` is consulted: the end event's kept `verdict` always lives under
    # `verdicts/`, which this never scans, so reading it would be a branch no input can reach.
    named = {os.path.realpath(str(ev['out'])) for ev in events
             if ev.get('ev') == 'start' and ev.get('kind') == 'review' and ev.get('out')
             and str(ev.get('track')) not in ('', 'None', ONE_OFF_TRACK)}
    found: list[str] = []
    for path in sorted(glob.glob(os.path.join(glob.escape(arc), '*.json'))):
        try:
            with open(path, encoding='utf-8') as fh:
                doc = json.load(fh)
        except (OSError, ValueError):
            continue
        if not isinstance(doc, dict) or not isinstance(doc.get('findings'), list):
            continue
        if os.path.realpath(path) not in named:
            found.append(path)
    return found


def render_unledgered(arc: str, paths: Sequence[str]) -> str:
    """The remedy for `unledgered_verdicts`, one ready-to-run command per file."""
    return '\n'.join(
        '    python3 {}/loop.py review record --arc {} --track <T> --round <N> --name {} '
        '--party codex|claude --verdict {}'
        .format(HERE, shlex.quote(arc),
                shlex.quote(os.path.basename(p).split('.')[0] or 'review'), shlex.quote(p))
        for p in paths)


#: Why a review name is refused. One value per REMEDY, because the two refusals are not repaired
#: the same way: a review writing ELSEWHERE is given its own `--name`, while a name whose review
#: already succeeded is SPENT for this round and cannot be reused at any path, including its own.
CLASH_ELSEWHERE = 'elsewhere'
CLASH_AFTER_SUCCESS = 'after-success'


def review_name_collision(events: Sequence[Mapping], track: str, rnd, name: str,
                          out: str) -> tuple[str, str] | None:
    """`(why, the other review's verdict path)` when `name` is already spent in this round.

    A finding's id is `<name>#<index in that verdict's findings array>`, which is the id a human
    can type and the whole reason it is the display name rather than the ledger's job string.
    There are TWO ways one name mints one id for two findings, and they are refused separately
    because their remedies differ.

    `CLASH_ELSEWHERE` — two reviews of one round sharing a name while writing DIFFERENT verdict
    files. `outcome_coverage` reads one outcome row as covering both, and the round closes with a
    finding nobody dispositioned — §5.5's hole, re-opened by a name.

    `CLASH_AFTER_SUCCESS` — a second review under a name whose first review already ended `rc=0`,
    even at the SAME path. The rerun OVERWRITES that verdict and `round_findings` reads only the
    file that survives, so a finding the first run reported and the second did not disappears
    entirely, while an outcome already recorded against it becomes a stray that `outcome_coverage`
    deliberately does not refuse on. MEASURED 2026-10-26 by driving the head functions: a
    one-element list holding the first lens's first finding id after the first run, then
    `([], [])` once a successful same-name rerun wrote zero findings to the same path, with
    `outcome_coverage` reporting nothing missing. (That id is spelled out nowhere here on
    purpose: a finding id's `<lens>` plus index suffix carries the same shape as a pull-request
    citation, which `publishing_guard_test.py` refuses in a SHIPPED module by design -- its
    class 1. The guard's recorded remedy for a literal it cannot tell from a real one is to
    neutralise the literal rather than to widen the shape set, which is what this wording is.)

    A prior run that ended `rc != 0` — failed, or quarantined by a tree move, which moves its
    output to `<out>.tree-moved` — left this round no verdict to read, so it is the one case where
    the name may be reused at the same path. That re-run is what the same-path exemption was
    written for, and it is all the exemption now covers. A prior with no terminal event at all
    stays OPEN in the ledger and `close-round` already refuses over it, so that case is answered
    there rather than twice here.

    Refused at LAUNCH, where exactly one of the two runs is wrong and renaming it costs nothing.
    At close time both verdicts already exist and neither can be renamed without orphaning its
    artifact, so the only remaining move there is to refuse the close, which strands the round.

    ADJUDICATED 2026-10-26, against the alternative of changing the test that caught it. The
    reserved `ONE_OFF_TRACK` is EXEMPT, because both refusals above are statements about what
    happens when the round CLOSES -- `CLASH_ELSEWHERE` says the round would close with an
    undispositioned finding, and `CLASH_AFTER_SUCCESS` says a finding would vanish from the count
    `close-round` reads. Nothing closes a round on that track, `cmd_close_round` now refuses to,
    and no outcome is ever required of a one-off, so neither harm is reachable there and the rule
    was only ever charging a one-off for a gate it cannot reach. MEASURED: without the exemption
    the SECOND one-off under a given verdict basename was refused `RC_FAILCLOSED` forever, per
    user and per name, because the one-off arc is shared (`${TMPDIR}/cc-one-off-$(id -u)`) and
    round 1 of that track never closes -- `codex-opinion`, whose every call is a one-off, would
    have worked exactly once. The exemption is pinned in BOTH directions
    (`TestOneOffTrackIsExemptFromNameCollision`): a one-off name reruns, and the identical reuse
    on a real track still refuses.
    """
    if str(track) == ONE_OFF_TRACK:
        return None
    want = os.path.abspath(out) if out else ''
    ends = {ev.get('job'): ev for ev in events if ev.get('ev') == 'end'}
    for ev in events:
        if ev.get('ev') != 'start' or ev.get('kind') != 'review':
            continue
        if str(ev.get('track')) != str(track) or str(ev.get('round')) != str(rnd):
            continue
        if str(ev.get('name')) != str(name):
            continue
        other = ev.get('out')
        if other and os.path.abspath(str(other)) != want:
            return CLASH_ELSEWHERE, str(other)
        if ends.get(ev.get('job'), {}).get('rc') == 0:
            return CLASH_AFTER_SUCCESS, str(other or '')
    return None


def outcome_coverage(finding_ids: Sequence[str], rows: Sequence[Mapping]) -> tuple[list[str], list[str]]:
    """`(findings with no outcome, outcome rows naming no finding)`, both in order.

    The two directions are treated differently by `close-round`, and the asymmetry has a reason
    written here because it looks like an oversight. A MISSING outcome is the defect decision 5
    asks this gate to catch, so it refuses. A STRAY row is a mistyped id, and the store is
    append-only with a uniqueness key — so refusing on a stray would make the round permanently
    unclosable unless somebody hand-edited the evidence store, and a gate whose only remedy is
    editing its own evidence is worse than the typo it caught. A stray is therefore reported
    loudly and does not refuse; it cannot hide a missing outcome, because that is the other
    direction and is checked separately.
    """
    recorded = {str(r.get('findingId')) for r in rows}
    want = list(dict.fromkeys(str(i) for i in finding_ids))
    missing = [i for i in want if i not in recorded]
    stray = [i for i in sorted(recorded) if i not in set(want)]
    return missing, stray


#: What every rendered report says in words, per §5.7. MEASURED 2026-10-21: of the 1,310 findings
#: in this repository's 460 past verdict files, 0 carry a finding outcome, because outcomes existed
#: only as free text before this store. So a zero in any bucket below is an absence of RECORDS, not
#: an absence of findings, and a reader who does not know that reads the first report as evidence
#: that nothing was ever found. The sentence travels with the numbers rather than living in the
#: spec, because a report is read where the spec is not.
OUTCOME_COUNTS_BEGIN_NOTE = (
    'Counts begin at the first round recorded after this store shipped. Measured 2026-10-21, 0 of '
    'the 1,310 findings in this arc\'s 460 past verdict files carry an outcome, so no historical '
    'count is recoverable and a zero here means no record rather than no finding.'
)


def outcome_report(rows: Sequence[Mapping], arc: str, track: str | None = None,
                   rnd=None) -> dict:
    """Count finding outcomes by kind, by severity and by round, FROM THE ROWS (§5.6).

    Pure: it takes the rows a caller read and never reads the store itself, so the rule is
    exercisable with no filesystem and a mutant that drops one of the three groupings is killed by
    an assertion about a count rather than about output text.

    It counts rows and never what a run returned. The store is append-only with several writers —
    one `finding record` per finding, a retry that can land mid-report, an ordinary hand edit of a
    JSONL file — so a tally kept by the recorder agrees with the file only until something else
    writes it, and the disagreement is silent.

    Three groupings, each present because two stores can agree on the others:

    - `by_outcome` is zero-filled over `review_eval.FINDING_OUTCOMES`, so a bucket that is empty
      cannot be told from a bucket that was dropped. A value outside that closed set is NOT folded
      into a bucket: the recorder refuses one, so a row carrying one was written by something else,
      and it is named in `unknown_outcomes` where it is visible.
    - `by_severity` is open, because severity comes from the reviewer's own vocabulary and a new
      severity word is a reviewer change rather than a defect here.
    - `by_round` is keyed `<track>:<round>`, because a round number recurs across tracks and a
      count keyed on the number alone would add two tracks together.

    Uniqueness is enforced rather than assumed, which is the other half of
    `outcome_duplicate_keys`' rule that a report reads validated unique findings. A key appearing
    twice is counted ONCE and named in `duplicate_keys`; a key whose rows DISAGREE about the
    declared fields is counted not at all and named in `conflicting_keys`, because which of two
    readings to count is not a choice a report may make silently. `outcomes_record` produces
    neither, so both lists are empty for a store this tool wrote and loud for one it did not.
    """
    want_arc = canonical_arc(arc)
    scoped = []
    for rec in rows:
        if canonical_arc(str(rec.get('arc') or '')) != want_arc:
            continue
        if track is not None and str(rec.get('track')) != str(track):
            continue
        if rnd is not None and str(rec.get('round')) != str(rnd):
            continue
        scoped.append(rec)

    duplicate_keys = outcome_duplicate_keys(scoped)
    grouped: dict[tuple, list[Mapping]] = {}
    for rec in scoped:
        grouped.setdefault(outcome_key(rec), []).append(rec)

    conflicting = [k for k, rs in grouped.items()
                   if any(outcome_identity(r) != outcome_identity(rs[0]) for r in rs[1:])]
    conflicting_set = set(conflicting)

    by_outcome = {o: 0 for o in review_eval.FINDING_OUTCOMES}
    by_severity: dict[str, int] = {}
    by_round: dict[str, int] = {}
    unknown: list[str] = []
    total = 0
    for key, rs in grouped.items():
        if key in conflicting_set:
            continue
        rec = rs[0]
        total += 1
        outcome = str(rec.get('outcome'))
        if outcome in by_outcome:
            by_outcome[outcome] += 1
        elif outcome not in unknown:
            unknown.append(outcome)
        sev = str(rec.get('severity'))
        by_severity[sev] = by_severity.get(sev, 0) + 1
        bucket = '{}:{}'.format(rec.get('track'), rec.get('round'))
        by_round[bucket] = by_round.get(bucket, 0) + 1

    return {
        'arc': want_arc,
        'scope': {'track': track, 'round': rnd},
        'total': total,
        'by_outcome': by_outcome,
        'by_severity': by_severity,
        'by_round': by_round,
        'unknown_outcomes': unknown,
        'duplicate_keys': duplicate_keys,
        'conflicting_keys': conflicting,
    }


def render_outcome_report(rep: Mapping) -> str:
    """The report as text, carrying §5.7's sentence with the numbers it qualifies."""
    scope = rep.get('scope') or {}
    where = 'arc {}'.format(rep.get('arc'))
    if scope.get('track') is not None:
        where += ' track {}'.format(scope['track'])
    if scope.get('round') is not None:
        where += ' round {}'.format(scope['round'])
    lines = ['finding outcomes — {}'.format(where), 'total {}'.format(rep.get('total', 0)), '',
             'by kind:']
    for outcome, n in rep['by_outcome'].items():
        lines.append('  {:<20} {}'.format(outcome, n))
    lines += ['', 'by severity:']
    for sev, n in sorted(rep['by_severity'].items(), key=lambda kv: (-kv[1], kv[0])):
        lines.append('  {:<20} {}'.format(sev, n))
    lines += ['', 'by round:']
    for bucket, n in sorted(rep['by_round'].items()):
        lines.append('  {:<20} {}'.format(bucket, n))
    if rep['unknown_outcomes']:
        lines += ['', 'OUTSIDE the closed set of six (this tool refuses to write one, so these '
                      'rows were written by something else): ' + ', '.join(rep['unknown_outcomes'])]
    if rep['duplicate_keys']:
        lines += ['', 'REPEATED keys, counted once each: '
                      + '; '.join(repr(k) for k in rep['duplicate_keys'])]
    if rep['conflicting_keys']:
        lines += ['', 'CONFLICTING keys, counted NOT AT ALL because two rows disagree about what '
                      'happened: ' + '; '.join(repr(k) for k in rep['conflicting_keys'])]
    lines += ['', OUTCOME_COUNTS_BEGIN_NOTE]
    return '\n'.join(lines)


def store_record(path: str, row: Mapping, decide, stamp_field: str,
                 corrupt_subject: str) -> tuple[str, str]:
    """Read, decide and append ONE row as ONE transaction under one store's lock.

    Every append-only store in this skill goes through here, and that is the point: the read, the
    decision and the write are one transaction, which is the difference between ENFORCING a
    uniqueness key and merely checking it. Two copies of this sequence is the shape where one
    store takes its lock and the other forgets to.

    `decide(existing_rows, row) -> (verdict, reason)` is each store's own admission rule, so the
    refusal still names its own subject in its own words; what is shared is the transaction, never
    the sentence. A corrupt file REFUSES rather than appending, because an existing row for this
    key cannot be ruled out, and `corrupt_subject` is how that refusal says what could not be
    ruled out.

    `decide` may instead return `(verdict, reason, row)`, and THAT row is the one written. A store
    whose key holds a field it can only compute under the lock — the launch store's `attempt` —
    otherwise has to hand `decide` a placeholder and keep the real row somewhere on the side, and
    then the row admitted is not the row stored. Measured: every reservation reached the store
    with `attempt: 0` while its key had been checked against the real number, so two concurrent
    reservations of one case could both admit and both append, and nothing could join a
    reservation to anything keyed on the attempt it really was.

    `stamp_field` is written inside the transaction and AFTER the decision, so a refused or
    idempotent call writes nothing at all — including no clock reading a later reader could
    mistake for a row.
    """
    parent = os.path.dirname(path)
    if parent:
        os.makedirs(parent, exist_ok=True)
    with _jsonl_locked(path, path + '.lock') as fd:
        records = _jsonl_read(path)
        corrupt = ledger_corrupt(records)
        if corrupt:
            return 'refuse', (
                f'refusing to record: {path} holds {corrupt} unparseable row(s), so an existing '
                f'{corrupt_subject} cannot be ruled out'
            )
        decided = decide(records, row)
        if len(decided) == 3:
            verdict, reason, row = decided
        else:
            verdict, reason = decided
        if verdict == 'append':
            _jsonl_write(fd, dict(row, **{stamp_field: now()}))
        return verdict, reason


def outcomes_record(arc: str, rec: dict) -> tuple[str, str]:
    """Record one finding outcome. Returns `(verdict, reason)` from `outcome_admission`."""
    os.makedirs(arc, exist_ok=True)
    return store_record(outcomes_path(arc), rec, outcome_admission, OUTCOME_STAMP,
                        'outcome for this finding')


# ------------------------------------------------------------------ authored ranges (§3)
# Requirement 3: every commit range is approved by a party that did NOT write it. Until this store
# existed the rule was prose — `SKILL.md` calls treating a Codex verdict over its own range as a
# verdict "the one substitution that turns the entire loop into theatre" — and nothing recorded an
# author or a sha, so the property could not even be asked about after the fact. MEASURED
# 2026-10-28 against arc `jobs/66648556/tmp`: 9 Codex-authored ranges over 9 tasks, 0 Claude review
# artifacts, and no record from which a non-author review could be shown or disproved.
#
# ONE row per task, written by the tool that CREATES the range (`run-codex.sh` write mode) rather
# than by a session remembering afterwards. A write run that cannot record its range FAILS, so a
# missing row is a red run rather than a silent gap —
# memory couple-an-effect-to-its-write-at-the-chokepoint.
#
# Claude-authored ranges are deliberately NOT recorded. Authorship in this loop is BINARY, so
# Claude's set is the COMPLEMENT of the codex rows over the range being closed: every commit no
# codex row claims is Claude's. A second recording mechanism would need per-commit discipline from
# a session, and the session that forgets would leave a commit claimed by nobody — which under the
# complement rule is not a gap but a Claude commit demanding a CODEX review.
RANGES = 'ranges.jsonl'

#: The record, in full. `startSha`/`endSha` are what the launcher measured, not what a session
#: remembered: write mode already computes `START_SHA` before it hands the worktree to codex.
RANGE_FIELDS = ('arc', 'track', 'task', 'party', 'startSha', 'endSha')

#: The uniqueness key. `task` alone is not it — the same task label recurs across tracks of one arc
#: and across arcs — and `round` is deliberately absent, because a range is a span of commits and
#: not a thing that happens inside one round: a task resumed in round 3 is the same range.
RANGE_KEY_FIELDS = ('arc', 'track', 'task')

RANGE_VALUE_FIELDS = tuple(f for f in RANGE_FIELDS if f not in RANGE_KEY_FIELDS)

#: Outside the key and outside the identity comparison, for the same reason as `OUTCOME_STAMP`: a
#: retry is the same range recorded again and a clock reading is not part of the range.
RANGE_STAMP = 'recordedAt'

#: The two parties that can author or review anything here. Binary ON PURPOSE: the complement rule
#: above is sound only because there is no third author.
PARTIES = ('codex', 'claude')

#: What a review event carrying no `party` is credited to. This is a MEASUREMENT and not a
#: convenience default: every review in every ledger written before the field existed was a Codex
#: launch through `run-codex.sh`, there being no command that could record a Claude one. It is also
#: the fail-closed direction for the check that matters — a codex-authored range needs a CLAUDE
#: artifact, and an unlabelled event can never supply one.
DEFAULT_REVIEW_PARTY = 'codex'

#: The task name the complement is reported under. `range record` refuses it, so a session cannot
#: claim the complement by naming it and thereby hand its own commits an author of its choosing.
COMPLEMENT_TASK = '(complement)'


def ranges_path(arc: str) -> str:
    return os.path.join(arc, RANGES)


def range_admission(existing: Sequence[Mapping], new: Mapping) -> tuple[str, str]:
    """May this range row be appended? `('append' | 'idempotent' | 'refuse', reason)`.

    The rule is `store_admission`, which both other stores here obey; this composes the refusal in
    this store's own words. A conflicting row is refused rather than appended because the two
    readings disagree about WHO WROTE a commit, and the independence gate would then answer from
    whichever row it read first — the one question in this loop where reading the wrong row
    silently converts a real review into theatre.
    """
    verdict, was, fields = store_admission(existing, new, RANGE_KEY_FIELDS, RANGE_VALUE_FIELDS)
    if verdict == 'append':
        return 'append', ''
    if verdict == 'idempotent':
        return 'idempotent', (
            'task {} of track {} already records {}..{} authored by {}; recorded once, so this '
            'retry appends nothing'
            .format(new.get('task'), new.get('track'), str(new.get('startSha'))[:12],
                    str(new.get('endSha'))[:12], new.get('party'))
        )
    return 'refuse', (
        'task {} of track {} already records a range authored by {} ({}..{}); this record says {} '
        '({}..{}) and differs on {}. Exactly one author per task, so the stored row stands — a '
        'correction is a deliberate edit of the store, never a second append.'
        .format(new.get('task'), new.get('track'), was.get('party'),
                str(was.get('startSha'))[:12], str(was.get('endSha'))[:12], new.get('party'),
                str(new.get('startSha'))[:12], str(new.get('endSha'))[:12], ', '.join(fields))
    )


def store_duplicate_keys(records: Sequence[Mapping], key_fields: Sequence[str]) -> list[tuple]:
    """Keys appearing on more than one row, in first-appearance order. ANY repeat counts.

    `outcome_duplicate_keys` is this function over `OUTCOME_KEY_FIELDS` and stays as its own name
    because its refusal cites decision 5; the rule is here once so a second store cannot ship with
    a subtly different idea of what a duplicate is.
    """
    seen: dict = {}
    dupes = []
    for rec in records:
        key = tuple('' if rec.get(f) is None else str(rec.get(f)) for f in key_fields)
        seen[key] = seen.get(key, 0) + 1
        if seen[key] == 2:
            dupes.append(key)
    return dupes


def ranges_read(arc: str) -> list[dict]:
    return _jsonl_read(ranges_path(arc))


def ranges_for_arc(records: Sequence[Mapping], arc: str) -> list[dict]:
    """The rows filed under one arc, canonicalised at BOTH ends (see `canonical_arc`)."""
    want = canonical_arc(arc)
    return [dict(r) for r in records if canonical_arc(str(r.get('arc') or '')) == want]


def ranges_record(arc: str, rec: dict) -> tuple[str, str]:
    """Record one authored range. Returns `(verdict, reason)` from `range_admission`."""
    os.makedirs(arc, exist_ok=True)
    return store_record(ranges_path(arc), rec, range_admission, RANGE_STAMP,
                        'range for this task')


def other_party(party: str) -> str:
    """The party that did not write this, which is the only one whose review counts for it."""
    return 'claude' if str(party) == 'codex' else 'codex'


def range_verdict(commits: Sequence[str], rows: Sequence[Mapping],
                  review_parties: Sequence[str]) -> dict:
    """Who wrote each commit of one range, and whose review is still owed. PURE.

    `commits` is the range's own commit list, in order, as git reports it. `rows` are range rows
    whose `commits` key has already been resolved to the shas that row claims. `review_parties`
    are the parties with a readable review artifact in this arc.

    Three answers, and they are not interchangeable:

    - A commit claimed by MORE THAN ONE row is AMBIGUOUS and refuses. Two rows claiming one commit
      disagree about who wrote it, and the independence gate would answer from whichever it read
      first.
    - A commit claimed by EXACTLY ONE row is that row's party's work, and the row needs a review
      artifact from the OTHER party.
    - A commit claimed by NO row is the COMPLEMENT: Claude's, by the binary-authorship rule above,
      and it needs a CODEX review artifact. This is why no second recording mechanism is needed and
      also why a launcher that fails to write its row cannot open a hole — the commit does not
      vanish from the table, it moves to the complement and demands a review of the other party.

    A row claiming only commits OUTSIDE this range is reported in `outside` and contributes
    nothing: the rows of one arc legitimately span branches that already merged, and a range table
    that included them could never equal the pull request's own commit list.

    The bound this leaves open, stated rather than glossed: `review_parties` is ARC-scoped, so this
    proves the other party reviewed SOMETHING in this arc and not that it read this exact range.
    Scoping it per range would need a verdict's `reviewed.base`/`reviewed.head` to be trustworthy
    for document reviews, where the schema makes both `null` by design. The approved plan says "a
    review artifact in this arc whose party differs", and that is what this is.
    """
    want = list(dict.fromkeys(str(c) for c in commits))
    inside = set(want)
    seen = {str(p) for p in review_parties}
    claims: dict[str, list[str]] = {c: [] for c in want}
    table: list[dict] = []
    outside: list[str] = []
    for row in rows:
        task = str(row.get('task'))
        # An unlabelled row reads `codex` for the same reason an unlabelled review event does, and
        # here too that is the fail-closed direction: it demands a CLAUDE review of the range.
        party = str(row.get('party') or DEFAULT_REVIEW_PARTY)
        mine = {str(c) for c in (row.get('commits') or []) if str(c) in inside}
        if not mine:
            outside.append(task)
            continue
        for c in mine:
            claims[c].append(task)
        table.append(dict(task=task, authorParty=party, reviewParty=other_party(party),
                          startSha=row.get('startSha'), endSha=row.get('endSha'),
                          commits=[c for c in want if c in mine]))
    ambiguous = [(c, sorted(claims[c])) for c in want if len(claims[c]) > 1]
    complement = [c for c in want if not claims[c]]
    if complement:
        table.append(dict(task=COMPLEMENT_TASK, authorParty='claude', reviewParty='codex',
                          startSha=None, endSha=None, commits=complement))
    for entry in table:
        entry['reviewed'] = entry['reviewParty'] in seen
    missing = [e for e in table if not e['reviewed']]
    return dict(commits=want, table=table, ambiguous=ambiguous, complement=complement,
                outside=sorted(set(outside)), missing=missing,
                ok=(not ambiguous and not missing))


def git_range_commits(repo: str, rng: str) -> list[str]:
    """The commits of one `BASE..HEAD`, oldest first, as git itself reports them.

    `--reverse` so the table reads in the order the work happened, which is the order a human
    checking it against `git log` will scroll.
    """
    return [c.strip() for c in git(repo, 'rev-list', '--reverse', rng).splitlines() if c.strip()]


def resolve_range_rows(repo: str, rows: Sequence[Mapping]) -> tuple[list[dict], list[str]]:
    """Attach each row's commit list by asking git. `(resolved rows, unresolvable descriptions)`.

    A row whose two shas git cannot walk is UNRESOLVABLE and refuses rather than being skipped.
    Skipping it would move its commits into the complement and demand a Codex review of what may
    be Codex's own work — the exact substitution this store exists to prevent — so the one safe
    answer is to say which row could not be read and in which repository.
    """
    resolved: list[dict] = []
    bad: list[str] = []
    for row in rows:
        start, end = str(row.get('startSha') or ''), str(row.get('endSha') or '')
        if not start or not end:
            bad.append('task {} of track {} records no {} sha'
                       .format(row.get('task'), row.get('track'),
                               'start' if not start else 'end'))
            continue
        try:
            commits = git_range_commits(repo, f'{start}..{end}')
        except subprocess.CalledProcessError as exc:
            bad.append('task {} of track {} claims {}..{}, which git cannot walk in {} ({})'
                       .format(row.get('task'), row.get('track'), start[:12], end[:12], repo,
                               (exc.stderr or '').strip().splitlines()[:1] or 'no stderr'))
            continue
        resolved.append(dict(row, commits=commits))
    return resolved, bad


def check_ranges(arc: str, repo: str, rng: str, events: Sequence[Mapping],
                 rows: Sequence[Mapping]) -> tuple[dict | None, list[str]]:
    """The range verdict for `rng`, or `(None, why it could not be computed)`.

    Separated from the refusal text so that `close-round` and `converge` ask the SAME question and
    only their sentences differ. Two copies of this sequence is the shape where one command's
    independence rule drifts from the other's, and the one that drifts is whichever is run less.
    """
    try:
        commits = git_range_commits(repo, rng)
    except subprocess.CalledProcessError as exc:
        return None, ['git cannot resolve {!r} in {}: {}'
                      .format(rng, repo, (exc.stderr or '').strip() or 'no stderr')]
    if not commits:
        return None, ['{!r} names no commit in {} — a range table over an empty range proves '
                      'nothing, so this is refused rather than passed vacuously'.format(rng, repo)]
    resolved, bad = resolve_range_rows(repo, ranges_for_arc(rows, arc))
    if bad:
        return None, bad
    return range_verdict(commits, resolved, review_artifact_parties(events)), []


def render_range_refusal(verdict: Mapping) -> str:
    """Why this range does not satisfy requirement 3, naming every range and every commit.

    Named rather than counted: the remedy for an ambiguous commit is editing the store, and the
    remedy for an unreviewed range is a review — so a reader who is told only "2 problems" has to
    go and find out which of the two they are looking at.
    """
    lines: list[str] = []
    for sha, tasks in verdict['ambiguous']:
        lines.append('  commit {} is claimed by {} range rows ({}) — two rows disagree about who '
                     'wrote it, and the independence gate would answer from whichever it read '
                     'first.'.format(sha[:12], len(tasks), ', '.join(tasks)))
    for entry in verdict['missing']:
        if entry['task'] == COMPLEMENT_TASK:
            lines.append('  {} commit(s) are claimed by no range row, so they are CLAUDE-authored '
                         'by the complement rule and need a party=codex review artifact in this '
                         'arc: {}.'
                         .format(len(entry['commits']),
                                 ', '.join(c[:12] for c in entry['commits'][:8])
                                 + (', …' if len(entry['commits']) > 8 else '')))
        else:
            lines.append('  range {} ({}..{}, {} commit(s)) was authored by {} and has no '
                         'party={} review artifact in this arc — a verdict by the author over its '
                         'own range is the one substitution that turns the loop into theatre.'
                         .format(entry['task'], str(entry['startSha'])[:12],
                                 str(entry['endSha'])[:12], len(entry['commits']),
                                 entry['authorParty'], entry['reviewParty']))
    return '\n'.join(lines)


def review_artifact_parties(events: Sequence[Mapping], track: str | None = None,
                            rnd=None) -> set[str]:
    """Every party holding a SUCCESSFUL review artifact in this ledger.

    Only `rc=0` review jobs count: a review that failed or was quarantined wrote no verdict, and
    an independence gate satisfied by a failed review is the gate not existing.

    The reserved one-off track is excluded. A one-off is an UNATTRIBUTED call whose arc is shared
    per user (`run-codex.sh --one-off`), so counting it would let any session's unrelated
    `codex-opinion` call discharge another session's independence requirement.
    """
    ends = {ev.get('job'): ev for ev in events if ev.get('ev') == 'end'}
    parties: set[str] = set()
    for ev in events:
        if ev.get('ev') != 'start' or ev.get('kind') != 'review':
            continue
        if str(ev.get('track')) == ONE_OFF_TRACK:
            continue
        if track is not None and str(ev.get('track')) != str(track):
            continue
        if rnd is not None and str(ev.get('round')) != str(rnd):
            continue
        if ends.get(ev.get('job'), {}).get('rc') != 0:
            continue
        parties.add(str(ev.get('party') or DEFAULT_REVIEW_PARTY))
    return parties


#: The contract `run-codex.sh` hands `codex exec --output-schema`, which is therefore the contract
#: a Claude review artifact must also satisfy for `round_findings` to be able to count it.
REVIEW_SCHEMA_PATH = os.path.join(HERE, 'review-output.schema.json')


def review_schema_contract(path: str = REVIEW_SCHEMA_PATH) -> dict:
    """`{top, finding, severities, verdicts}` READ FROM the schema file, never retyped.

    `jsonschema` is not installed on this machine (measured 2026-10-28: `import jsonschema` raises
    `ModuleNotFoundError`), so the validation below is hand-rolled. A hand-rolled validator
    carrying its own copy of the field list would be a SECOND contract, free to drift from the one
    the launcher passes to codex — and the drift would show up as a Claude verdict this loop
    accepts and codex's own runs could never produce. The file is the contract; this reads it.
    """
    with open(path, encoding='utf-8') as fh:
        doc = json.load(fh)
    finding = doc['properties']['findings']['items']
    return dict(top=tuple(doc['required']),
                finding=tuple(finding['required']),
                severities=tuple(finding['properties']['severity']['enum']),
                verdicts=tuple(doc['properties']['verdict']['enum']))


def verdict_errors(doc, contract: Mapping) -> list[str]:
    """Every way `doc` fails the review-output contract, in order. Empty means it passes.

    Every way, and not the first: an artifact rejected one field at a time costs one round trip per
    field, and the party fixing it is a session that has already finished reviewing.
    """
    errs: list[str] = []
    if not isinstance(doc, Mapping):
        return [f'the verdict is a {type(doc).__name__}, not a JSON object']
    for field in contract['top']:
        if field not in doc:
            errs.append(f'missing required top-level field {field!r}')
    if 'verdict' in doc and doc['verdict'] not in contract['verdicts']:
        errs.append('verdict is {!r}; the schema allows {}'
                    .format(doc['verdict'], ' | '.join(contract['verdicts'])))
    findings = doc.get('findings')
    if 'findings' in doc and not isinstance(findings, list):
        errs.append(f'findings is a {type(findings).__name__}, not an array')
        findings = []
    for i, f in enumerate(findings or []):
        if not isinstance(f, Mapping):
            errs.append(f'findings[{i}] is a {type(f).__name__}, not an object')
            continue
        for field in contract['finding']:
            if field not in f:
                errs.append(f'findings[{i}] is missing required field {field!r}')
        if 'severity' in f and f['severity'] not in contract['severities']:
            errs.append('findings[{}].severity is {!r}; the schema allows {}'
                        .format(i, f['severity'], ' | '.join(contract['severities'])))
    return errs


# ------------------------------------------------------------ run summaries (§4.4, §4.5)
# `keep_verdict(baseline, candidate)` refuses when the baseline is `None`, and until this store
# existed NOTHING wrote a `RunSummary` anywhere: the keep rule would have refused every comparison
# forever, which reads as the gate working rather than as a missing producer. One JSON object per
# run, beside `outcomes.jsonl` in the same arc directory and NOT inside it — two stores in one file
# would make each one's uniqueness key evaluate the other's rows.
RUN_SUMMARIES = 'run-summaries.jsonl'

#: The uniqueness key. A run id is unique within an arc and an arc directory is per job, so the
#: two together are the identity; `runId` alone would collide the moment two arcs shared a store.
RUN_SUMMARY_KEY_FIELDS = ('arc', 'runId')

#: The persisted fields of a `RunSummary`, in `review_eval`'s own field order, camelCased for the
#: row. `catches`, `escape_cases` and `clean_cases` are deliberately ABSENT: S1 made them
#: properties of the sets they count, so persisting one would reintroduce the integer a caller
#: could supply — the exact shape that let a per-finding sum be passed where a per-case count
#: belongs.
RUN_SUMMARY_SET_FIELDS = (
    ('case_ids', 'caseIds'),
    ('caught_case_ids', 'caughtCaseIds'),
    ('scorable_case_ids', 'scorableCaseIds'),
    ('clean_case_ids', 'cleanCaseIds'),
)
RUN_SUMMARY_SCALAR_FIELDS = (
    ('false_alarms', 'falseAlarms'),
    ('case_manifest_hash', 'caseManifestHash'),
    ('malformed_findings', 'malformedFindings'),
    ('out_of_scope_findings', 'outOfScopeFindings'),
)

#: Everything a second row for one run could DISAGREE about: the summary itself and the judge that
#: produced part of it. `judge` is in here rather than outside it because two runs of one id that
#: used different models are two runs, not one recorded twice.
RUN_SUMMARY_VALUE_FIELDS = tuple(
    [row for _, row in RUN_SUMMARY_SET_FIELDS] + [row for _, row in RUN_SUMMARY_SCALAR_FIELDS]
) + ('judge',)

#: Stamped on every row, outside the key and outside the identity comparison, for the same reason
#: `OUTCOME_STAMP` is: a retry is the same result recorded again, and a clock reading is not part
#: of the result. Epoch seconds, as the ledger's `t` is.
RUN_SUMMARY_STAMP = 'recordedAt'


def run_summaries_path(arc: str) -> str:
    return os.path.join(arc, RUN_SUMMARIES)


def run_summaries_read(arc: str) -> list[dict]:
    return _jsonl_read(run_summaries_path(arc))


def run_summary_row(arc: str, run_id: str, summary, judge: Mapping | None) -> dict:
    """One `RunSummary` as a row. The ONLY serialiser, so there is one field mapping.

    `judge` is REQUIRED and may be `None`, which is a recorded fact rather than a missing key: a
    run that did no near-miss judging says so, and a reader can tell that from a run whose judge
    was never written down. S8 fills it with the model identity and effort it used.
    """
    row = {'arc': canonical_arc(arc), 'runId': run_id,
           'judge': dict(judge) if judge is not None else None}
    for attr, key in RUN_SUMMARY_SET_FIELDS:
        row[key] = list(getattr(summary, attr))
    for attr, key in RUN_SUMMARY_SCALAR_FIELDS:
        row[key] = getattr(summary, attr)
    return row


def run_summary_from_row(row: Mapping):
    """A row back into a `RunSummary`, through its own constructor so its refusals still fire.

    The sets come back as TUPLES, not lists: `RunSummary` is a frozen dataclass compared by value,
    and a list-valued field would make a round-tripped summary unequal to the one that was written
    while every member matched.
    """
    kwargs = {attr: tuple(row[key]) for attr, key in RUN_SUMMARY_SET_FIELDS}
    kwargs.update({attr: row[key] for attr, key in RUN_SUMMARY_SCALAR_FIELDS})
    return review_eval.RunSummary(**kwargs)


def run_summary_admission(existing: Sequence[Mapping], new: Mapping) -> tuple[str, str]:
    """May this run summary be appended? Same rule as the finding store, its own words."""
    verdict, was, fields = store_admission(existing, new, RUN_SUMMARY_KEY_FIELDS,
                                           RUN_SUMMARY_VALUE_FIELDS)
    if verdict == 'append':
        return 'append', ''
    if verdict == 'idempotent':
        return 'idempotent', (
            'run {!r} of arc {} is already recorded with an identical summary; recorded once, so '
            'this retry appends nothing'.format(new.get('runId'), new.get('arc'))
        )
    return 'refuse', (
        'run {!r} of arc {} is already recorded and this summary differs on {}. One run id, one '
        'result: a second reading of one run is two answers rather than a correction, and the keep '
        'rule compares these sets across runs, so a disagreement between them does not fail — it '
        'answers wrongly. The stored row stands.'
        .format(new.get('runId'), new.get('arc'), ', '.join(fields))
    )


def run_summaries_record(arc: str, row: dict) -> tuple[str, str]:
    """Record one run summary. Read, decide and append as ONE transaction under the store's lock."""
    os.makedirs(arc, exist_ok=True)
    return store_record(run_summaries_path(arc), row, run_summary_admission, RUN_SUMMARY_STAMP,
                        'summary for this run')


def run_summary_baseline(records: Sequence[Mapping], arc: str) -> dict | None:
    """The most recently recorded summary of `arc`, or `None`.

    `None` and never an empty summary. An empty one would let the keep rule's like-with-like gate
    pass vacuously — identical (empty) case sets compare equal on both halves — which is the one
    answer a gate must not give in the absence of its own input.

    "Most recent" is by `recordedAt`, with the file's own order breaking a tie, because two rows
    can share a clock reading on a fast machine and append order is the only remaining evidence.
    """
    want = canonical_arc(arc)
    mine = [r for r in records if canonical_arc(str(r.get('arc') or '')) == want]
    if not mine:
        return None
    best = max(range(len(mine)), key=lambda i: (float(mine[i].get(RUN_SUMMARY_STAMP) or 0.0), i))
    return dict(mine[best])


def run_summary_from_scores(doc: Mapping):
    """Build a `RunSummary` from a scored-run document, THROUGH `build_run_summary`.

    Never field by field. That producer derives `caught_case_ids` and `scorable_case_ids` from one
    reading of one set of scores and refuses a duplicate case id; a recorder assembling the row
    itself could write a summary whose two sets came from different readings, and the keep rule
    compares exactly those two sets across runs.
    """
    scores = []
    for raw in doc['escapeScores']:
        scores.append(review_eval.CaseScore(
            case_id=str(raw['caseId']),
            caught=bool(raw['caught']),
            verdicts=tuple(raw['verdicts']),
            near_misses=tuple(raw['nearMisses']),
            malformed=int(raw['malformed']),
            out_of_scope=int(raw['outOfScope']),
            scorable=bool(raw['scorable']),
        ))
    clean = {str(k): int(v) for k, v in doc['cleanFalseAlarms'].items()}
    return review_eval.build_run_summary(scores, clean, str(doc['caseManifestHash']))


def record_job(arc: str, track: str, rnd: int, kind: str, name: str, t_start: float, t_end: float,
               rc: int, span_s: float | None = None, **extra) -> str:
    """Ledger a job that ran outside `run` (mutate.py uses this): start + end events.

    `span_s` is the MONOTONIC duration when the caller measured one, and it goes on the end event
    where `rows_from_ledger` reads it — so the row's length survives a wall-clock correction that
    lands mid-job. It stays optional because a hand-written or legacy record genuinely has none,
    and the reader already treats that case as wall-clock evidence rather than a measurement.
    """
    job = f'{track}.r{rnd}.{name}.{int(t_start * 1000)}.{os.getpid()}'
    ledger_append(arc, dict(ev='start', t=t_start, job=job, track=track, round=rnd, kind=kind, name=name,
                            cpu=extra.pop('cpu', 'light'), t_req=extra.pop('t_req', t_start),
                            queued_s=extra.pop('queued_s', 0.0), **extra))
    end_ev = dict(ev='end', t=t_end, job=job, rc=rc, reason=extra.get('reason', ''))
    if span_s is not None:
        end_ev['span_s'] = max(0.0, float(span_s))
    ledger_append(arc, end_ev)
    return job


# -------------------------------------------------------------------------- locks
def lock_dir() -> str:
    return os.environ.get('CC_LOCK_DIR') or os.path.expanduser('~/.claude/ops/locks')


def tree_lock_name(tree: str) -> str:
    """One lock per WORKTREE, keyed on its TOPLEVEL — never on the path the caller happened to pass.

    Keying on the passed path let `--tree /repo` and `--tree /repo/sub` take two DIFFERENT locks on
    the same worktree, so a reader and a `--write` job could each believe it held "the tree lock"
    while the writer edited files under the reader's feet — the precise corruption this scheduler
    exists to prevent. Measured before this fix: the two paths hashed to tree-5c1a7c92... and
    tree-189ab888....
    Distinct worktrees (a `git worktree add` snapshot included) have distinct toplevels, so this
    must NOT collapse them, and does not. A directory that is not in a git tree has no toplevel and
    keeps its realpath, which is still exactly one lock per tree.
    """
    real = os.path.realpath(tree)
    try:
        top = git(real, 'rev-parse', '--show-toplevel').strip()
        if top:
            real = os.path.realpath(top)
    except (subprocess.CalledProcessError, FileNotFoundError, OSError):
        pass  # not a git tree (or git is gone): the path itself is the tree
    return 'tree-' + hashlib.sha1(real.encode('utf-8')).hexdigest()[:16] + '.lock'


def path_lock_name(path: str, prefix: str) -> str:
    """One lock per literal PATH — deliberately NOT `tree_lock_name`.

    A mutation copy dir lives INSIDE the repo (gitignored), so `tree_lock_name` would resolve it
    to the git toplevel and hand back the TREE's lock. Taking that exclusively to protect one copy
    dir would serialise every reader in the arc, and two batches with two different copy dirs
    would still collide on it. Hashing the realpath names exactly one directory and nothing else.
    """
    return f'{prefix}-' + hashlib.sha1(os.path.realpath(path).encode('utf-8')).hexdigest()[:16] + '.lock'


class Locks:
    """Acquire the job's locks in a fixed order (tree, extras, then cpu); release on exit.

    tree_mode / cpu_mode / each extra mode ∈ {'ex', 'sh', None}.  Uses flock(2): a holder that
    dies releases.
    """

    def __init__(self, tree: str | None, tree_mode: str | None, cpu_mode: str | None,
                 holder: str = '', max_queue_s: float | None = None,
                 extra: list[tuple[str, str]] | None = None):
        self.specs = []
        if tree and tree_mode:
            self.specs.append((os.path.join(lock_dir(), tree_lock_name(tree)), tree_mode))
        # Extras sit between the tree and the cpu lock so that EVERY holder takes the whole set in
        # one order. Order is the only thing standing between two batches that each want a tree
        # lock and a resource lock and a deadlock; it costs nothing to fix it here.
        for name, mode in (extra or []):
            self.specs.append((os.path.join(lock_dir(), name), mode))
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
                    # t0 is monotonic, so the elapsed check must be monotonic too. It used to read
                    # `now() - t0` (wall epoch minus uptime ≈ 1.79e9), which exceeded EVERY deadline on
                    # the first contended poll: `--max-queue 3600` refused instantly. The test that
                    # covered this asserted only "refused", which that bug also satisfies — so it is
                    # now asserted to have WAITED as well.
                    if self.max_queue_s is not None and time.monotonic() - t0 > self.max_queue_s:
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
        # Clamped for the same reason the two span_s sites are: every consumer of this number
        # (L5's queue lever, the round profile, `--max-queue` reporting) treats it as a
        # DURATION, and a negative duration silently subtracts from the arc's measured wait
        # instead of failing. The clock that produces one is not reachable in production --
        # monotonic() is monotonic -- but the invariant is free and the alternative is a
        # profile that under-reports the very contention it exists to find.
        self.queued_s = max(0.0, time.monotonic() - t0)
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


def round_lock_name(arc: str, track: str, rnd) -> str:
    """One lock per (arc, track, round) — the admission/closure lock.

    Keyed on the arc's REAL path so two spellings of one arc cannot take two locks, and hashed
    because a track name is free text (a `/` in it would name a directory that does not exist).
    """
    key = '\0'.join((os.path.realpath(arc), str(track), str(rnd)))
    return 'round-' + hashlib.sha256(key.encode('utf-8')).hexdigest()[:16] + '.lock'


def lock_dir_ready() -> str | None:
    """None if the lock directory exists and can be created, else the reason it cannot.

    Called BEFORE taking a round lock so an unusable lock directory refuses with RC_LOCK — the
    same answer the tree/CPU locks give — instead of escaping as a traceback from inside the
    context manager. A scheduler that cannot lock must refuse, never run unlocked.
    """
    try:
        os.makedirs(lock_dir(), exist_ok=True)
        return None
    except OSError as e:
        return str(e)


@contextlib.contextmanager
def round_lock(arc: str, track: str, rnd):
    """Serialize a round's ADMISSION against its CLOSURE.

    Round 3 (LIFE2/LIFE4). Launch admission read the ledger and closure wrote to it with nothing
    between them: `close-round` could check for unfinished jobs, compute a profile and append the
    close while another `run` was appending queued/start events for that same round. The close then
    described a round it did not contain, and the gate for round N+1 opened over a job that was
    still holding trees and CPU.

    This lock is held only across the DECISION plus the durable record of it — the queued event on
    the launch side, the close event on the closing side. It is deliberately NOT held across the
    child's run: doing that would serialize the whole panel and undo the concurrency this
    scheduler exists to create.
    """
    os.makedirs(lock_dir(), exist_ok=True)
    fd = os.open(os.path.join(lock_dir(), round_lock_name(arc, track, rnd)), os.O_RDWR | os.O_CREAT, 0o644)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX)
        yield
    finally:
        try:
            fcntl.flock(fd, fcntl.LOCK_UN)
        finally:
            os.close(fd)


def admission_decision(closed: bool, corrupt: int) -> tuple[bool, str]:
    """May a job be admitted into this round? A pure rule, so it can be swept in both directions.

    Independent of the lever gate, which asks about the PREVIOUS round. This asks about the round
    being launched into: a closed round is sealed, because its profile and its close record are
    already written and a job admitted afterwards is work no artifact accounts for.
    """
    if corrupt:
        return False, (f'the ledger holds {corrupt} unparseable record(s), so the presence of a close '
                       'or of a terminal event cannot be established — refusing rather than deciding '
                       'over a hole. Repair or archive the ledger first.')
    if closed:
        return False, ('this round is already CLOSED: its profile and lever record are written, so a job '
                       'admitted now would be work no artifact accounts for, and the next round\'s gate '
                       'would open over it. Launch into the NEXT round instead.')
    return True, ''


def admit_into_round(events: Sequence[Mapping], track: str, rnd) -> tuple[bool, str]:
    """May work be added to this round? The ONE call site of `admission_decision`.

    Two commands add work to a round — `cmd_run` launching a job and `cmd_review` filing a review
    artifact — and before this helper each carried its own copy of the pair (`round_status` for
    the seal, `ledger_corrupt` for the hole). Two copies is the shape where one command checks the
    seal and the other forgets, and the one that forgets is whichever is used less, which is the
    newer of the two by construction. It also made the mutant that bypasses admission arm at two
    sites, so a kill no longer isolated either: `loop.mutants.json`'s M64 anchors HERE, and it now
    breaks both commands at once, which is the property worth pinning.

    Takes the events the caller already read under the round lock rather than reading them again:
    the whole point of the lock is that one snapshot answers every admission question in the
    transaction, and a second read inside it could answer differently.
    """
    return admission_decision(round_status(events, track, rnd)['closed'], ledger_corrupt(events))


def lock_modes(cpu: str, has_tree: bool, writes_tree: bool) -> tuple[str | None, str | None]:
    """The (tree, cpu) lock modes for a job.

    `writes_tree` is REQUIRED and never defaulted on purpose: it is the fact that decides whether
    a reader can safely run beside this job, and a default would let a new call site inherit
    "read-only" silently. Pass `tree_writing(kind, argv)`.

    The `kind` is deliberately NOT a parameter. It used to be, as a second `kind == 'write'`
    disjunct beside `writes_tree`, and that made "a write job writes" true in two places at once:
    `tree_writing` already answers it unconditionally, so the copy here could be deleted with no
    test able to see it (measured — mutant M5 SURVIVED against the whole suite). One fact, one
    owner: `tree_writing` decides, this function only spends the answer.
    """
    tree_mode = None
    if has_tree:
        tree_mode = 'ex' if writes_tree else 'sh'
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


# The ONLY untracked entries a snapshot may legitimately carry are the ones cmd_snapshot installs
# itself after `git worktree add`. Both the installer and the reuse check read this tuple, so the
# allowlist can never name something nothing creates, nor miss something the installer adds.
SNAPSHOT_INSTALLED = ('node_modules',)


def snapshot_pollution(path: str, repo: str) -> list[str]:
    """Untracked entries in `path` that are NOT an install link this command made itself.

    Round 3 (CORR2): reuse checked `git status --untracked-files=no`, so an untracked entry was
    tolerated wholesale on the grounds that the node_modules link is untracked. An untracked
    importable module or an AGENTS.md changes what every lens READS while HEAD is unchanged, and
    the reuse path then certified the directory as the pinned revision. Measured before this fix:
    reuse returned 0 and the next review read the untracked file.

    The carve-out is gated on a LIVE predicate, never on the name: an allowlisted entry counts as
    an install link only while it is still a symlink resolving to the source repo's own copy. A
    real directory (or a file) by that name is pollution like anything else.
    """
    others = git(path, 'ls-files', '--others', '--exclude-standard', '-z')
    bad = []
    for rel in sorted(filter(None, others.split('\0'))):
        top = rel.split('/', 1)[0]
        if top in SNAPSHOT_INSTALLED:
            here, there = os.path.join(path, top), os.path.join(repo, top)
            if os.path.islink(here) and os.path.realpath(here) == os.path.realpath(there):
                continue
        bad.append(rel)
    return bad


# -------------------------------------------------------------------- gate (pure)
def gate_decision(prev_closed: bool, triggered: set, dispositioned: set) -> tuple[bool, set]:
    """Pass iff the round that must be closed IS closed and every TRIGGERED lever is dispositioned."""
    missing = set(triggered) - set(dispositioned)
    return (prev_closed and not missing), missing


# ------------------------------------------------------- the preflight (round 1's gate)
# "until it is clean" is not a stopping condition, it is the absence of one. A BOUNDED stop names a
# number (a round ceiling), the artifact that ends the loop (a census, a last panel), or the finding
# class that may reopen it ("a new production-risk finding"). The banned forms below are the ones
# measured to run a region for rounds after it stopped paying -- memory convergence-loop-speed-rules
# recorded 15->10->14->9->7->6 findings across four rounds of one region under exactly this wording.
UNBOUNDED_STOP_RE = re.compile(
    r'until\s+(?:there\s+are\s+)?(?:no|zero)\b|until\s+(?:it\s+is\s+)?clean\b'
    r'|only\s+lows?\b|(?:till|until)\s+converg|repeat\s+until|no\s+more\s+findings', re.I)
# What counts as naming a bound. Deliberately generous about WORDING -- this gate exists to make the
# author write a bound, not to score its quality -- but not about SHAPE. An earlier version accepted
# a bare `\d`, and because it was consulted BEFORE the banned-form check, any stray digit excused an
# explicitly open-ended stop: measured, `"repeat until no findings remain, across 3 tracks"` PASSED,
# as did `"until only lows remain"` with any number appended. A number is only a bound when it
# counts the thing being bounded (rounds, panels, iterations) or is attached to a ceiling word, so
# "3 tracks" no longer buys an exit. The limit that remains, stated rather than hidden:
# `--stop "2 rounds maybe"` still passes. The ledger's reader is the check on that, not this regex.
STOP_BOUND_RE = re.compile(
    r'(?:max|at\s+most|no\s+more\s+than|ceiling|cap(?:ped)?|budget|limit|within|after)\D{0,24}\d'
    r'|\d+\s*(?:more\s+)?(?:rounds?|panels?|iterations?|passes|lenses)\b'
    r'|round\s+\d+\s+is\s+the\s+last|last\s+panel|census'
    r'|no\s+new\s+(?:high|critical|production|prod)|production-risk|bounded|first\s+green', re.I)


def thin_answer(text: str | None) -> str | None:
    """Why this preflight answer is not an answer, or None when it is one.

    A required field with a filled-in blank in it buys nothing -- it converts the gate into a
    keystroke. Refusing the blank is the whole difference between a prompt and a mechanism.
    """
    t = (text or '').strip()
    if not t:
        return 'empty'
    if t.lower().strip('.').strip() in PREFLIGHT_FILLER:
        return f'filler ({t!r}) -- say the actual answer, or say why the question does not apply here'
    if len(t) < 12:
        return f'too short at {len(t)} chars to be an answer'
    return None


def repeated_answers(answers: dict) -> str | None:
    """Which answer was pasted into more than one field, or None when all six are distinct.

    Six required fields will accept six copies of one sentence: measured, "not applicable here" in
    every field cleared thin_answer (19 chars, not a listed filler word). That is the same
    keystroke-instead-of-thought the field validation exists to refuse, one level up -- the six
    questions are different questions, so one answer cannot be the honest answer to all of them.
    Compared on normalised whitespace and case so re-punctuating a paste does not defeat it.
    """
    seen: dict[str, list[str]] = {}
    for f in PREFLIGHT_FIELDS:
        key = ' '.join((answers.get(f) or '').lower().split()).strip('.')
        if key:
            seen.setdefault(key, []).append(f)
    dupes = {k: v for k, v in seen.items() if len(v) > 1}
    if not dupes:
        return None
    key, fields = max(dupes.items(), key=lambda kv: len(kv[1]))
    named = ', '.join('--' + f.replace('_', '-') for f in fields)
    return (f'{named} are the same answer ({key[:60]!r}) -- they are different questions; '
            'answer each one, or say why that question does not apply to this workflow')


def unbounded_stop(text: str | None) -> str | None:
    """Why this stopping condition is not bounded, or None when it is.

    One rule: the stop must NAME a bound. This does not weaken the convergence gate (every finding
    still gets a recorded disposition); it forbids the loop whose only exit is "run it again".
    """
    t = (text or '').strip()
    if not t:
        return 'empty'
    # The live bug was TWO defects and only one of them lives here. The order was reversed (a bound
    # anywhere returned None before the ban was looked at) AND STOP_BOUND_RE accepted a bare digit,
    # so "across 3 tracks" bought an exit from "repeat until no findings remain". Only the second
    # one carries behaviour. Measured over 139 generated stop strings (every banned form x every
    # bound shape): with the regex as tightened above, the two orders differ on NOTHING -- and they
    # cannot, since `banned and not bound` is reachable only when `bound` is falsy, which is exactly
    # when the early return would not have fired. The order below is kept because it is the honest
    # reading order and it stays correct if the regex is ever loosened again; it is not the guard.
    # The guard is the SHAPE rule in STOP_BOUND_RE, and that is what M80 arms against.
    bound = STOP_BOUND_RE.search(t)
    banned = UNBOUNDED_STOP_RE.search(t)
    if banned and not bound:
        return (f'"{banned.group(0)}" is an open-ended form and the stop names no bound beside it')
    if bound:
        return None
    return ('names no bound -- give a round ceiling, the census/last-panel that ends the region, '
            'or the finding class that may reopen it')


def preflight_decision(rnd: int, has_preflight: bool, paid_jobs: int, track: str = '') -> tuple[bool, str]:
    """May round 1 launch? Pass iff the preflight is on record, or the arc already paid for the loop.

    Why this gate is HERE and not at a round boundary: the round-boundary machinery (close-round +
    lever dispositions) cannot fire until a round has been paid for -- `gate()` passed round 1
    unconditionally, so the earliest an efficiency question could be asked was AFTER the first
    round's bill. Measured twice (memory optimize-the-loop-unprompted): a directive telling the
    session to optimise loops sat in CLAUDE.md and in memory, and both times the session hand-rolled
    a serial loop anyway and profiled only when the user asked. This is the same question moved to the
    only moment its answer is still free.

    `paid_jobs` is the GRANDFATHER clause and it is derived from the ledger, never from a list of
    arc names: an arc that has already launched review/write jobs committed to its process before
    this gate existed, and refusing it now wedges live work without saving any. It counts review and
    write jobs only -- a scoped vitest run is not committing to a process, so a brand-new arc cannot
    buy its way past the gate by running one test first.
    """
    if rnd != 1:
        return True, 'not round 1 -- the close-round chain governs every later round'
    if track == ONE_OFF_TRACK:
        # The preflight asks what a REPEATING workflow puts on its critical path, what batches and
        # what parallelises. A one-off has no second round to optimise, so there is no such answer
        # to give -- and demanding one made every fresh one-off arc unusable: measured, a
        # `CC_ONEOFF_ARC=<new dir> run-codex.sh --one-off ...` exited 6 with "round 1: no efficiency
        # preflight on record" before codex was ever invoked, and the arc is created per user per
        # machine, so the FIRST one-off on any box hit it. The exemption is decided HERE, by the
        # gate, and never by the launcher writing itself a record to get past its own gate.
        return True, f'round 1 on the reserved {ONE_OFF_TRACK!r} track -- a single call is not a loop to preflight'
    if has_preflight:
        return True, 'round 1: efficiency preflight on record'
    if paid_jobs:
        return True, (f'round 1: no preflight, but this arc has already launched {paid_jobs} '
                      'review/write job(s), so it committed to this process before the gate existed '
                      '-- GRANDFATHERED (refusing now would wedge live work and save nothing)')
    return False, 'round 1: no efficiency preflight on record, and this arc has paid for nothing yet'


def preflight_of(events: list[dict]) -> dict | None:
    """The arc's last preflight record, or None. Per ARC, not per track: the process is the arc's."""
    found = [ev for ev in events if ev.get('ev') == 'preflight']
    return found[-1] if found else None


def stillborn_jobs(events: list[dict]) -> set:
    """Jobs that emitted `queued` and never started -- they spent nothing and prove nothing.

    `queued` lands before the lock wait, so a job REFUSED at the lock sits in the ledger having
    never run. Both the preflight's grandfather clause and the cadence gate's rate must subtract
    them, and they said so in two byte-identical copies until this extraction -- which silently
    un-armed the mutant guarding the rule, since `mutate.py` needs a UNIQUE site to arm at all. A
    duplicated invariant is not merely repetition here: it disables its own guard.
    """
    started = {ev.get('job') for ev in events if ev.get('ev') == 'start'}
    return {ev.get('job') for ev in events if ev.get('ev') == 'refused'} - started


def paid_review_jobs(events: list[dict]) -> int:
    """Review/write jobs this arc actually launched -- the evidence it committed to a process.

    `queued` lands before the lock wait, so a job REFUSED at the lock emits `queued` and then
    `refused` without ever starting. It spent nothing, so it is not evidence of anything and is
    subtracted here: counting it would let a fresh arc grandfather itself on a job that never ran.
    A job that started and then failed still counts -- it paid.

    `mutant` is deliberately NOT a paying kind even though it IS a gated one (see GATED_KINDS): a
    mutation battery is an expense the preflight exists to ask about, never a licence to skip it.
    """
    stillborn = stillborn_jobs(events)
    return sum(1 for ev in events
               if ev.get('ev') == 'queued' and ev.get('kind') in PAYING_KINDS
               and ev.get('job') not in stillborn)


# Kinds whose round-1 launch owes a preflight. `mutant` is here because an unbounded mutation
# battery is one of the expensive loops the user named by name; `vitest`/`tsc`/`ci` are not, because a
# scoped test run is not a process commitment and gating it would only teach people to run one first.
GATED_KINDS = ('review', 'write', 'mutant')
# Kinds that count as having PAID for the loop (the grandfather clause). A strict subset of
# GATED_KINDS on purpose -- see paid_review_jobs.
PAYING_KINDS = ('review', 'write')

# 'preflight' is deliberately absent: it is a per-ARC record, not a track's history, and every
# consumer of TRACK_EVENTS asks a per-track question (which round closed, which lever was
# dispositioned). preflight_of() reads the ledger directly instead. Not an omission.
TRACK_EVENTS = ('queued', 'start', 'end', 'refused', 'round-close', 'lever')


# ------------------------------------------------- the cadence gate (what a REPEAT owes)
# GATED_KINDS waves `vitest`/`tsc`/`ci` through on the grounds that "a scoped test run is not a
# process commitment". That is true of ONE run and false of the twenty-fifth, and the difference is
# structurally invisible to a gate keyed on KIND: every instance passes the per-instance question
# while the AGGREGATE is the bill. Measured 2026-09-07 on one feature branch of a private repo --
# 25 commits, a project rule requiring the whole suite green before each one, 1,067 tracked test
# files, and seven days in which no arc ledger was written at all, so nothing ever priced the repeat.
#
# So this gate keys on REPETITION instead -- of the WHOLE-PROJECT runs only, see `cadence_jobs` --
# and it fires at the FIRST boundary where the saving is still collectable: everything it needs is
# available at iteration one, and a saving is only collectable forward. Runs 1 and 2 are free
# (profile what you will run more than twice, not what you ran once) and run 3 must name the
# schedule.
CADENCE_KINDS = ('vitest', 'tsc', 'ci')
# The lock class that is cheap BY CONSTRUCTION and therefore never counts toward a rate, and is
# never refused by the rate. Keyed on the class `cpu_class` already computes rather than on a second
# rule of this gate's own, so a run cannot be cheap for the locks and expensive for the gate. `tsc`
# is always `heavy` and `ci` is always `none`, so neither is quietly dropped from the gate by this.
CADENCE_EXEMPT_CPU = 'light'
CADENCE_FREE_RUNS = 2
# A wrong cadence is fixed by changing the SCHEDULE (batch, background, cap, drop), never by making
# each instance marginally cheaper -- that preserves the defect at a discount and reads as progress.
# Generous about wording and strict about shape, for the reason STOP_BOUND_RE is: this gate exists
# to make the author move the schedule, not to score the prose.
CADENCE_SCHEDULE_RE = re.compile(
    r'\bbatch|\bgroup(?:ed|s|ing)?\b|\bbackground|\bparallel|\bdefer|\bcoalesc|\bcombin'
    r'|\bcap(?:ped|s)?\b|\bceiling|\bdrop(?:ped|s)?\b|\bskip|\bonce\b|\bfewer\b|\bstop\b'
    r'|\bat the (?:end|tip|last)|\bper (?:group|arc|surface|tip)|\bonly (?:at|on|when)', re.I)


def cadence_jobs(events: list[dict], kind: str) -> set:
    """The job ids of this arc's WHOLE-PROJECT runs of `kind` -- the repeat that is actually the bill.

    A SCOPED run is exempt permanently and by construction, and that exemption is the difference
    between a gate and a nuisance: running the changed test files after each edit is the pattern
    this skill asks for, and gating it would only teach people to route around the gate -- the same
    objection GATED_KINDS raises against gating cheap kinds at all. What costs is the whole-project
    repeat (`npm test`, a wide vitest, a `tsc`, a CI run), and `cpu_class` has already sorted
    exactly that, failing towards `heavy` whenever it cannot tell. Measured: the first draft of this
    gate counted every run and refused the THIRD one-file vitest in an arc, breaking a live overlap
    test whose three scoped runs were cheap and correct.

    Stillborn jobs are subtracted for the same reason `paid_review_jobs` subtracts them: a run
    refused at the lock spent nothing, and must not push the arc toward a gate it did not earn.
    """
    stillborn = stillborn_jobs(events)
    return {ev.get('job') for ev in events
            if ev.get('ev') == 'queued' and ev.get('kind') == kind
            and ev.get('cpu') != CADENCE_EXEMPT_CPU and ev.get('job') not in stillborn} - {None}


def runs_of(events: list[dict], kind: str) -> int:
    """How many whole-project runs of `kind` this arc has actually launched."""
    return len(cadence_jobs(events, kind))


def cadence_bill(events: list[dict], kind: str) -> tuple[int, float, float]:
    """(runs measured, median span, total span) for `kind` -- the count the refusal argues with.

    Read from each run's own recorded `span_s`, never estimated: a bare count can only be believed,
    and the point of refusing here is to hand the author a number they can check. The `end` event
    carries neither `kind` nor `cpu`, so the billed jobs resolve through `cadence_jobs` -- the SAME
    set the gate counts, so the count and the price can never disagree about what is billed. Runs open
    contribute nothing -- a bill that under-reports is honest, one that guesses is not, and
    under-reporting can only make this gate more permissive, never less.
    """
    jobs = cadence_jobs(events, kind)
    spans = sorted(float(ev['span_s']) for ev in events
                   if ev.get('ev') == 'end' and ev.get('job') in jobs
                   and isinstance(ev.get('span_s'), (int, float)) and not isinstance(ev.get('span_s'), bool))
    if not spans:
        return 0, 0.0, 0.0
    n = len(spans)
    mid = spans[n // 2] if n % 2 else (spans[n // 2 - 1] + spans[n // 2]) / 2.0
    return n, mid, sum(spans)


def cadence_of(events: list[dict], kind: str) -> dict | None:
    """This arc's last cadence record for `kind`, or None. Per ARC and per KIND.

    Per arc for the same reason the preflight is (the process is the arc's), but per KIND because
    the answer is kind-specific: batching the suite says nothing about how often the type-checker
    runs, and one record standing for both is how a real answer becomes a keystroke.
    """
    found = [ev for ev in events if ev.get('ev') == 'cadence' and ev.get('kind') == kind]
    return found[-1] if found else None


def cadence_decision(kind: str, prior_runs: int, has_cadence: bool) -> tuple[bool, str]:
    """May this launch proceed, or does the repeat owe its cadence answer first?"""
    if kind not in CADENCE_KINDS:
        return True, f'{kind} is not a repeating cheap kind -- round 1 preflight and close-round govern it'
    if prior_runs < CADENCE_FREE_RUNS:
        return True, (f'whole-project run {prior_runs + 1} of {kind}: inside the {CADENCE_FREE_RUNS}-run '
                      'free window -- profile what you will run more than twice, not what you ran once')
    if has_cadence:
        return True, f'whole-project run {prior_runs + 1} of {kind}: cadence on record'
    return False, (f'whole-project run {prior_runs + 1} of {kind}: no cadence on record, and this arc '
                   f'has already run the whole project {prior_runs} times under {kind}')


def cadence_help(arc: str, kind: str, n: int, mid: float, total: float) -> str:
    """The refusal, priced from the ledger, with the command that answers it."""
    bill = (f'measured so far: {n} whole-project run(s) of {kind}, median {hms(mid)}, {hms(total)} total'
            if n else f'no {kind} run has recorded a span yet, so the bill is unmeasured')
    return f'''{bill}.

Ask the CADENCE question, not the per-action one: a per-step self-check passes on every instance
while a wrong RATE is the bill. Answer it with a COUNT -- iterations remaining x cost each -- and
fix a wrong cadence by changing the SCHEDULE (batch, background, cap, drop), never by making each
instance marginally cheaper, which preserves the defect at a discount.

Where a PROJECT RULE fixes the rate, the cadence is not yours to lower: record it with --fixed-by
and find the cost somewhere else.

  python3 {HERE}/loop.py cadence --arc {shlex.quote(arc)} --kind {kind} \\
    --remaining <N> --each '<measured cost of one run>' \\
    --schedule '<what moves: batch/background/cap/drop>' | --fixed-by '<the rule that fixes it>' '''

def round_to_close(events: list[dict], track: str, rnd: int) -> int | None:
    """The round this track must have closed before it may launch into `rnd`, or None.

    This used to be `rnd - 1` unconditionally, which is wrong in both directions and I hit
    both inside one arc:

    - A lane opened MID-ARC (a fix track first used at round 3) has no round 2 to close, so
      the gate refused it forever. The only route left was `--one-off`, which takes no tree
      lock at all — a gate that pushes callers into the unsafe path is a worse gate.
    - Conversely, keying on `rnd - 1` alone means SKIPPING a round escapes the gate: leave
      round 3 empty and launch round 4, and round 2's unclosed state is never looked at.

    So the answer is the HIGHEST earlier round in which this track did anything. None means
    the track has no history before `rnd` and there is genuinely nothing to close; any real
    history is still held to the close rule, whichever round it is in.
    """
    rs = [ev['round'] for ev in events
          if ev.get('track') == track and ev.get('ev') in TRACK_EVENTS
          and isinstance(ev.get('round'), int) and not isinstance(ev.get('round'), bool)
          and ev['round'] < rnd]
    return max(rs) if rs else None


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
    # `rnd <= 1` passed round 0 and every negative round unconditionally, so a typo'd `--round 0`
    # bought a free launch instead of an error — and the round it "closed" was round -1, which
    # nothing ever writes. Rounds are 1-based; anything below that is refused, not waved through.
    if rnd < 1:
        return False, f'round {rnd} is not a valid round number — rounds start at 1'
    events = ledger_read(arc)
    if rnd == 1:
        ok, msg = preflight_decision(1, preflight_of(events) is not None, paid_review_jobs(events), track)
        if ok:
            return True, msg + '; nothing to close yet'
        return False, (msg + '''.

Answer the efficiency preflight BEFORE paying for the loop -- what is actually on the critical
path, what runs in PARALLEL, what BATCHES into one run, which surfaces the last change actually
invalidated (re-review only those), the BOUNDED stop, and the top cost drivers. Ask Codex to
critique the PROCESS for unnecessary serialization, redundant verification and over-broad review
scope in ONE cheap call first; if it is down, record that and do the analysis yourself -- never
block on it.''' + f'''

  python3 {HERE}/loop.py preflight --arc {shlex.quote(arc)} \\
    --critical-path '...' --parallel '...' --batch '...' --scope '...' \\
    --stop '...' --drivers '...' \\
    [--codex <critique.json> | --codex-unavailable '<why>']''')
    prev = round_to_close(events, track, rnd)
    if prev is None:
        return True, f'track {track} has no earlier rounds in the ledger — nothing to close'
    st = round_status(events, track, prev)
    ok, missing = gate_decision(st['closed'], st['triggered'], st['dispositioned'])
    if ok:
        return True, f"round {prev} closed at {clock(st['close_t'])}; triggered {sorted(st['triggered']) or 'none'} all dispositioned"
    if not st['closed']:
        return False, (f'round {prev} of track {track} is not closed — run:\n'
                       f'  python3 {HERE}/loop.py close-round --arc {shlex.quote(arc)} --track {shlex.quote(track)} --round {prev}')
    lines = [f'round {prev} of track {track} has TRIGGERED levers without a disposition: {sorted(missing)} — land each, then record it:']
    for lid in sorted(missing):
        lines.append(f'  python3 {HERE}/loop.py lever --arc {shlex.quote(arc)} --track {shlex.quote(track)} '
                     f'--round {prev} --id {lid} --state landed|declined --note "<what you did, or why not>"')
    return False, '\n'.join(lines)


# ----------------------------------------------------------------------- profiler
DUR_RE = re.compile(r'^\s*Duration\s+([\d.]+)(m?s)\b', re.M)
DUR_MIN_RE = re.compile(r'^\s*Duration\s+(\d+)m\s*([\d.]+)s', re.M)
TF_RE = re.compile(r'^\s*Test Files\s+(.*?)\s*$', re.M)
T_RE = re.compile(r'^\s*Tests\s+(.*?)\s*$', re.M)
# This scheduler's own stdout signature, from the three sites that print it (`loop.py: [<job>] ...`
# on launch, on a non-terminal exit, and on completion). It is how a scanned artifact can NAME the
# ledgered job that produced it.
JOB_LINE_RE = re.compile(r'^loop\.py: \[([^\]]+)\]', re.M)


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


def rows_from_dir(d: str, seen_paths: set, ledgered_jobs: set | None = None) -> list[dict]:
    """The legacy heuristic scan of a flat artifact dir (birth → mtime spans).

    `ledgered_jobs` is the set of job ids the ledger already accounts for. A scanned log that
    names one of them is that job's own captured output, not a separate unscheduled run.
    """
    ledgered_jobs = ledgered_jobs or set()
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
        # A caller that redirects the scheduler's own stdout to a file (`run-codex.sh ... >
        # x.wrap.log 2>&1`) leaves an artifact this scan cannot distinguish from an unscheduled
        # run — and it is nothing of the kind: its first line carries the loop.py job id of the
        # LEDGERED run it captured. Two defects came out of that. L7 ("jobs launched outside the
        # scheduler") fired on three such captures, and the same interval was counted twice in
        # `busy` — once from the ledger row, once from this one.
        #
        # Attribute it by READING it, not by skipping a filename: a `.wrap.log` exclusion only
        # holds for the suffix someone typed, and the identical redirect under any other name
        # would keep both defects. Fail-closed in the direction that matters — a log with no job
        # line, or one naming a job this ledger does not have, stays a stray, so absence of
        # evidence never attributes and a genuinely unscheduled run is still seen.
        jm = JOB_LINE_RE.search(text)
        if jm and jm.group(1) in ledgered_jobs:
            seen.add(ap)
            continue
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
            # The FILE existed for less time than the run it records — it was created after the
            # process started (a log opened late), or truncated and rewritten. The run's own
            # Duration is a measurement; birth is only an estimate of the start, so move the START
            # back rather than letting `span` disagree with the interval it is drawn from.
            #
            # Leaving them inconsistent was not merely untidy: `busy` unions [start, end] while the
            # totals-by-kind table sums `span`, so a row could report more time than the timeline
            # could account for, and clip_rows had no interval to clip that excess against.
            b = st.st_mtime - reported
            span = reported
        if reported is not None and span > reported * 1.5 and span - reported > 5:
            queued = span - reported
            note = f'queued ~{queued:.0f}s beyond its own Duration (inferred: birth→mtime minus Duration)'
        if reported is not None and span > 10 * reported and span > 3600:
            note = (f'measurement-suspect: span {hms(span)} vs Duration {hms(reported)} — a log appended to long '
                    'after its run (birth→mtime is not this run)')
        rows.append(dict(kind=kind, start=b, end=st.st_mtime, span=span, reported=reported, tests=tests,
                         path=os.path.join(os.path.basename(d), base), note=note, source='dir',
                         track=None, round=None, queued=queued, cpu=None, job=None, checkpoint=None,
                         # This row's queue is INFERRED (birth→mtime minus the run's own Duration)
                         # rather than measured by the scheduler, and L5 fires on its presence at any
                         # size. That used to be read off the note's `queued ...` prefix — a text
                         # match, so any other note starting with that word turned the lever on, and
                         # rewording the note would have turned it off silently.
                         queued_inferred=queued > 0))
    return rows


# A job's ledger record is finished by an `end` OR by a `refused` (--max-queue expired before it
# ever got the lock). Round 3 (CORR6): only `end` counted here, so a refusal was invisible -- the
# refused job's queue was left open-ended and re-measured against the PROFILER's clock on every
# call, while its run interval stayed the zero-length point it is. `round_window` then took
# max(end) over a single refused job and produced the degenerate window (t_queued, t_queued), and
# clipping deleted the whole wait. Measured before this fix: a real 400 s queue clipped to 0 s with
# L5 reading false, so close-round recorded no triggered lever and the next round's gate passed.
# `cmd_close_round`'s unfinished-job scan already treated both as terminal; this is the other half.
TERMINAL_EVENTS = ('end', 'refused')


def rows_from_ledger(events: list[dict], t_now: float | None = None) -> tuple[list[dict], set]:
    t_now = t_now or now()
    starts: dict = {}
    ends: dict = {}
    for ev in events:
        if ev.get('ev') == 'start' and ev.get('job'):
            starts[ev['job']] = ev
        elif ev.get('ev') in TERMINAL_EVENTS and ev.get('job'):
            ends[ev['job']] = ev
    rows, paths = [], set()
    # A job killed (or refused) while WAITING on a lock has a `queued` event and no `start`. Walking
    # only `starts` dropped it from every profiler view, so the wall-clock it spent queued became
    # unattributed gap — which is precisely the thing lever L6 exists to surface. Carry it as a row
    # whose whole span is wait.
    for ev in events:
        if ev.get('ev') != 'queued' or not ev.get('job') or ev['job'] in starts:
            continue
        q_t = float(ev.get('t', 0))
        fin = ends.get(ev['job'])
        q_end = float(fin['t']) if fin else t_now
        # ZERO-LENGTH on purpose: this job never ran, so it must not join the union of busy intervals
        # (that would report queueing as timed activity and shrink the unattributed figure). Its
        # wall-clock lives in `queued`, which the timeline reports on its own line.
        rows.append(dict(kind=ev.get('kind', 'other'), start=q_t, end=q_t, span=0.0, reported=None, tests='',
                         path=f"{ev.get('track')}/r{ev.get('round')}/{ev.get('name')}", source='ledger',
                         note=('refused while queued' if (fin or {}).get('ev') == 'refused'
                               else 'ended while queued (no start event)' if fin
                               else 'killed or abandoned while queued (no start event)'),
                         # The refusal's own MONOTONIC measurement when it left one, and only then
                         # the difference of two wall stamps -- which is a reconstruction, not a
                         # measurement, and collapses to ~0 across a clock step in either direction.
                         track=ev.get('track'), round=ev.get('round'),
                         queued=(float(fin['queued_s']) if fin and fin.get('queued_s') is not None
                                 else max(0.0, q_end - q_t)),
                         cpu=ev.get('cpu'), job=ev['job'], t_req=q_t, checkpoint=None,
                         rc=(fin or {}).get('rc'), unscoped=0, mutants=0, never_started=True,
                         coff=ev.get('coff'), coff_end=(fin or {}).get('coff')))
    for job, s in starts.items():
        e = ends.get(job)
        start = float(s.get('t', 0))
        end = float(e['t']) if e else t_now
        note = '' if e else 'unfinished (no end event)'
        if e and e.get('span_s') is not None:
            # The runner measured this span with time.monotonic(). t_end - t_start is a WALL
            # difference and is wrong by exactly any clock correction that landed mid-job, so where
            # the real measurement exists it wins and the wall-clock fallback below never runs.
            end = start + float(e['span_s'])
        elif end < start:
            # no monotonic span (a legacy or hand-written record) and the wall clock moved backwards
            # mid-job: the interval is INVALID evidence, never a duration
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
                         t_req=float(s.get('t_req') or start), pid=s.get('pid'), finished=bool(e),
                         checkpoint=s.get('checkpoint'), rc=(e or {}).get('rc'), unscoped=s.get('unscoped', 0),
                         mutants=s.get('mutants', 0), coff=s.get('coff'), coff_end=(e or {}).get('coff')))
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


def solo_wait(waits, others):
    """Time during which EXACTLY ONE wait is in flight and nothing else is running at all.

    This is the quantity L1 exists to measure: a blocking call with an idle machine behind it. The
    earlier version asked only whether a wait overlapped a NON-wait (`a > 0 and b == 0`), which
    counts a fully parallel panel as 100% alone — measured on this arc's own round 2, where three
    review lenses ran concurrently for 19m28s and L1 read TRIGGERED anyway, telling the round to
    land a lever it had already landed. A lever that cannot read green after its own fix is not a
    gate, so `a == 1` is the whole correction: two lenses overlapping is the fixed state, not waste.
    """
    pts = []
    for s, e in waits:
        pts.append((s, 1, 'a'))
        pts.append((e, -1, 'a'))
    for s, e in others:
        pts.append((s, 1, 'b'))
        pts.append((e, -1, 'b'))
    pts.sort()
    a = b = 0
    prev = None
    lone = 0.0
    for t, d, w in pts:
        if prev is not None and a == 1 and b == 0:
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


def stranded_mutant_anchors(mutants: list[dict], src: str) -> list[str]:
    """Which mutants can no longer arm the code they name?

    A mutant is a text substitution, so it is only as good as its anchor. Two ways an anchor goes
    bad, and both read as a passing battery to anyone who does not look:

      0 occurrences -- the source was rewritten under the mutant (renamed, reindented, lifted into
        another expression). `mutate.py` reports MISARMED and fails the run, but only after paying
        for the whole battery, and only if the battery is run at all.
      2+ occurrences -- the snippet is not unique, so the substitution rewrites every site. The
        mutant may still be killed, but the kill says nothing about the line the label names.

    So the rule is EXACTLY ONE, and it is a rule about text, which makes it a few milliseconds
    rather than a suite run per mutant -- cheap enough to sit in the unit tests, where a rewrite
    that strands a mutant reddens immediately instead of forty minutes into a battery.

    Pure and total: returns one human-readable line per bad anchor, in battery order, and the
    empty list when every mutant resolves exactly once. It judges anchors only -- whether a
    mutant that DOES arm is then killed is the battery's question, not this one.
    """
    out: list[str] = []
    for m in mutants:
        anchor = m.get('old') or ''
        n = src.count(anchor) if anchor else 0
        if n != 1:
            out.append('%s -- %d occurrence(s)' % (m.get('label') or '<unlabelled>', n))
    return out


def clock_discontinuity(rows: list[dict], tol_s: float = 2.0) -> list[dict]:
    """Where in a wall-sorted timeline did the clock JUMP, so the order across it is unknown?

    Every ledger record carries `coff` = wall - monotonic at write time (see `ledger_append`).
    That offset is constant while one boot's clock runs untouched, so a difference between two
    records larger than `tol_s` means a step or a reboot happened between them -- and a wall-clock
    comparison across a step is not evidence about ordering, no matter how far apart the stamps are.

    Returns one entry per adjacent boundary that crossed a jump, in the order the profiler prints
    the rows: {'before', 'after', 'delta', 'at'}. Empty means every row this set was measured
    against shared one continuous clock, which is the case the profiler may sort by wall time.

    TWO points per row, not one (round 4, LIFE5). A job stamps `coff` when it starts and `coff_end`
    when it ends, and a sequence built from start offsets alone discards the second of those --
    so a step that lands WHILE a job runs is invisible, which is the likeliest place for one to
    land: a review lens or a `codex --write` holds the longest single window in the whole arc.
    A row whose own two offsets disagree is reported with itself on both sides, which is the
    truthful attribution -- the step happened while that job was what was running.

    Pure and total: rows with no `coff` (a legacy or hand-written record) carry no evidence either
    way and are skipped rather than guessed at, and `tol_s` is clamped at 0 so a negative tolerance
    cannot turn every ordinary row into a finding.
    """
    tol = max(0.0, float(tol_s))
    pts: list[tuple[float, float, str]] = []
    for r in rows:
        who = r.get('path') or r.get('job') or '?'
        if r.get('coff') is not None:
            pts.append((float(r.get('start') or 0), float(r['coff']), who))
        if r.get('coff_end') is not None:
            pts.append((float(r.get('end') or r.get('start') or 0), float(r['coff_end']), who))
    pts.sort(key=lambda p: p[0])
    out: list[dict] = []
    for a, b in zip(pts, pts[1:]):
        delta = b[1] - a[1]
        if abs(delta) > tol:
            out.append(dict(before=a[2], after=b[2], delta=delta, at=b[0]))
    return out


def queue_intervals(rows: list[dict], window: tuple[float, float] | None = None) -> list[tuple[float, float]]:
    """The intervals in which jobs sat QUEUED on a lock, anchored at each job's request stamp.

    A job that waited an hour behind another lane's writer was not idle, and those seconds are not
    "editing / reading / thinking". They used to be counted TWICE: once on the `queued` line, and
    again inside `wall - busy`, because only RUN intervals joined the union. A synthetic 3600 s
    queue in front of a 100 s review therefore reported 3600 s queued and, simultaneously, an hour
    with no timed artifact — which fired L6 and pointed it at the wrong remedy. The scheduler
    working as designed must never read as unexplained silence.

    The length is the MEASURED (monotonic) wait, never `start - t_req`: that is a difference of two
    wall stamps and is wrong by exactly any clock correction that landed mid-queue. A row that
    never started has the same two fields, so one rule prices both.
    """
    out: list[tuple[float, float]] = []
    for r in rows:
        q = float(r.get('queued') or 0.0)
        t0 = r.get('t_req')
        if q <= 0 or t0 is None:
            continue
        a, b = float(t0), float(t0) + q
        if window:
            a, b = max(a, window[0]), min(b, window[1])
        if b > a:
            out.append((a, b))
    return out


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
    # `busy` stays RUN-ONLY, because it is what the per-kind percentages are a share of. The gap
    # and unattributed arithmetic runs on the EXPLAINED union instead: a run interval or a
    # measured queue interval both account for their seconds.
    qivs = queue_intervals(rows, (first, last))
    explained_ivs = sorted(list(ivs) + qivs)
    explained = union(explained_ivs)
    unattr_s = max(0.0, wall - explained)
    waits = [(r['start'], r['end']) for r in rows if r['kind'] in WAIT_KINDS]
    others = [(r['start'], r['end']) for r in rows if r['kind'] not in WAIT_KINDS]
    wait_union = union(waits) if waits else 0.0
    wait_alone = solo_wait(waits, others) if waits else 0.0
    big_gaps = gaps_of(explained_ivs)
    queued_total = sum(r.get('queued') or 0.0 for r in rows)
    P('')
    P('== timeline ==')
    P(f'  window          {hms(wall):>9}   {clock(first)} → {clock(last)}')
    P(f'  timed activity  {hms(busy):>9}   union of every interval above')
    P(f'  unattributed    {hms(unattr_s):>9}   editing / reading / thinking — neither run nor queued')
    if waits:
        P(f'  waits           {hms(wait_union):>9}   {len(waits)} review / codex --write / CI-watch run(s)')
        P(f'  waits SOLO      {hms(wait_alone):>9}   one wait in flight and nothing else at all — no second lens, no fixes')
    if queued_total:
        P(f'  queued          {hms(queued_total):>9}   measured time jobs spent waiting on a lock (the serialiser working)')
    jumps = clock_discontinuity(rows)
    if jumps:
        P(f'  CLOCK JUMPED    {len(jumps)}         the wall clock moved between jobs, so the ORDER across each')
        P('                                boundary below is UNKNOWN and every gap spanning one is unpriced')
        for j in jumps[:6]:
            P(f"                  {j['delta']:+9.0f}s  {clock(j['at'])}   between {j['before']} and {j['after']}")
    gap_rows = []
    if big_gaps:
        P(f'  gaps ≥ 30 min   {len(big_gaps)}')
        for g, a, b in big_gaps[:8]:
            cls, ev = classify_gap(a, b, list(notes), timeline)
            # Round 3 (LIFE6): a gap whose two ends were stamped under DIFFERENT clock offsets has
            # no measured length -- its span is (wall difference + however far the clock moved), and
            # the two are not separable from the record. It is reported as unpriced rather than
            # billed to the seat, so a 1h clock correction cannot masquerade as an hour of silence.
            spans = [j for j in jumps if a <= j['at'] <= b]
            if spans:
                cls = 'clock-jump'
                ev = (f"the clock moved {spans[0]['delta']:+.0f}s inside this gap, so its length is not a "
                      f"measurement — nothing is billed to it") + ('; ' + ev if ev else '')
            gap_rows.append(dict(span=g, start=a, end=b, cls=cls, evidence=ev))
            P(f'                  {hms(g):>9}   {clock(a)} → {clock(b)}   {cls:11} {ev}')
    levers: list[dict] = []

    def lever(lid, name, triggered, evidence, fix, failopen):
        levers.append(dict(id=lid, name=name, triggered=bool(triggered), evidence=evidence, fix=fix, failopen=failopen))

    lever('L1', 'Waits (panel / codex --write / CI) serialised with the fixes',
          bool(waits) and wait_alone > 0.4 * wait_union and wait_union > 300,
          f'{hm(wait_alone)} of {hm(wait_union)} wait time was ONE blocking call with an idle machine behind it' if waits else 'no review / codex / CI runs',
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
    queued_rows = [r for r in rows if (r.get('queued') or 0) >= 5 or r.get('queued_inferred')]
    lever('L5', 'Runs queued behind each other on one machine',
          queued_total >= 300 or any(r.get('queued_inferred') for r in rows),
          (f"{len(queued_rows)} run(s) waited; queue total {hm(queued_total)} (ledgered rows measured, unattributed ones inferred from Duration): "
           + ', '.join(f"{os.path.basename(r['path'])} {hm(r.get('queued') or 0)}" for r in queued_rows[:6])) if queued_rows else 'no run waited on another',
          'the serialiser is doing its job — shrink the queue by scoping (fewer wide runs, --affected per commit) or by '
          'moving the wide ones to checkpoints; never bypass the lock to "speed up"',
          'an unscheduled run beside a scheduled one is contention the lock cannot see — see L7')
    lever('L6', 'Wall-clock not in any artifact',
          wall > 0 and ((unattr_s > 0.6 * wall and wall > 1800) or bool(big_gaps)),
          (f'{hm(unattr_s)} of {hm(wall)} ({100 * unattr_s / wall:.0f}%) has no timed artifact'
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
    return dict(text='\n'.join(out), levers=levers, rows=rows, wall=wall, busy=busy,
                explained=explained, unattributed=unattr_s, wait_union=wait_union,
                wait_alone=wait_alone, gaps=gap_rows, queued=queued_total)


def gather_rows(arc: str | None, dirs: list[str]) -> tuple[list[dict], list[dict]]:
    events = ledger_read(arc) if arc else []
    rows, seen = rows_from_ledger(events)
    # Derived from the ledger rows themselves rather than restated, so a job the reader knows about
    # is a job the dir scan can attribute — the two sets cannot drift apart.
    ledgered_jobs = {r['job'] for r in rows if r.get('job')}
    scan = list(dirs)
    if arc and arc not in [os.path.abspath(d) for d in scan]:
        scan.append(arc)
    for d in scan:
        if not os.path.isdir(d):
            print(f'!! not a directory: {d}', file=sys.stderr)
            continue
        rows.extend(rows_from_dir(d, seen, ledgered_jobs))
    notes = [ev for ev in events if ev.get('ev') == 'note']
    return rows, notes


def round_window(rows: list[dict], track: str, rnd: int) -> tuple[float, float] | None:
    mine = [r for r in rows if r['source'] == 'ledger' and r['track'] == track and r['round'] == rnd]
    if not mine:
        return None
    # the RECORDED request time opens the window — never start minus an aggregate queue total
    # (mutate.py sums the waits of every mutant into one row, which would open it far too early)
    def last_moment(r: dict) -> float:
        # A job that was REFUSED never ran, so its run interval is a zero-length point at the moment
        # it asked (deliberately, so a wait cannot be counted as timed activity). Its wall-clock is
        # all in `queued`, and closing the window at max(end) therefore cut the entire wait out of
        # the round -- the window collapsed onto the request instant. The round ends at the last
        # moment ANY of its intervals reached, wait included.
        q_a = float(r['t_req'] if r.get('t_req') is not None else r['start'])
        return max(float(r['end']), q_a + float(r.get('queued') or 0.0))
    return min(r['t_req'] for r in mine), max(last_moment(r) for r in mine)


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
        # A job's WAIT is an interval too — [t_req, t_req + queued] — and it was carried into the
        # round whole while the run interval beside it was clipped. A job that queued 40 min before
        # this round opened and ran 10 s inside it charged the round all 40 minutes, which is enough
        # on its own to trigger L5 ("runs queued behind each other") for a round that queued nothing.
        # Clipping both intervals against the same window is what makes the two numbers comparable.
        q = float(r.get('queued') or 0.0)
        q_a = float(r['t_req'] if r.get('t_req') is not None else r['start'])
        c['queued'] = max(0.0, min(q_a + q, b) - max(q_a, a)) if q > 0 else 0.0
        if c['queued'] <= 0:
            c['queued_inferred'] = False   # a queue clipped entirely outside the round is not this round's
        if c['end'] >= c['start']:
            if (c['start'], c['end']) != (r['start'], r['end']):
                c['span'] = c['end'] - c['start']
                c['note'] = (f"clipped to the round ({hms(r['end'] - r['start'])} in full); " + (r.get('note') or '')).rstrip('; ')
            out.append(c)
        elif c['queued'] > 0:
            # It waited inside this round and ran outside it. Dropping it lost that wait entirely —
            # the mirror of the over-attribution above, and the same defect. It contributes its WAIT
            # and no run interval, so it is pinned to the window edge with zero span and cannot add
            # timed activity the round did not have.
            c['start'] = c['end'] = min(max(r['start'], a), b)
            c['span'] = 0.0
            c['note'] = ('waited inside the round, ran outside it; ' + (r.get('note') or '')).rstrip('; ')
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


def signal_child(child, signum: int) -> None:
    """Forward a signal to the child's whole process group, falling back to the child alone.

    The child runs in its own session (see cmd_run), so its pid is its process-group id and killpg
    reaches every helper it spawned. A group that has already exited raises ProcessLookupError, and
    a platform without killpg raises AttributeError; both mean "nothing left to signal".
    """
    if child is None or child.poll() is not None:
        return
    try:
        os.killpg(child.pid, signum)
    except (ProcessLookupError, PermissionError, AttributeError, OSError):
        try:
            child.send_signal(signum)
        except (ProcessLookupError, OSError):
            pass


def reap_group(child, grace_s: float = REAP_GRACE_S) -> bool:
    """TERM the child's process group, then KILL it, and WAIT.  True once nothing is left running.

    A scheduler that writes a job's terminal event while its process group is still alive has
    sealed a round over an untracked writer — one that still holds an inherited copy of the tree
    lock's descriptor and can still edit the tree the next job is about to be handed. So the only
    honest order is: kill, reap, then record. False means the group outlived both signals and the
    job must stay NON-terminal, because nothing here can prove the tree is quiet.
    """
    for sig in (signal.SIGTERM, signal.SIGKILL):
        signal_child(child, sig)
        try:
            child.wait(timeout=grace_s)
            return True
        except subprocess.TimeoutExpired:
            continue
        except OSError:
            return False
    return child.poll() is not None


def cmd_run(args) -> int:
    arc = need_arc(args)
    if not arc:
        return RC_USAGE
    if args.kind not in KINDS:
        return die(f'--kind must be one of {KINDS}')
    # The zero-test gate is only possible if we can READ the child's output. `vitest_verdict` used to
    # run under `if args.kind == 'vitest' and capture`, so `--no-capture` silently skipped it and a
    # `-t does-not-exist` run (vitest exits 0 on a zero match) was recorded and returned as GREEN --
    # the exact false green this scheduler exists to make impossible. Capture is not optional for the
    # one kind whose own exit status cannot be trusted.
    if args.kind == 'vitest' and args.capture is False:
        return die('--no-capture is refused for --kind vitest: the zero-test gate reads the child\'s '
                   'output, and vitest exits 0 when a name filter selects nothing. Drop --no-capture '
                   '(the log is written under the arc by default).')
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
    # Round 3 (LIFE2/LIFE4): admission is a TRANSACTION under the round lock — the seal check, the
    # lever gate and the durable `queued` record happen with no window in which a concurrent
    # close-round can slip between them. The child's run is deliberately outside it (see round_lock).
    err = lock_dir_ready()
    if err:
        return die(f'cannot take locks under {lock_dir()}: {err} (refusing to run unlocked)', RC_LOCK)
    with round_lock(arc, args.track, args.round):
        events = ledger_read(arc)
        ok, msg = admit_into_round(events, args.track, args.round)
        if not ok:
            print(f'loop.py: ADMISSION REFUSED launching {args.kind} into track {args.track} round '
                  f'{args.round}:\n{msg}', file=sys.stderr)
            return RC_GATE
        if args.kind == 'review':
            clash = review_name_collision(events, args.track, args.round, name, args.out or '')
            if clash:
                why, other = clash
                if why == CLASH_ELSEWHERE:
                    return die(
                        'refusing to launch review {!r} into track {} round {}: a review of this '
                        'round already carries that name and wrote its verdict to {}. A finding\'s '
                        'id is <name>#<index>, so two verdict files under one name mint one id for '
                        'two different findings and the round would close with one of them '
                        'undispositioned. Give this run its own --name.'
                        .format(name, args.track, args.round, other), RC_FAILCLOSED)
                return die(
                    'refusing to launch review {!r} into track {} round {}: a review of this round '
                    'already carries that name and ended SUCCESSFULLY, writing {}. Re-running it '
                    'would overwrite that verdict, and the round reads only the file that survives, '
                    'so every finding the first run reported and this one does not would vanish '
                    'with its outcome left as a stray nothing refuses on. The name is spent for '
                    'this round: give this run its own --name. Only a review that FAILED or was '
                    'quarantined may be retried under the same name.'
                    .format(name, args.track, args.round, other or '(no --out recorded)'),
                    RC_FAILCLOSED)
        # The reserved one-off track is CARVED OUT, and the condition is derived from
        # `ONE_OFF_TRACK` rather than spelling the string a second time (`cmd_one_off_track` exists
        # for the same reason). `cmd_close_round` REFUSES on that track by design, so a one-off
        # whose previous round was gated could never be unblocked by any command this tool offers:
        # the gate would demand a close that the closer refuses, forever. The arc is shared per
        # user (`${TMPDIR}/cc-one-off-$(id -u)`), so the first session to leave a round open there
        # would wedge every later `codex-opinion` call on the machine. Pinned in both directions by
        # `TestLaunchGateCarvesOutTheOneOffTrack`.
        if args.kind in GATED_KINDS and str(args.track) != ONE_OFF_TRACK:
            ok, msg = gate(arc, args.track, args.round)
            if not ok:
                print(f'loop.py: GATE REFUSED launching {args.kind} for track {args.track} round {args.round}:\n{msg}', file=sys.stderr)
                return RC_GATE
        # Keyed on how many times this arc has already run this kind, never on the kind alone: the
        # gate above cannot see a cheap check whose RATE is the expense. Same round lock, same
        # already-read `events`, and refused BEFORE the queued event so a refusal cannot count
        # itself toward the next refusal's bill.
        # `cpu != CADENCE_EXEMPT_CPU` on BOTH sides: a scoped run neither counts toward the rate
        # nor is refused by it. Gating the cheap run is what would teach people around the gate.
        if args.kind in CADENCE_KINDS and cpu != CADENCE_EXEMPT_CPU:
            ok, msg = cadence_decision(args.kind, runs_of(events, args.kind),
                                       cadence_of(events, args.kind) is not None)
            if not ok:
                n, mid, total = cadence_bill(events, args.kind)
                print(f'loop.py: CADENCE REFUSED launching {args.kind}:\n{msg}.\n'
                      + cadence_help(arc, args.kind, n, mid, total), file=sys.stderr)
                return RC_GATE
        tree = os.path.abspath(args.tree) if args.tree else None
        if tree and tree_state(tree) is None:
            return die(f'--tree {tree} is not a git worktree')
        tree_mode, cpu_mode = lock_modes(cpu, bool(tree), tree_writing(args.kind, cmd))
        t_req = now()
        # pid included: two jobs with the same track/round/name launched in the same millisecond used to
        # share an id, so one's `end` event closed the other's row and the profile attributed one
        # job's span to both. The ledger keys on this string, so it must identify the RUN, not the instant.
        job = f'{args.track}.r{args.round}.{name}.{int(t_req * 1000)}.{os.getpid()}'
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
    # MONOTONIC, because this number is a DURATION and the two wall stamps it used to be
    # reconstructed from (`refused.t - queued.t`) are not: an NTP step inside the wait wrote a
    # collapsed or negative lock wait straight into lever L6's input. Wall time still ANCHORS the
    # row; only the measurement is monotonic.
    m_req = time.monotonic()
    try:
        queued = locks.acquire()
    except TimeoutError as e:
        ledger_append(arc, dict(ev='refused', t=now(), job=job, track=args.track, round=args.round, kind=args.kind,
                                name=name, queued_s=max(0.0, time.monotonic() - m_req),
                                reason=f'lock not available: {e}'))
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
                    affected=affected_files or None, pid=os.getpid(), tree_status=(tree_before[1] if tree_before else None),
                    # Requirement 3 needs to know WHO reviewed, and `loop.py run` launches a child
                    # process — which a Claude reviewer subagent is not. Every review that reaches
                    # here is therefore a `run-codex.sh` launch, and `--party` exists so that fact
                    # is recorded rather than inferred later from the absence of a field. Stamped
                    # only on a review: a `write` or `vitest` event carrying a reviewing party
                    # would be a field with no meaning that some later reader would read anyway.
                    party=(args.party if args.kind == 'review' else None))
    ledger_append(arc, start_ev)
    print(f'loop.py: [{job}] {args.kind}/{cpu} queued {queued:.1f}s → running: {shlex.join(cmd)}'
          + (f'  (log: {log})' if log else ''), file=sys.stderr)
    rc = -1
    reason = ''
    fh = open(log, 'ab') if capture else None
    child = None
    terminal = True     # cleared only when a launched child cannot be proven dead (see reap_group)
    try:
        # The inner handshake: run-codex.sh honours CC_LOOP_JOB only when the ledger shows this
        # job started by ITS parent pid, so the marker cannot be forged by passing a flag.
        # CC_LOOP_TRACK/ROUND/NAME join the handshake because `run-codex.sh` write mode has to
        # record its authored range under (arc, track, task) and the inner launcher carries no
        # --track of its own (see its own comment at the re-exec). The alternative was parsing
        # `CC_LOOP_JOB`, which is `<track>.r<round>.<name>.<ms>.<pid>` — and both a track label and
        # a job name may contain a dot, so that parse is ambiguous by construction.
        child_env = dict(os.environ, CC_LOOP_JOB=job, CC_LOOP_ARC=arc,
                         CC_LOOP_TRACK=str(args.track), CC_LOOP_ROUND=str(args.round),
                         CC_LOOP_NAME=str(name))

        # Handlers go on BEFORE the fork. Installed after it, a signal landing in the window between
        # Popen and signal.signal() takes the DEFAULT disposition: the scheduler dies, its flock is
        # released by the kernel, and the child keeps writing a tree nothing holds any more. Small
        # window, but it is the one that produces an unlocked writer, so it is worth closing.
        # Once installed, forwarding + waiting is what keeps the locks held for exactly as long as
        # the child lives: we do not release on the signal, we release when the child is gone.
        pending: list = []

        def forward(signum, _frame):
            pending.append(signum)
            signal_child(child, signum)

        for sig in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
            signal.signal(sig, forward)
        # The child INHERITS the lock fds, and start_new_session gives it its own process group.
        #
        # Inheriting the fds is what makes the lock outlive a SIGKILL of this scheduler. flock(2)
        # belongs to the open file DESCRIPTION, not to a process, so the lock stands while any
        # process holds a descriptor on it. Without this, `kill -9` on the scheduler released the
        # tree lock instantly while its --write child carried on editing that tree: the next queued
        # job took the lock it had just been granted and both wrote the same worktree. SIGKILL is
        # uncatchable, so no handler can close this — only the kernel can, and this is how you ask.
        # The parent's release() still runs after child.wait(), by which point the child's copies
        # are gone too, so nothing leaks: the lock is held for exactly as long as a writer exists.
        #
        # The process group is the other half. `send_signal` reaches only the direct child, so a
        # forwarded TERM left the grandchildren (codex's own helpers, a vitest worker pool) running
        # unsupervised under a lock that was about to be released. Signalling the group reaches them.
        for fd in locks.fds:
            os.set_inheritable(fd, True)
        try:
            child = subprocess.Popen(cmd, cwd=cwd, stdout=fh or None, stderr=(subprocess.STDOUT if fh else None),
                                     env=child_env, start_new_session=True, pass_fds=tuple(locks.fds))
        except OSError as e:
            # A launch that never starts (no such binary, not executable, fork failure) used to escape as
            # a traceback AFTER the `queued`/`start` events were written, leaving the job with no terminal
            # event: it read as "still running" forever, and close-round would refuse the round on a job
            # that never existed. Every path out of here now ledgers a terminal event.
            #
            # This handler covers Popen and NOTHING ELSE. It used to wrap the whole block below, so an
            # OSError raised AFTER the fork — writing the `child` event, forwarding a pending signal,
            # waiting — was labelled `launch failed`, the locks were released, and a terminal `end` was
            # written while the process group was still running and still holding an inherited copy of
            # the tree lock. The round then closed over a live untracked writer.
            rc, reason = RC_FAILCLOSED, f'launch failed: {type(e).__name__}: {e}'
        else:
            try:
                # The child's identity, durable BEFORE we wait on it. start_new_session makes the child its
                # own group leader, so child.pid is the group id — and that group, not this scheduler, is
                # what actually holds the tree while the work runs (see the pass_fds note above). Without
                # this event a SIGKILL of the scheduler left close-round no way to see the live writer.
                ledger_append(arc, dict(ev='child', t=now(), job=job, track=args.track, round=args.round,
                                        name=name, kind=args.kind, pid=os.getpid(), pgid=child.pid))
                # a signal that arrived while the child was being forked was recorded, not delivered — pass it on
                for signum in pending:
                    signal_child(child, signum)
                rc = child.wait()
                reason = f'child rc={rc}'
            except BaseException as e:   # noqa: BLE001 — KeyboardInterrupt and SystemExit included ON PURPOSE
                # There is a live process group out there. Kill it and reap it FIRST; only then is
                # a terminal event honest. If it survives both signals we cannot say the tree is
                # quiet, so the job stays non-terminal and close-round refuses the round — which is
                # exactly what `--abandon-unverifiable` is the operator's escape from.
                rc = RC_FAILCLOSED
                reason = f'aborted after launch: {type(e).__name__}: {e}'
                if not reap_group(child):
                    terminal = False
                    reason += ' — the child process group SURVIVED SIGTERM and SIGKILL'
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
    if args.kind == 'vitest':   # capture is guaranteed on for vitest (refused at entry)
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
    if not terminal:
        # No `end` event on purpose. The job stays OPEN in the ledger so close-round refuses the
        # round rather than sealing it over a process nobody can account for. Our own lock fds go
        # with this process, but the child inherited copies, so the tree stays locked while it lives.
        print(f'loop.py: [{job}] NOT TERMINAL — {reason}', file=sys.stderr)
        return RC_FAILCLOSED
    # After the tree-move branch above, so a quarantined review (rc is RC_FAILCLOSED there, and
    # the output has been moved to `<out>.tree-moved`) is never snapshotted: `round_findings`
    # consults rc=0 reviews only, and there is nothing at `args.out` to copy.
    if args.kind == 'review' and rc == 0 and args.out:
        kept = keep_verdict(arc, job, args.out)
        if kept:
            end_ev['verdict'] = kept
    end_ev.update(rc=rc, reason=reason, span_s=span_s)
    ledger_append(arc, end_ev)
    print(f'loop.py: [{job}] done rc={rc} in {hms(t_end - t_start)} — {reason}', file=sys.stderr)
    return rc


def cmd_one_off_track(_args) -> int:
    """Print the reserved track name, so `run-codex.sh` need not spell it a second time."""
    print(ONE_OFF_TRACK)
    return 0


def cmd_gate(args) -> int:
    arc = need_arc(args)
    if not arc:
        return RC_USAGE
    ok, msg = gate(arc, args.track, args.round)
    print(('GATE PASS: ' if ok else 'GATE REFUSED: ') + msg)
    return 0 if ok else RC_GATE


def cmd_preflight(args) -> int:
    arc = need_arc(args)
    if not arc:
        return RC_USAGE
    answers = {f: getattr(args, f) for f in PREFLIGHT_FIELDS}
    for f in PREFLIGHT_FIELDS:
        why = thin_answer(answers[f])
        if why:
            return die(f'--{f.replace("_", "-")}: {why}.\nThe preflight is the one cheap moment to '
                       'catch an expensive process; a filled-in blank buys nothing.')
    why = repeated_answers(answers)
    if why:
        return die(f'the preflight answers repeat: {why}.')
    why = unbounded_stop(answers['stop'])
    if why:
        return die(f'--stop is not a bounded stopping condition: {why}.\n'
                   'Prefer "round N is the LAST panel for <region>, then findings are dispositioned '
                   'against the census" or "another round needs a new production-risk finding" over '
                   '"repeat until no findings remain".')
    # The Codex process critique is cheap and catches the serialization the author cannot see. Its
    # ABSENCE is recorded rather than silently skipped -- an outage must not quietly become the
    # reason a workflow ran unexamined, and it must not block either.
    if not args.codex and not args.codex_unavailable:
        return die('pass --codex <path to the Codex process critique> or --codex-unavailable "<why>": '
                   'the critique is a lightweight planning consultation, not another review loop, and '
                   'skipping it is a recorded decision rather than a silent one')
    if args.codex and args.codex_unavailable:
        return die('pass one of --codex / --codex-unavailable, not both')
    if args.codex:
        if not os.path.exists(args.codex):
            return die(f'--codex {args.codex} does not exist')
        # An empty file satisfied `exists` and so satisfied the consultation requirement outright --
        # asymmetric with how strictly the six text fields are checked, and the easiest way to record
        # a critique that never happened. `--codex-unavailable "<why>"` is the honest route for that.
        if os.path.getsize(args.codex) < 40:
            return die(f'--codex {args.codex} is {os.path.getsize(args.codex)} bytes -- that is not a '
                       'process critique. Record --codex-unavailable "<why>" instead of an empty file.')
    prior = preflight_of(ledger_read(arc))
    ledger_append(arc, dict(ev='preflight', codex=args.codex or None,
                            codex_unavailable=args.codex_unavailable or None,
                            supersedes=(prior or {}).get('t'), **answers))
    print(f'efficiency preflight recorded for arc {arc}:')
    for f in PREFLIGHT_FIELDS:
        print(f'  {f.replace("_", "-"):14s} {answers[f]}')
    print(f'  {"codex":14s} ' + (args.codex or f'UNAVAILABLE -- {args.codex_unavailable}'))
    if prior:
        print(f'  (supersedes the preflight recorded at {clock(prior.get("t"))})')
    return 0


def cmd_cadence(args) -> int:
    arc = need_arc(args)
    if not arc:
        return RC_USAGE
    if args.kind not in CADENCE_KINDS:
        return die(f'--kind {args.kind} is not a cadence-gated kind (one of {", ".join(CADENCE_KINDS)})')
    if args.remaining < 0:
        return die(f'--remaining {args.remaining} is not a count of iterations left')
    why = thin_answer(args.each)
    if why:
        return die(f'--each: {why}.\nA cadence answer is "iterations remaining x cost EACH"; without '
                   'the cost of one run there is no total, and a total is the only form a wrong rate '
                   'is visible in.')
    # Exactly one of the two routes. A run that supplies both has not decided whether the rate is
    # its own to change, and that is the whole question this gate asks.
    if bool(args.schedule) == bool(args.fixed_by):
        return die('pass one of --schedule "<what moves>" / --fixed-by "<the project rule that fixes '
                   'the rate>", not both and not neither')
    if args.fixed_by:
        why = thin_answer(args.fixed_by)
        if why:
            return die(f'--fixed-by: {why}. Name the rule (and where it is written), so the next '
                       'session can check whether it still says that.')
    else:
        why = thin_answer(args.schedule)
        if why:
            return die(f'--schedule: {why}.')
        # The banned shape, not a banned wording: an answer that only makes each instance cheaper
        # leaves the rate exactly where it was, and reads as progress while doing it.
        if not CADENCE_SCHEDULE_RE.search(args.schedule):
            return die(f'--schedule does not change the SCHEDULE: {args.schedule!r}.\n'
                       'Batch it, background it, cap it, or drop it. Making each instance marginally '
                       'cheaper preserves the defect at a discount -- and if the rate is fixed by a '
                       'project rule, say so with --fixed-by and find the cost elsewhere.')
    events = ledger_read(arc)
    n, mid, total = cadence_bill(events, args.kind)
    prior = cadence_of(events, args.kind)
    ledger_append(arc, dict(ev='cadence', t=now(), kind=args.kind, remaining=args.remaining,
                            each=args.each, schedule=args.schedule or None,
                            fixed_by=args.fixed_by or None,
                            measured_runs=n, measured_median_s=mid, measured_total_s=total,
                            supersedes=(prior or {}).get('t')))
    print(f'cadence recorded for arc {arc}, kind {args.kind}:')
    print(f'  {"remaining":14s} {args.remaining}')
    print(f'  {"each":14s} {args.each}')
    print(f'  {"schedule" if args.schedule else "fixed-by":14s} {args.schedule or args.fixed_by}')
    print(f'  {"measured":14s} ' + (f'{n} run(s), median {hms(mid)}, {hms(total)} total so far'
                                    if n else 'no span recorded yet'))
    if args.fixed_by:
        print('  NOTE: the rate is fixed by a project rule -- the saving has to come from somewhere else.')
    if prior:
        print(f'  (supersedes the cadence recorded at {clock(prior.get("t"))})')
    return 0


def pid_alive(pid) -> bool:
    """Whether the scheduler process that launched a job is still around.

    Signal 0 only asks; it never delivers. EPERM means a live process we do not own, which is still
    alive. Pid reuse can make this answer yes for an unrelated process — it fails CLOSED (we refuse
    to close a round that is probably still running), which is the safe direction.
    """
    try:
        pid = int(pid)
    except (TypeError, ValueError):
        return False
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    except OSError:
        return False
    return True


def pgid_alive(pgid) -> bool:
    """Whether any process remains in the child's process group.

    `cmd_run` gives every child `start_new_session=True`, so the child's pid IS its group id, and
    the group holds the child plus everything it spawned (codex's helpers, a vitest worker pool).
    Signal 0 to the group only asks. Fails CLOSED for the same reason `pid_alive` does: id reuse
    answers "alive", and refusing to close a round is the safe direction.
    """
    try:
        pgid = int(pgid)
    except (TypeError, ValueError):
        return False
    if pgid <= 1:
        return False
    try:
        os.killpg(pgid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    except OSError:
        return False
    return True


def job_alive(j: dict) -> bool:
    """A job is alive while EITHER its scheduler or its child process group is."""
    return pid_alive(j.get('pid')) or pgid_alive(j.get('pgid'))


def describe_liveness(j: dict) -> str:
    parts = []
    if pid_alive(j.get('pid')):
        parts.append(f"scheduler pid {j.get('pid')}")
    if pgid_alive(j.get('pgid')):
        parts.append(f"child group {j.get('pgid')}")
    return ' + '.join(parts) or 'no live process'


def unfinished_jobs(arc: str, track: str, rnd: int) -> tuple[list[dict], list[dict]]:
    """(still running, abandoned) jobs ledgered for this track+round.

    A job is unfinished when it has a `queued` or `start` event and no terminal event. Closing a
    round over one of those writes a profile that omits it AND opens the gate for round N+1, so the
    next panel launches while this one is still holding trees and CPU — the exact serialisation this
    scheduler exists to prevent, arrived at from the other direction.
    """
    terminal = {ev['job'] for ev in ledger_read(arc)
                if ev.get('ev') in ('end', 'refused') and ev.get('job')}
    seen: dict = {}
    for ev in ledger_read(arc):
        if ev.get('ev') not in ('queued', 'start', 'child') or not ev.get('job'):
            continue
        if str(ev.get('track')) != str(track) or int(ev.get('round', -1)) != int(rnd):
            continue
        if ev['job'] in terminal:
            continue
        seen.setdefault(ev['job'], dict(job=ev['job'], name=ev.get('name'), kind=ev.get('kind'),
                                        pid=ev.get('pid'), pgid=None, started=False, t=ev.get('t')))
        if ev.get('pid'):
            seen[ev['job']]['pid'] = ev['pid']
        if ev.get('ev') == 'start':
            seen[ev['job']]['started'] = True
        if ev.get('pgid'):
            # Round 3 (LIFE3): the child's process GROUP, ledgered right after Popen. The scheduler
            # pid alone was the whole liveness test, so `kill -9` on the scheduler -- which
            # deliberately leaves the child alive holding the inherited lock fds -- read as dead and
            # `--abandon-unfinished` closed the round over a running writer.
            seen[ev['job']]['pgid'] = ev['pgid']
    live = [j for j in seen.values() if job_alive(j)]
    dead = [j for j in seen.values() if not job_alive(j)]
    return live, dead


def cmd_close_round(args) -> int:
    arc = need_arc(args)
    if not arc:
        return RC_USAGE
    # Round 3 (LIFE4): the WHOLE close is one transaction under the round lock — the unfinished-job
    # check, the profile computation, both artifact writes and the single close event. Before this,
    # two concurrent closes could compute different snapshots, truncate each other's profile.txt
    # mid-write and append two close events, and `round_status` reads the LAST close as
    # authoritative — so a lever disposition recorded against the first close was silently voided.
    err = lock_dir_ready()
    if err:
        return die(f'cannot take locks under {lock_dir()}: {err} (refusing to close unlocked)', RC_LOCK)
    with round_lock(arc, args.track, args.round):
        events = ledger_read(arc)
        corrupt = ledger_corrupt(events)
        if corrupt:
            return die(f'refusing to close round {args.round} of track {args.track}: the ledger holds '
                       f'{corrupt} unparseable record(s), so an unfinished job cannot be ruled out. '
                       'Repair or archive the ledger first.', RC_FAILCLOSED)
        if round_status(events, args.track, args.round)['closed']:
            return die(f'round {args.round} of track {args.track} is already CLOSED. A second close '
                       'would overwrite its profile and become the authoritative record, voiding every '
                       'lever disposition made against the first one. Record dispositions with '
                       '`loop.py lever` (no re-close needed); if the round genuinely has new work, it '
                       'belongs in the next round.', RC_FAILCLOSED)
        live, dead = unfinished_jobs(arc, args.track, args.round)
        if live:
            return die('cannot close round {} of track {}: {} job(s) still RUNNING — {}. The profile would '
                       'omit them and the gate would admit the next round while this one still holds its '
                       'trees and CPU. Wait for them, or kill them (a killed job ledgers no end event and '
                       'then closes with --abandon-unfinished).'
                       .format(args.round, args.track, len(live),
                               ', '.join(f"{j['name']} ({describe_liveness(j)})" for j in live)), RC_FAILCLOSED)
        # UNCONDITIONAL, and deliberately not inside the `--abandon-unfinished` branch. A job that
        # ledgered `start` but never ledgered a `child` has no recorded pgid, so `job_alive` cannot
        # ask about its child at all -- it reads "dead" from the absence of evidence, not from a
        # signal. That is exactly the record `--abandon-unfinished` used to close over: the flag
        # skipped this computation, so a round could be closed over a child that is still running,
        # still holding its tree and CPU locks through inherited fds, into a round the gate then
        # admits. Liveness that cannot be established is never abandonable by a blanket flag; the
        # operator must name each such job, which forces them to look at the one thing the ledger
        # cannot tell them.
        unverifiable = [j for j in dead if j.get('started') and not j.get('pgid')]
        named = {n for n in (args.abandon_unverifiable or '').split(',') if n}
        blind = [j for j in unverifiable if str(j['name']) not in named]
        if blind:
            return die('cannot close round {} of track {}: {} job(s) ledgered a start but never a child, '
                       'so no process group was ever recorded and a LIVE orphan cannot be ruled out by '
                       'inspection — {}. --abandon-unfinished does not cover these: it abandons jobs '
                       'measured dead, and these are jobs that cannot be measured at all. Confirm each '
                       'is gone (`ps -o pgid=,command= -p <pid>` for anything still writing under the '
                       'arc), then name them: --abandon-unverifiable={}'
                       .format(args.round, args.track, len(blind),
                               ', '.join(str(j['name']) for j in blind),
                               ','.join(str(j['name']) for j in blind)), RC_FAILCLOSED)
        if dead and not args.abandon_unfinished:
            extra = ('' if not unverifiable else
                     ' Of those, {} died before its child identity was durably recorded ({}), so a live '
                     'orphan cannot be ruled out by inspection.'
                     .format(len(unverifiable), ', '.join(str(j['name']) for j in unverifiable)))
            return die('cannot close round {} of track {}: {} job(s) have no terminal ledger event and '
                       'neither their launcher nor their child process group is alive — {}. They were '
                       'killed or crashed, so their wall-clock is unmeasured. Re-run them, or pass '
                       '--abandon-unfinished to close anyway (the close then records that they were '
                       'abandoned).{}'
                       .format(args.round, args.track, len(dead),
                               ', '.join(str(j['name']) for j in dead), extra), RC_FAILCLOSED)
        # §5.5: a round cannot close while any of its findings has no outcome. The requirement
        # joins the gate that already decides whether the next round may launch, so the
        # enforcement sits at a chokepoint rather than depending on an agent remembering. The
        # change is additive: a round whose reviewers reported no findings — or that ran no
        # review job at all — closes exactly as it did before, which is every round of every
        # in-flight arc that predates this store.
        # `review_name_collision` exempts the reserved one-off track because nothing closes a
        # round there. That is an assumption until something enforces it, and an exemption whose
        # premise is only a comment is the shape where a round DOES close one day having lost a
        # finding to a reused name. So the premise is the mechanism: the close is refused here.
        if str(args.track) == ONE_OFF_TRACK:
            return die('cannot close round {} of track {!r}: that track is reserved for '
                       '`run-codex.sh --one-off`, whose arc is shared per user and whose rounds '
                       'are never accounted. A one-off reports no finding outcomes, and '
                       '`review_name_collision` exempts this track on the strength of nothing '
                       'closing a round on it — closing one would seal a round that may have '
                       'reused a review name. Attribute the work to a real arc/track/round if it '
                       'needs a round at all.'
                       .format(args.round, ONE_OFF_TRACK), RC_FAILCLOSED)
        rows = outcomes_read(arc)
        corrupt_outcomes = ledger_corrupt(rows)
        if corrupt_outcomes:
            return die(f'cannot close round {args.round} of track {args.track}: '
                       f'{outcomes_path(arc)} holds {corrupt_outcomes} unparseable row(s), so '
                       'whether every finding carries an outcome cannot be established. Repair '
                       'or archive the outcome store first.', RC_FAILCLOSED)
        dupes = outcome_duplicate_keys(rows)
        if dupes:
            return die('cannot close round {} of track {}: the outcome store holds duplicate '
                       'key(s) {} — decision 5 gives each finding EXACTLY ONE outcome, and a '
                       'duplicate means two readings of one finding that every count would then '
                       'answer from whichever row it read first. `loop.py finding record` cannot '
                       'produce one, so these were written by something else.'
                       .format(args.round, args.track,
                               ', '.join('/'.join(k) for k in dupes)), RC_FAILCLOSED)
        found, unreadable = round_findings(events, args.track, args.round)
        if unreadable:
            return die('cannot close round {} of track {}: {} review verdict(s) this round '
                       'recorded cannot be read, so the round\'s finding count is UNKNOWN and an '
                       'unrecorded outcome cannot be ruled out — {}. Unknown is not zero, and '
                       'zero is the one value that would make the requirement vacuous. This loop '
                       'keeps its own copy of every paid review verdict under {}, and the path '
                       'named above is already that copy where one was taken — so a verdict '
                       'unreadable here was either never snapshotted (a ledger written before '
                       'this loop kept them, or a snapshot whose WARNING was printed at the time) '
                       'or has been removed since. Restore the file at the path named and close '
                       'again.'
                       .format(args.round, args.track, len(unreadable), '; '.join(unreadable),
                               os.path.join(arc, 'verdicts')),
                       RC_FAILCLOSED)
        missing, stray = outcome_coverage(found, outcomes_for_round(rows, arc, args.track, args.round))
        if stray:
            print('note: {} outcome row(s) name no finding this round reported — {}. Recorded '
                  'anyway (see `outcome_coverage` for why a stray does not refuse), but one of '
                  'them is usually a mistyped id whose real finding is still unrecorded.'
                  .format(len(stray), ', '.join(stray)), file=sys.stderr)
        if missing:
            return die('cannot close round {} of track {}: {} of {} finding(s) carry no outcome '
                       '— {}. Decision 5 gives every finding exactly one of {}. Record each with '
                       '`loop.py finding record --arc {} --track {} --round {} --id <id> ...`; '
                       'ids are <lens job name>#<index in that verdict\'s findings array>.'
                       .format(args.round, args.track, len(missing), len(found),
                               ', '.join(missing), ' | '.join(review_eval.FINDING_OUTCOMES),
                               shlex.quote(arc), shlex.quote(str(args.track)), args.round),
                       RC_FAILCLOSED)
        # Requirement 3 at the round boundary: no commit of the range claimed twice, and every
        # range reviewed by the party that did NOT write it. ADDITIVE in exactly the way the
        # outcome store was — an arc with no range rows closes as it did before, which is every
        # in-flight arc on this machine. Rows PRESENT with no `--range` fails CLOSED rather than
        # closing vacuously: that is the one direction a "check it only if you asked" gate is
        # always wrong in, because the party who would not ask is the party with something to hide.
        raw_ranges = ranges_read(arc)
        corrupt_ranges = ledger_corrupt(raw_ranges)
        if corrupt_ranges:
            return die(f'cannot close round {args.round} of track {args.track}: '
                       f'{ranges_path(arc)} holds {corrupt_ranges} unparseable row(s), so who '
                       'authored this range cannot be established. Repair or archive the range '
                       'store first.', RC_FAILCLOSED)
        range_dupes = store_duplicate_keys(raw_ranges, RANGE_KEY_FIELDS)
        if range_dupes:
            return die('cannot close round {} of track {}: the range store holds duplicate key(s) '
                       '{} — exactly one author per task, and a duplicate means two rows '
                       'disagreeing about who wrote a span of commits. `loop.py range record` '
                       'cannot produce one, so these were written by something else.'
                       .format(args.round, args.track,
                               ', '.join('/'.join(k) for k in range_dupes)), RC_FAILCLOSED)
        arc_ranges = ranges_for_arc(raw_ranges, arc)
        if arc_ranges and not args.range:
            return die('cannot close round {} of track {}: this arc records {} authored range(s), '
                       'so requirement 3 (every range approved by a non-author) is live here — and '
                       'it cannot be checked without the commit range this round closes over. '
                       'Re-run with --range BASE..HEAD (and --repo DIR if the repository is not '
                       'the current directory). An arc with no range rows still closes with no '
                       '--range; this one has rows.'
                       .format(args.round, args.track, len(arc_ranges)), RC_FAILCLOSED)
        if args.range:
            repo = os.path.abspath(args.repo or os.getcwd())
            if tree_state(repo) is None:
                return die(f'--range needs a git worktree to resolve in; {repo} is not one (pass '
                           '--repo DIR)', RC_USAGE)
            range_check, range_errs = check_ranges(arc, repo, args.range, events, raw_ranges)
            if range_errs:
                return die('cannot close round {} of track {}: the range {!r} cannot be checked:\n{}'
                           .format(args.round, args.track, args.range,
                                   '\n'.join('  - ' + e for e in range_errs)), RC_FAILCLOSED)
            assert range_check is not None
            if not range_check['ok']:
                return die('cannot close round {} of track {}: requirement 3 is not satisfied over '
                           '{}:\n{}\nRecord the missing review with `loop.py review record '
                           '--party <the other party> --name <lens> --verdict <path>`; a range row '
                           'is corrected by editing the store, never by a second append.'
                           .format(args.round, args.track, args.range,
                                   render_range_refusal(range_check)), RC_FAILCLOSED)
        txt, res = profile_text(arc, args.dirs, args.track, args.round, args.timeline)
        if res.get('empty') and not args.empty_ok:
            print(txt)
            return die(f'no ledgered job in track {args.track} round {args.round}; pass --empty-ok to close it anyway '
                       '(the close then records that nothing was measured)', RC_FAILCLOSED)
        rdir = os.path.join(arc, 'rounds', str(args.track), f'r{args.round}')
        os.makedirs(rdir, exist_ok=True)
        ppath, lpath = os.path.join(rdir, 'profile.txt'), os.path.join(rdir, 'levers.json')
        levers = res.get('levers', [])
        # tmp + os.replace: a reader never sees a half-written profile, and a crash between the two
        # artifacts leaves the previous pair intact rather than one new and one truncated.
        write_atomic(ppath, txt + '\n')
        write_atomic(lpath, json.dumps(levers, indent=1))
        triggered = [lv['id'] for lv in levers if lv['triggered']]
        ledger_append(arc, dict(ev='round-close', track=args.track, round=args.round, triggered=triggered,
                                profile=ppath, levers=lpath, empty=bool(res.get('empty')),
                                abandoned=[j['job'] for j in dead] or None,
                                # Separately recorded because they were closed on an OPERATOR'S WORD,
                                # not on a measurement: `abandoned` says "we saw it die", this says
                                # "nobody could see, and a human asserted it".
                                unverifiable=[j['job'] for j in unverifiable] or None))
    print(txt)
    print(f'\nround {args.round} of track {args.track} CLOSED; TRIGGERED: {triggered or "none"}')
    if triggered:
        print('before launching round %d, land each and record it:' % (args.round + 1))
        for lid in triggered:
            print(f'  python3 {HERE}/loop.py lever --arc {shlex.quote(arc)} --track {shlex.quote(str(args.track))} '
                  f'--round {args.round} --id {lid} --state landed|declined --note "..."')
    # REPORT, not refuse: a stray verdict need not belong to THIS round, so closing over it is not
    # wrong here -- but `converge` will refuse over it, and this is the earliest the count is cheap.
    stray = unledgered_verdicts(arc, ledger_read(arc))
    if stray:
        print('\nUNLEDGERED: {} review verdict(s) in the arc directory are named by no ledgered '
              'review; `converge` will refuse until each is recorded:\n{}'
              .format(len(stray), render_unledgered(arc, stray)))
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


def cmd_finding(args) -> int:
    """`loop.py finding <record|report>` — the finding-outcome store's two commands.

    One command with two actions rather than two commands, because both are about the same store
    and the report's whole claim is that it reads the rows the recorder wrote.
    """
    arc = need_arc(args)
    if not arc:
        return RC_USAGE
    if args.action == 'report':
        return _finding_report(args, arc)
    return _finding_record(args, arc)


def _finding_report(args, arc: str) -> int:
    """`loop.py finding report` — counts by kind, by severity and by round (§5.6).

    Refuses over an unparseable store rather than reporting the smaller number it could still
    count. A corrupt row is a row whose outcome is unknown, and a report that silently omitted it
    would answer a question nobody asked — "how many rows can I read" rather than "what happened
    to this round's findings".
    """
    records = outcomes_read(arc)
    corrupt = ledger_corrupt(records)
    if corrupt:
        return die(
            f'refusing to report: {outcomes_path(arc)} holds {corrupt} unparseable row(s), so the '
            'counts below would be of what could be read rather than of what was recorded',
            RC_FAILCLOSED)
    print(render_outcome_report(outcome_report(records, arc, track=args.track, rnd=args.round)))
    return 0


def _finding_record(args, arc: str) -> int:
    """`loop.py finding record` — file the ONE outcome a review finding gets (§5.1–§5.4).

    The closed set of six comes from `review_eval.FINDING_OUTCOMES` rather than from a second
    tuple here. Two copies of a closed set is the shape where a seventh value is accepted by one
    reader and refused by the other, and this store's whole claim is that `outcome` is validated
    against that set "and nothing else".

    It is validated HERE rather than by `argparse(choices=...)` on purpose: argparse would refuse
    first, with its own exit code and its own message, so the refusal a programmatic caller gets
    from `outcome_admission` would never be the refusal the CLI exercises, and the test for it
    would be a test of argparse.
    """
    if args.outcome not in review_eval.FINDING_OUTCOMES:
        return die('--outcome must be one of {}; {!r} is outside the closed set of six that '
                   'decision 5 names, and an unrecognised outcome cannot be counted'
                   .format(list(review_eval.FINDING_OUTCOMES), args.outcome), RC_FAILCLOSED)
    if not args.note.strip():
        return die('--note must say what happened to this finding; an outcome with no note is a '
                   'label nobody can audit', RC_USAGE)
    if args.line_start > args.line_end:
        return die(f'--line-start {args.line_start} is after --line-end {args.line_end}',
                   RC_USAGE)
    rec = {
        'arc': canonical_arc(arc), 'track': args.track, 'round': args.round,
        'findingId': args.id,
        'severity': args.severity, 'file': args.file,
        'lineStart': args.line_start, 'lineEnd': args.line_end,
        'outcome': args.outcome, 'note': args.note,
    }
    missing = [f for f in OUTCOME_FIELDS if rec.get(f) in (None, '')]
    if missing:
        return die(f'every field of a finding outcome is required; missing: {", ".join(missing)}',
                   RC_USAGE)
    verdict, reason = outcomes_record(arc, rec)
    if verdict == 'refuse':
        return die(reason, RC_FAILCLOSED)
    if verdict == 'idempotent':
        print(reason)
        return 0
    print('recorded {} = {!r} for track {} round {}'
          .format(args.id, args.outcome, args.track, args.round))
    return 0


def cmd_review(args) -> int:
    """`loop.py review record` — file a review by a party that launches no child (requirement 2).

    MEASURED 2026-10-28 on arc `jobs/66648556/tmp`: all 16 paid verdicts were Codex's and the arc
    held 0 Claude review artifacts. That was not the Claude half of step 7 failing to run — a
    reviewer subagent writes into a session transcript, and no command existed that could file its
    verdict anywhere the loop reads. An absence by construction is indistinguishable from a review
    that never happened, which is exactly why property 3 was unprovable from the record.

    What this writes is deliberately the SAME pair of ledger events a launched review writes, with
    `party` set, so no second gate is needed anywhere: `round_findings` counts its findings and
    §5.5 therefore refuses the close while any of them lacks an outcome, and
    `review_artifact_parties` reads it for the independence check. One new command, zero new gates.
    """
    arc = need_arc(args)
    if not arc:
        return RC_USAGE
    if args.party not in PARTIES:
        return die(f'--party must be one of {list(PARTIES)}; authorship here is binary and a third '
                   'party would make the complement rule unsound', RC_USAGE)
    path = os.path.abspath(args.verdict)
    try:
        with open(path, encoding='utf-8') as fh:
            doc = json.load(fh)
    except (OSError, ValueError) as exc:
        return die(f'cannot read the verdict at {path}: {type(exc).__name__}: {exc}. A review '
                   'artifact this loop cannot read is one `close-round` would later refuse the '
                   'round over, so it is refused here where the reviewer is still in the room.',
                   RC_FAILCLOSED)
    errs = verdict_errors(doc, review_schema_contract())
    if errs:
        return die('the verdict at {} does not satisfy {}:\n{}\nThis is the same contract '
                   '`run-codex.sh` hands `codex exec --output-schema`, so a Claude review is held '
                   'to what a Codex review is held to — otherwise the two halves of one round '
                   'would not be comparable and `round_findings` could not count both.'
                   .format(path, os.path.basename(REVIEW_SCHEMA_PATH),
                           '\n'.join('  - ' + e for e in errs)), RC_FAILCLOSED)
    name = args.name
    err = lock_dir_ready()
    if err:
        return die(f'cannot take locks under {lock_dir()}: {err} (refusing to record unlocked)',
                   RC_LOCK)
    with round_lock(arc, args.track, args.round):
        events = ledger_read(arc)
        ok, msg = admit_into_round(events, args.track, args.round)
        if not ok:
            # The same admission rule a launch obeys, for the same reason: a review filed after
            # the close adds findings the close already accounted for as absent.
            return die(f'cannot record a review into track {args.track} round {args.round}:\n{msg}',
                       RC_GATE)
        clash = review_name_collision(events, args.track, args.round, name, path)
        if clash:
            why, other = clash
            return die(
                'refusing to record review {!r} into track {} round {}: a review of this round '
                'already carries that name and {}. A finding\'s id is <name>#<index>, so two '
                'verdicts under one name mint one id for two findings and the round would close '
                'with one of them undispositioned. Give this artifact its own --name.'
                .format(name, args.track, args.round,
                        'wrote its verdict to ' + other if why == CLASH_ELSEWHERE
                        else 'ended successfully, writing ' + (other or '(no path recorded)')),
                RC_FAILCLOSED)
        t = now()
        job = f'{args.track}.r{args.round}.{name}.{int(t * 1000)}.{os.getpid()}'
        kept = keep_verdict(arc, job, path)
        ledger_append(arc, dict(ev='start', t=t, job=job, track=args.track, round=args.round,
                                kind='review', name=name, cpu='none', tree=None, out=path,
                                party=args.party, pid=os.getpid(), recorded=True))
        ledger_append(arc, dict(ev='end', t=now(), job=job, track=args.track, round=args.round,
                                kind='review', name=name, rc=0, verdict=kept or None,
                                party=args.party, recorded=True))
    ids = [finding_id(name, i) for i in range(len(doc.get('findings') or []))]
    print('recorded a {} review {!r} of track {} round {}: {} finding(s){}'
          .format(args.party, name, args.track, args.round, len(ids),
                  '' if not kept else f'; verdict kept at {kept}'))
    if ids:
        print('each of these now needs exactly one outcome before the round can close:')
        for fid in ids:
            print(f'  {fid}')
    return 0


def cmd_range(args) -> int:
    """`loop.py range record` — one row per authored commit range (requirement 3).

    Normally written by `run-codex.sh` write mode rather than by hand: the launcher already knows
    `START_SHA` because it measured it before handing the worktree over, and a row a session has
    to remember is a row that goes missing on the first resume path. The hand-written form exists
    for the case the plan names — a range authored outside a write run — and it refuses to claim
    the complement, because the complement is computed and never asserted.
    """
    arc = need_arc(args)
    if not arc:
        return RC_USAGE
    if args.party not in PARTIES:
        return die(f'--party must be one of {list(PARTIES)}', RC_USAGE)
    if str(args.task) == COMPLEMENT_TASK:
        return die('--task {!r} is reserved: the complement is DERIVED (every commit of the range '
                   'no codex row claims) and never recorded. A row claiming it would let the '
                   'author of those commits name their own reviewing party.'
                   .format(COMPLEMENT_TASK), RC_FAILCLOSED)
    rec = {'arc': canonical_arc(arc), 'track': args.track, 'task': args.task,
           'party': args.party, 'startSha': args.start_sha, 'endSha': args.end_sha}
    missing = [f for f in RANGE_FIELDS if rec.get(f) in (None, '')]
    if missing:
        return die(f'every field of a range row is required; missing: {", ".join(missing)}',
                   RC_USAGE)
    verdict, reason = ranges_record(arc, rec)
    if verdict == 'refuse':
        return die(reason, RC_FAILCLOSED)
    if verdict == 'idempotent':
        print(reason)
        return 0
    print('recorded range {} of track {}: {}..{} authored by {}'
          .format(args.task, args.track, str(args.start_sha)[:12], str(args.end_sha)[:12],
                  args.party))
    return 0


def arc_rounds(events: Sequence[Mapping]) -> dict[str, list[int]]:
    """Every track this arc did anything on, and its rounds in order.

    The reserved one-off track is excluded, because `cmd_close_round` refuses on it by design and
    `converge` requiring a close there would be a requirement nothing can satisfy.
    """
    out: dict[str, set] = {}
    for ev in events:
        if ev.get('ev') not in TRACK_EVENTS:
            continue
        track = str(ev.get('track'))
        rnd = ev.get('round')
        if track in ('', 'None', ONE_OFF_TRACK):
            continue
        if not isinstance(rnd, int) or isinstance(rnd, bool) or rnd < 1:
            continue
        out.setdefault(track, set()).add(rnd)
    return {t: sorted(rs) for t, rs in sorted(out.items())}


def cmd_converge(args) -> int:
    """`loop.py converge` — the one artifact a merge requires, obtainable only by closing everything.

    This closes the gap the launch gate cannot reach. Gating round N+1 gates every round but the
    LAST, and the last is the round convergence is declared on — so the final round's findings,
    the ones that matter most, were the one set nothing could hold. The answer is not a new gate on
    the round; it is to make the artifact the merge already requires be unobtainable while any
    round is open.

    What it verifies, and it is all re-used: every track's every round CLOSED, every finding of
    every round carrying exactly one outcome, and the range table of `--range` with no commit
    claimed twice and every range reviewed by the party that did not write it.

    What it cannot verify, named rather than glossed: CI cannot check that the reviews happened,
    because the arc is local and unpushed — memory a-gate-may-not-read-its-verdict-from-the-gated-party.
    What the committed artifact CAN be held to is its own shape against the real commit list, which
    the product-side validator recomputes from git. That turns "somebody forgot to close a round"
    into "somebody would have to deliberately write a file whose commit list CI recomputes".
    """
    arc = need_arc(args)
    if not arc:
        return RC_USAGE
    repo = os.path.abspath(args.repo or os.getcwd())
    if tree_state(repo) is None:
        return die(f'--repo {repo} is not a git worktree, so the range table cannot be computed '
                   'from git', RC_USAGE)
    events = ledger_read(arc)
    corrupt = ledger_corrupt(events)
    if corrupt:
        return die(f'refusing to declare convergence: {ledger_path(arc)} holds {corrupt} '
                   'unparseable record(s), so an open round cannot be ruled out', RC_FAILCLOSED)
    tracks = arc_rounds(events)
    if not tracks:
        return die(f'refusing to declare convergence: {ledger_path(arc)} records no track with a '
                   'round, so there is nothing whose closure could be checked. An arc that ran '
                   'nothing has not converged; it has not started.', RC_FAILCLOSED)
    rows = outcomes_read(arc)
    corrupt_outcomes = ledger_corrupt(rows)
    if corrupt_outcomes:
        return die(f'refusing to declare convergence: {outcomes_path(arc)} holds '
                   f'{corrupt_outcomes} unparseable row(s), so whether every finding carries an '
                   'outcome cannot be established', RC_FAILCLOSED)
    dupes = store_duplicate_keys(rows, OUTCOME_KEY_FIELDS)
    if dupes:
        return die('refusing to declare convergence: the outcome store holds duplicate key(s) {} '
                   '— two readings of one finding, which every count would answer from whichever '
                   'row it read first'.format(', '.join('/'.join(k) for k in dupes)),
                   RC_FAILCLOSED)
    open_rounds: list[str] = []
    unreadable_all: list[str] = []
    undispositioned: list[str] = []
    table: list[dict] = []
    reported = covered = 0
    for track, rnds in tracks.items():
        entries = []
        for rnd in rnds:
            st = round_status(events, track, rnd)
            if not st['closed']:
                open_rounds.append(
                    '  round {} of track {} is not closed — run:\n    python3 {}/loop.py '
                    'close-round --arc {} --track {} --round {}'
                    .format(rnd, track, HERE, shlex.quote(arc), shlex.quote(track), rnd))
                continue
            found, unreadable = round_findings(events, track, rnd)
            unreadable_all.extend(f'track {track} round {rnd}: {u}' for u in unreadable)
            missing, _stray = outcome_coverage(found, outcomes_for_round(rows, arc, track, rnd))
            reported += len(found)
            covered += len(found) - len(missing)
            if missing:
                undispositioned.append(
                    '  track {} round {}: {} of {} finding(s) carry no outcome — {}'
                    .format(track, rnd, len(missing), len(found), ', '.join(missing)))
            entries.append(dict(round=rnd, closedAt=st['close_t'],
                                closedAtIso=(dt.datetime.fromtimestamp(st['close_t'],
                                                                       dt.timezone.utc).isoformat()
                                             if st['close_t'] else None),
                                findingsReported=len(found),
                                findingsWithOutcome=len(found) - len(missing)))
        table.append(dict(track=track, lastRound=(rnds[-1] if rnds else None), rounds=entries))
    refusals = open_rounds + undispositioned
    if unreadable_all:
        refusals.append('  {} review verdict(s) cannot be read, so a round\'s finding count is '
                        'UNKNOWN and unknown is not zero — {}'
                        .format(len(unreadable_all), '; '.join(unreadable_all)))
    # REFUSE, not report: converge is the one place the claim "every finding is accounted for" is
    # made, and a verdict no ledgered review names is a set of findings that claim silently omits.
    stray = unledgered_verdicts(arc, events)
    if stray:
        refusals.append('  {} review verdict(s) in the arc directory are named by no ledgered '
                        'review, so their findings are counted by nothing — ledger each one '
                        '(then disposition its findings), or move a file that is not a review of '
                        'this arc out of {}:\n{}'
                        .format(len(stray), arc, render_unledgered(arc, stray)))
    verdict, errs = check_ranges(arc, repo, args.range, events, ranges_read(arc))
    if errs:
        refusals.extend('  ' + e for e in errs)
    elif verdict is not None and not verdict['ok']:
        refusals.append(render_range_refusal(verdict))
    if refusals:
        return die('refusing to declare convergence for arc {}:\n{}\n\nEvery one of these is a '
                   'thing the loop promised and can show. Nothing here has an override: the '
                   'artifact a merge requires is exactly the artifact closing everything produces.'
                   .format(arc, '\n'.join(refusals)), RC_GATE)
    assert verdict is not None
    base, head = args.range.split('..', 1) if '..' in args.range else (args.range, 'HEAD')
    doc = {
        'arc': canonical_arc(arc),
        'generatedAt': now(),
        'generatedAtIso': dt.datetime.now(dt.timezone.utc).isoformat(),
        'repo': repo,
        'range': args.range,
        'base': git(repo, 'rev-parse', base.strip() or 'HEAD').strip(),
        'head': git(repo, 'rev-parse', head.strip() or 'HEAD').strip(),
        'tracks': table,
        'findings': {'reported': reported, 'withOutcome': covered},
        'reviewParties': sorted(review_artifact_parties(events)),
        'rangeTable': [
            {k: entry[k] for k in ('task', 'authorParty', 'reviewParty', 'startSha', 'endSha',
                                   'commits')}
            for entry in verdict['table']
        ],
    }
    out = os.path.abspath(args.out or os.path.join(repo, 'convergence.json'))
    write_atomic(out, json.dumps(doc, indent=1) + '\n')
    print('CONVERGED: {} track(s), {} round(s), {} finding(s) all dispositioned, {} range(s) each '
          'reviewed by a non-author.'
          .format(len(table), sum(len(t['rounds']) for t in table), reported,
                  len(doc['rangeTable'])))
    print(f'wrote {out} — commit it, and name it on the pull request\'s `Convergence:` line.')
    return 0


def cmd_run_summary(args) -> int:
    """`loop.py run-summary <record|baseline>` — the run-summary store's two commands (§4.4)."""
    arc = need_arc(args)
    if not arc:
        return RC_USAGE
    if args.action == 'baseline':
        rows = run_summaries_read(arc)
        corrupt = ledger_corrupt(rows)
        if corrupt:
            return die(f'refusing to answer: {run_summaries_path(arc)} holds {corrupt} '
                       'unparseable row(s), so the most recent summary cannot be identified',
                       RC_FAILCLOSED)
        base = run_summary_baseline(rows, arc)
        if base is None:
            # Refuses rather than printing an empty summary: see `run_summary_baseline`.
            return die(f'no run summary is recorded for arc {arc}, so there is no baseline to '
                       'compare against. The keep rule refuses a comparison without one, which is '
                       'the honest first answer rather than a defect to route around: record a '
                       "run's summary with `loop.py run-summary record` and the next run has a "
                       'baseline.', RC_FAILCLOSED)
        print(json.dumps(base, indent=2, sort_keys=True))
        return 0

    if args.judge_model or args.judge_effort:
        if not (args.judge_model and args.judge_effort):
            return die('--judge-model and --judge-effort travel together: a model identity with '
                       'no effort does not identify the judge that ran', RC_USAGE)
        judge = {'model': args.judge_model, 'effort': args.judge_effort}
    elif args.no_judge:
        judge = None
    else:
        # A missing provenance field is reported, never silently filled. S8 persists the judge's
        # identity here, and a run that did no near-miss judging must SAY so.
        return die('this run summary records no judge. Pass --judge-model and --judge-effort for '
                   'a run that judged near misses, or --no-judge for one that did not; an absent '
                   'judge is a recorded fact, not a missing key.', RC_USAGE)

    try:
        with open(args.scores, encoding='utf-8') as fh:
            doc = json.load(fh)
    except (OSError, ValueError) as exc:
        return die(f'cannot read the scored-run document {args.scores}: {exc}', RC_FAILCLOSED)
    try:
        summary = run_summary_from_scores(doc)
    except (KeyError, TypeError, ValueError) as exc:
        return die(f'refusing to record run {args.run_id!r}: {exc}', RC_FAILCLOSED)

    verdict, reason = run_summaries_record(arc, run_summary_row(arc, args.run_id, summary, judge))
    if verdict == 'refuse':
        return die(reason, RC_FAILCLOSED)
    if verdict == 'idempotent':
        print(reason)
        return 0
    print('recorded run {!r}: {} escape case(s), {} caught, {} scorable, {} clean case(s), '
          '{} false alarm(s), manifest {}'
          .format(args.run_id, summary.escape_cases, summary.catches,
                  len(summary.scorable_case_ids), summary.clean_cases, summary.false_alarms,
                  summary.case_manifest_hash))
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
            # Being AT the sha is not the same as MATCHING it. The reuse path compared only
            # head[0] and ignored the working tree, so a snapshot somebody had edited was handed
            # back as the pinned revision and every lens read the edit while reporting the sha.
            # Measured before this fix: a reviewer read 'MUTATED BY SOMEONE' out of a worktree
            # this command had just certified. That is the fail-open the whole read/write overlap
            # rests on, so a tracked modification refuses.
            polluted = snapshot_pollution(path, repo)
            if polluted:
                return die(f'{path} is at {sha[:12]} but carries UNTRACKED entries that sha does not '
                           f'name, so a lens would read them while citing the sha:\n'
                           + '\n'.join('  ' + p for p in polluted[:20])
                           + (f'\n  ... and {len(polluted) - 20} more' if len(polluted) > 20 else '')
                           + f'\nRemove them (git -C {shlex.quote(path)} clean -fd) or remove the '
                             f'snapshot and re-snapshot.', RC_FAILCLOSED)
            dirty = git(path, 'status', '--porcelain', '--untracked-files=no').strip()
            if dirty:
                return die(f'{path} is at {sha[:12]} but has UNCOMMITTED TRACKED CHANGES, so it is '
                           f'not the code that sha names:\n{dirty}\n'
                           f'Reviews of it would cite a sha they did not read. Restore it '
                           f'(git -C {shlex.quote(path)} checkout -- .) or remove it and re-snapshot.',
                           RC_FAILCLOSED)
            print(path)
            return 0
        return die(f'{path} exists but is not at {sha[:12]}', RC_FAILCLOSED)
    os.makedirs(wt_root, exist_ok=True)
    r = subprocess.run(['git', '-C', repo, 'worktree', 'add', '--detach', path, sha], capture_output=True, text=True)
    if r.returncode != 0:
        return die(f'git worktree add failed: {r.stderr.strip()}')
    for rel in SNAPSHOT_INSTALLED:
        src = os.path.join(repo, rel)
        if os.path.isdir(src) and not os.path.exists(os.path.join(path, rel)):
            os.symlink(src, os.path.join(path, rel))
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
    # Defaulted rather than required because every review that reaches `run` is a `run-codex.sh`
    # launch -- this command launches a CHILD PROCESS, and a Claude reviewer subagent is not one.
    # `loop.py review record` is the Claude path. Recorded explicitly anyway, so the independence
    # check reads a field rather than inferring a party from the absence of one.
    p.add_argument('--party', choices=PARTIES, default=DEFAULT_REVIEW_PARTY,
                   help='who authored this review (reviews only; default: %(default)s)')
    p.add_argument('cmd', nargs=argparse.REMAINDER, help='-- command...')
    p.set_defaults(fn=cmd_run)

    # Printed rather than spelled twice: run-codex.sh asks for the reserved track name instead
    # of carrying its own copy of the string. See ONE_OFF_TRACK.
    p = sub.add_parser('one-off-track', help='print the reserved track name --one-off schedules into')
    p.set_defaults(fn=cmd_one_off_track)

    p = sub.add_parser('gate', help='may round N of this track launch?')
    common(p)
    p.set_defaults(fn=cmd_gate)

    p = sub.add_parser('preflight', help="the efficiency review round 1 may not launch without")
    common(p, track=False)
    p.add_argument('--critical-path', dest='critical_path', required=True,
                   help='what is actually on the critical path')
    p.add_argument('--parallel', required=True,
                   help='independent work that will run CONCURRENTLY (or why none of it is independent)')
    p.add_argument('--batch', required=True,
                   help='checks batched into one run (or which ones genuinely need isolation)')
    p.add_argument('--scope', required=True,
                   help='what is NOT re-reviewed/re-verified this time, and why it stays valid')
    p.add_argument('--stop', required=True,
                   help='the BOUNDED stopping condition (a round ceiling, a census, or the finding class that reopens it)')
    p.add_argument('--drivers', required=True,
                   help='projected top cost drivers, and the one being cut before execution')
    p.add_argument('--codex', help='path to the Codex critique of the PROCESS')
    p.add_argument('--codex-unavailable', dest='codex_unavailable',
                   help='why the Codex critique was skipped -- recorded, never silent, and never a blocker')
    p.set_defaults(fn=cmd_preflight)

    p = sub.add_parser('cadence', help='what a REPEATING cheap check owes before its third run')
    common(p, track=False)
    p.add_argument('--kind', required=True, choices=CADENCE_KINDS,
                   help='the repeating kind being priced')
    p.add_argument('--remaining', type=int, required=True,
                   help='iterations still to come -- the count that turns a per-run cost into a bill')
    p.add_argument('--each', required=True,
                   help='measured cost of ONE run')
    p.add_argument('--schedule',
                   help='what MOVES: batch, background, cap, drop (not "make each run cheaper")')
    p.add_argument('--fixed-by', dest='fixed_by',
                   help='the project rule that fixes this rate, when the cadence is not yours to lower')
    p.set_defaults(fn=cmd_cadence)

    p = sub.add_parser('close-round', help='profile the round, write its levers, record the close')
    common(p)
    p.add_argument('--empty-ok', action='store_true')
    p.add_argument('--abandon-unfinished', action='store_true',
                   help='close even though some jobs have no terminal event and their launcher is gone; '
                        'the close records them as abandoned (never allowed while one is still running)')
    p.add_argument('--abandon-unverifiable', default='',
                   help='comma-separated job names that ledgered a start but never a child, whose '
                        'processes you have CONFIRMED gone by hand; nothing else can close over them')
    p.add_argument('--timeline', help='heartbeat file for gap classification (default: <arc>/../timeline.jsonl)')
    p.add_argument('--range', metavar='BASE..HEAD',
                   help='the commit range this round closes over; REQUIRED once the arc records '
                        'any authored range, because requirement 3 cannot be checked without it')
    p.add_argument('--repo', help='worktree to resolve --range in (default: the current directory)')
    p.add_argument('dirs', nargs='*', help='extra artifact dirs to scan heuristically')
    p.set_defaults(fn=cmd_close_round)

    p = sub.add_parser('lever', help='disposition a TRIGGERED lever')
    common(p)
    p.add_argument('--id', required=True)
    p.add_argument('--state', required=True, choices=('landed', 'declined'))
    p.add_argument('--note', required=True)
    p.set_defaults(fn=cmd_lever)

    # NESTED actions, not one flat parser with a positional. `record` requires nine flags and
    # `report` requires none of them, so a single parser would have to drop `required=True` from
    # all nine and re-check them by hand -- which is how a recorder stops failing at the call
    # site. argparse enforces each action's own flags this way, and `loop.py finding record ...`
    # is unchanged for every existing caller.
    p = sub.add_parser('finding', help='the ONE outcome a review finding gets (decision 5)')
    fsub = p.add_subparsers(dest='action', required=True)

    rec = fsub.add_parser('record',
                          help='append one outcome under the (arc, track, round, findingId) key')
    common(rec)
    rec.add_argument('--id', required=True, help="the finding's id, as its verdict file names it")
    rec.add_argument('--severity', required=True, help='the severity the reviewer gave it')
    rec.add_argument('--file', required=True, help='the file the finding cited')
    rec.add_argument('--line-start', dest='line_start', required=True, type=int)
    rec.add_argument('--line-end', dest='line_end', required=True, type=int)
    # Deliberately NOT argparse `choices`: see _finding_record's docstring for why the closed set
    # is checked in the command instead, and why it comes from review_eval not from a literal.
    rec.add_argument('--outcome', required=True,
                     help='one of: ' + ' | '.join(review_eval.FINDING_OUTCOMES))
    rec.add_argument('--note', required=True, help='what happened to this finding')
    rec.set_defaults(fn=cmd_finding)

    rep = fsub.add_parser('report',
                          help='counts by kind, by severity and by round, read from the rows')
    # --track and --round are OPTIONAL here and required on `record`: an outcome is filed under
    # exactly one round, while a report over the whole arc is the common question and is the one
    # that shows a round which recorded nothing.
    common(rep, track=False)
    rep.add_argument('--track', help='report one track only (default: every track in the arc)')
    rep.add_argument('--round', type=int, help='report one round only (needs --track)')
    rep.set_defaults(fn=cmd_finding)

    p = sub.add_parser('review', help='file a review artifact a non-launching party produced (requirement 2)')
    vsub = p.add_subparsers(dest='action', required=True)
    rec = vsub.add_parser('record', help='snapshot one verdict and ledger it as this round\'s review')
    common(rec)
    rec.add_argument('--party', required=True, choices=PARTIES,
                     help='who authored this review; a verdict over a range its own author wrote '
                          'is the substitution the whole loop exists to prevent')
    rec.add_argument('--name', required=True,
                     help='the lens name; a finding\'s id is <name>#<index>, so it must be unique '
                          'within the round')
    rec.add_argument('--verdict', required=True,
                     help='path to the review JSON, validated against review-output.schema.json')
    rec.set_defaults(fn=cmd_review)

    p = sub.add_parser('range', help='the authored-range store (requirement 3): one row per task')
    gsub = p.add_subparsers(dest='action', required=True)
    rec = gsub.add_parser('record', help='append one (arc, track, task) -> party, start, end row')
    common(rec, track=False)
    rec.add_argument('--track', required=True)
    rec.add_argument('--task', required=True, help='the task label this range implements')
    rec.add_argument('--party', required=True, choices=PARTIES, help='who authored these commits')
    rec.add_argument('--start-sha', dest='start_sha', required=True,
                     help='the sha HEAD was at before the author touched the tree')
    rec.add_argument('--end-sha', dest='end_sha', required=True, help='the sha HEAD is at now')
    rec.set_defaults(fn=cmd_range)

    p = sub.add_parser('converge',
                       help='declare the arc converged and write convergence.json (every round '
                            'closed, every finding dispositioned, every range non-author reviewed)')
    p.add_argument('--arc')
    p.add_argument('--range', required=True, metavar='BASE..HEAD',
                   help='the commit range the pull request will carry')
    p.add_argument('--repo', help='worktree to resolve --range in (default: the current directory)')
    p.add_argument('--out', help='where to write convergence.json (default: <repo>/convergence.json)')
    p.set_defaults(fn=cmd_converge)

    p = sub.add_parser('run-summary',
                       help="persist a grading run's result, so a baseline can exist (§4.4)")
    rssub = p.add_subparsers(dest='action', required=True)

    rsr = rssub.add_parser('record', help='append one run summary under the (arc, runId) key')
    common(rsr, track=False)
    rsr.add_argument('--run-id', dest='run_id', required=True,
                     help='this run\'s id, unique within the arc')
    rsr.add_argument('--scores', required=True,
                     help='JSON document holding escapeScores[], cleanFalseAlarms{} and '
                          'caseManifestHash; the summary is built from it through '
                          'review_eval.build_run_summary and never field by field')
    rsr.add_argument('--judge-model', dest='judge_model',
                     help='the near-miss judge\'s model identity (§3.10 provenance)')
    rsr.add_argument('--judge-effort', dest='judge_effort', help="that judge's effort")
    rsr.add_argument('--no-judge', dest='no_judge', action='store_true',
                     help='state that this run judged no near misses')
    rsr.set_defaults(fn=cmd_run_summary)

    rsb = rssub.add_parser('baseline',
                           help='the most recently recorded summary, or a refusal naming the arc')
    common(rsb, track=False)
    rsb.set_defaults(fn=cmd_run_summary)

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
