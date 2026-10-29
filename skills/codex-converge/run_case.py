#!/usr/bin/env python3
"""The case runner (spec §8.1, §8.5): one escape case, reviewed in an answer-free workspace.

## What this module exists to prevent

A case run hands the reviewer the case's `introducing.diff` and nothing else, and that is enforced
by WHERE the reviewer runs rather than by what the prompt omits. The workspace is a temporary
directory OUTSIDE any repository holding exactly two files — the introducing diff and the
reviewer's prompt — with no git repository present. The repair diff, the repair sha, `case.json`
and the repository's history are therefore ABSENT FROM THE FILESYSTEM rather than merely
unmentioned.

The first wording of §8.1 said the reviewer gets the diff "and nothing else", which was a claim
about the prompt while `repair.diff` sat beside it in a tracked tree the launcher was handed. A
reviewer could have manufactured a perfect catch by reading the answer, which invalidates every
score rather than one case.

## The spend gate counts LAUNCHES, not completions (§8.5, decision 15)

A slot is reserved ATOMICALLY BEFORE the reviewer is launched, and every attempted launch consumes
one of the approved slots. Counting completions is the implementation that passes the obvious test
and fails the one decision 15 actually asks for: three interrupted attempts would spend on three
cases while a durable completion counter still read zero, after which the harness would launch
three more. Once the reviewer has launched, the tokens are spent whatever happens next, so the only
honest unit for a spend gate is the launch.

The attempt number is derived as one more than the rows this case already has, so a retry of an
interrupted case is a NEW row and consumes a slot. A reservation written just before a crash that
prevented the launch therefore also spends a slot. That direction is deliberate: a spend gate that
errs may only ever err towards spending LESS.

## Why `--one-off` rather than an attributed launch

`run-codex.sh` refuses an attributed launch through the round gate until the previous round of the
arc is closed and its triggered levers are dispositioned. A grading run is not a round of a
convergence loop and has no round to close, so an attributed launch would be refused for a reason
that has nothing to do with grading. `--one-off` is the launcher's own documented opt-out for a
single call outside any arc.
"""
from __future__ import annotations

import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
from typing import NamedTuple

HERE = os.path.dirname(os.path.abspath(__file__))
if HERE not in sys.path:
    sys.path.insert(0, HERE)
import loop  # noqa: E402
import review_eval  # noqa: E402

#: Decision 15's number, and the one place it is written down.
#:
#: It is a module constant and NOT a parameter read from a file the runner or the reviewer writes.
#: `[[a-gate-may-not-read-its-verdict-from-the-gated-party]]`: a gate may not take its deciding
#: value from the party it gates, and the party being gated here is this harness. Raising it is a
#: deliberate edit of this skill, which is the user's word made mechanical rather than a flag a
#: later run could set for itself.
APPROVED_LAUNCHES = 3

#: One store, beside `outcomes.jsonl` and `run-summaries.jsonl` in the arc directory and never
#: inside either: two stores in one file would make each one's uniqueness key evaluate the
#: other's rows.
LAUNCHES = 'case-launches.jsonl'

#: The uniqueness key. An arc directory is per job and a case id is unique within the case tree,
#: so the three together identify one attempt. `attempt` is IN the key because a retry of an
#: interrupted case must be a second row rather than an idempotent repeat of the first — that is
#: the difference between the gate counting launches and counting cases.
LAUNCH_KEY_FIELDS = ('arc', 'caseId', 'attempt')

#: Everything a second row for one attempt could DISAGREE about. The prompt is compared by HASH
#: rather than by text so a row stays small, and it is in here because the same case reviewed with
#: a different prompt is a different launch, which is the whole subject of decision 4.
LAUNCH_VALUE_FIELDS = ('workspace', 'launcher', 'promptSha256')

#: Stamped outside the key and outside the identity comparison, as both sibling stores do.
LAUNCH_STAMP = 'reservedAt'

#: The completion store. A reservation says a slot was SPENT; this says what the spending bought.
#:
#: They are two files and not one, for the same reason the reservation is not written into
#: `outcomes.jsonl`: two stores in one file make each one's uniqueness key evaluate the other's
#: rows. They are two WRITES of one function, which is the part that matters — a reservation
#: whose completion only ever existed in a returned dictionary left a spent launch with no
#: durable cost and no way to find the artifacts it produced.
COMPLETIONS = 'case-completions.jsonl'

#: One completion per attempt, and the key is the reservation's key so the two rows join.
COMPLETION_KEY_FIELDS = ('arc', 'caseId', 'attempt')

#: What a second completion row for one attempt could disagree about. A launch happens once, so a
#: differing second reading of it is a defect to refuse rather than a later measurement to accept.
COMPLETION_VALUE_FIELDS = ('returncode', 'wallClockSeconds', 'measuredTokens', 'outPath', 'logPath')

COMPLETION_STAMP = 'completedAt'

#: The workspace's closed membership, in the order they are written. Named here so
#: `workspace_findings` and the materialiser cannot disagree about what belongs.
CASE_DIFF_NAME = 'introducing.diff'
PROMPT_NAME = 'reviewer-prompt.txt'
WORKSPACE_MEMBERS = (CASE_DIFF_NAME, PROMPT_NAME)

#: Everything that must not be in the workspace, by SHAPE rather than by name: a future case
#: artefact called `repair-2.diff` or `repair.json` is caught by the prefix, where a name list
#: would admit it. `case.json` is named outright because it carries the defect locations, which
#: are the answer in their most compact form.
ANSWER_SHAPES = (
    ('repair', 'a repair artefact: the defect this case is graded on, already fixed'),
    ('case.json', 'the case record, which carries the defect locations'),
    ('expected', 'an expected-answer artefact'),
)

WORKSPACE_PREFIX = 'review-eval-case-'


class CaseInputs(NamedTuple):
    """One case as the scorer needs it. Every field is required."""

    case_id: str
    kind: str | None
    defects: tuple
    files: tuple[str, ...]
    measured_tokens: int | None

#: The three case partitions of a repository's case tree, each as (directory, the `kind` every
#: record in it must declare).
#:
#: The directory decides which SET a case belongs to and the record's own `kind` must AGREE with
#: it, or `case_ids_in` refuses by name. Selecting on the directory alone would score a case
#: somebody misfiled; selecting on the record alone would score a case somebody moved. Requiring
#: both is what makes "the runner reads only the scorable set" a property of the data rather than
#: of a glob written once.
SCORABLE = ('cases', 'escape')
CLEAN = ('clean', 'clean')
DESIGN_STAGE = ('design-stage', 'design-stage')
PARTITIONS = (SCORABLE, CLEAN, DESIGN_STAGE)


def case_ids_in(review_eval_root: str, partition=SCORABLE) -> tuple[str, ...]:
    """The case ids of one partition of `review_eval_root`, sorted, with the partition enforced.

    `review_eval_root` is supplied by the caller: this module ships no repository's paths. A
    missing partition directory RAISES rather than returning an empty tuple, because an empty
    case set scores a reviewer as having caught nothing and a wrong path is the likeliest way to
    produce one.

    A member is a direct child directory holding a case record. A record whose `kind` disagrees
    with the partition it sits in is named in the refusal, which is the one reading that catches
    a design-stage case moved into the scorable set — the move the empty-defect raise downstream
    could not tell from a case with no defects.
    """
    directory, expected_kind = partition
    root = os.path.join(review_eval_root, directory)
    if not os.path.isdir(root):
        raise FileNotFoundError(
            f'{root} is not a directory: the {expected_kind} case partition must exist, and an '
            'empty case set grades a reviewer as having caught nothing'
        )
    ids, mismatched = [], []
    for name in sorted(os.listdir(root)):
        record = os.path.join(root, name, 'case.json')
        if not os.path.isfile(record):
            continue
        with open(record, encoding='utf-8') as fh:
            declared = json.load(fh).get('kind')
        if declared != expected_kind:
            mismatched.append(f'{name} declares kind {declared!r}')
            continue
        ids.append(name)
    if mismatched:
        raise ValueError(
            f'{root} holds {len(mismatched)} case(s) whose declared kind is not {expected_kind!r}: '
            + '; '.join(mismatched)
        )
    return tuple(ids)


#: The post-image file header of a unified diff. The reviewer cites files as this side spells
#: them, so this is the manifest `catch_verdict` needs: a finding naming a file the diff does not
#: carry is out-of-scope rather than a miss, and that distinction is only as good as this parse.
DIFF_POST_IMAGE_RE = re.compile(r'^\+\+\+ b/(.+)$', re.MULTILINE)


def diff_files(diff_text: str) -> tuple[str, ...]:
    """The post-image paths the reviewer was shown, in first-appearance order, deduplicated.

    Read from the diff the reviewer actually receives rather than from the case record's slice
    manifest. The manifest is the harvester's account of what it kept; the diff is what the
    reviewer read, and a finding is scored against what the reviewer read.
    """
    seen: list[str] = []
    for path in DIFF_POST_IMAGE_RE.findall(diff_text):
        if path != '/dev/null' and path not in seen:
            seen.append(path)
    return tuple(seen)


def load_case(case_dir: str):
    """Read one case into the scorer's inputs: `(case_id, kind, defects, files, measured_tokens)`.

    Returned as a plain tuple-like record built here rather than as the raw mapping, so a caller
    cannot reach past it into a field this function did not validate.

    Every refusal NAMES the case, because a case that cannot be read is an operator's problem and
    "a defect location failed to parse" is unactionable without knowing which case and which
    entry. Two refusals in particular are not conveniences:

    - A `defectLocations` entry that does not parse RAISES rather than being dropped. Dropped
      silently, the case scores against a smaller defect set and a finding that would have been a
      catch reads as a miss, which moves the grade for a data error.
    - An EMPTY `defectLocations` list raises here as well as in the scorer. The scorer's own
      raise is the backstop; this one names the file the operator has to fix.

    `introducing` is required to be a LIST, which is the widened schema. The pre-widening shape
    was a single mapping, and accepting both here would mean two readings of one field living in
    production forever; the integration test that compares the repositories converts a real
    record to its old shape itself to prove the widening is invisible to the score.
    """
    record_path = os.path.join(case_dir, 'case.json')
    case_id = os.path.basename(os.path.normpath(case_dir))
    try:
        with open(record_path, encoding='utf-8') as fh:
            record = json.load(fh)
    except (OSError, ValueError) as cause:
        raise ValueError(f'case {case_id!r} at {record_path} could not be read: {cause}') from cause
    if not isinstance(record, dict):
        raise ValueError(f'case {case_id!r} at {record_path} is not a case record object')
    introducing = record.get('introducing')
    if not isinstance(introducing, list) or not introducing:
        raise ValueError(
            f'case {case_id!r} must carry a non-empty `introducing` LIST (the widened schema); '
            f'it carries {type(introducing).__name__}'
        )
    raw_locations = record.get('defectLocations')
    if not isinstance(raw_locations, list) or not raw_locations:
        raise ValueError(
            f'case {case_id!r} carries no defect location, so it cannot be scored: an empty set '
            'means the repair changed no production line the introducing change had touched, '
            'which means it is not an escape this reviewer could have caught'
        )
    defects, unparsed = [], []
    for index, raw in enumerate(raw_locations):
        parsed = review_eval.parse_defect_location(raw)
        if parsed is None:
            unparsed.append(f'entry {index}: {raw!r}')
            continue
        defects.append(parsed)
    if unparsed:
        raise ValueError(
            f'case {case_id!r} has {len(unparsed)} defect location(s) that did not parse, and a '
            'dropped location scores a catch as a miss: ' + '; '.join(unparsed)
        )
    diff_path = os.path.join(case_dir, CASE_DIFF_NAME)
    try:
        with open(diff_path, encoding='utf-8') as fh:
            text = fh.read()
    except OSError as cause:
        raise ValueError(f'case {case_id!r} has no readable {CASE_DIFF_NAME}: {cause}') from cause
    files = diff_files(text)
    if not files:
        raise ValueError(
            f'case {case_id!r} has a {CASE_DIFF_NAME} with no post-image file header, so every '
            'finding would score as out-of-scope and the case would never be graded'
        )
    return CaseInputs(case_id=case_id, kind=record.get('kind'), defects=tuple(defects),
                      files=files, measured_tokens=record.get('measuredTokens'))


def scorable_case_dirs(review_eval_root: str) -> tuple[str, ...]:
    """Absolute directories of the cases a grading run scores, in id order."""
    directory = SCORABLE[0]
    return tuple(os.path.join(review_eval_root, directory, case_id)
                 for case_id in case_ids_in(review_eval_root, SCORABLE))


#: The policy version this harness acknowledges to the launcher.
#:
#: `run-codex.sh` refuses a launch whose acknowledged version is not its own, so this is a
#: handshake and not a label. It is a COPY of the launcher's own default, which means the two can
#: drift — so `run_case_test.py` reads the launcher's `POLICY_VERSION=` line and asserts equality.
#: A cross-file import is not available here (the launcher is shell), and both files are in this
#: one repository, so the comparison is a real test rather than a note.
POLICY_VERSION = '2026-09-11-reachability-gate-v1'

#: The launcher, resolved beside this module. Named as ONE entry point: decision 14 says the
#: grading tool is built for `codex-converge`'s reviewer only, so a second launch shape here
#: would be the pluggable reviewer interface that decision declines.
LAUNCHER = os.path.join(HERE, 'run-codex.sh')

#: `codex exec` prints its usage as the marker line and the comma-grouped number on the NEXT line.
#: Measured against all 19 Codex run logs of this arc on 2026-10-26: 19 of 19 matched this shape,
#: median 115,039 tokens, min 38,188, max 270,561. Every group is optional in the number so a
#: run under 1,000 tokens still parses.
TOKENS_USED_RE = re.compile(r'^tokens used\s*\n\s*([0-9][0-9,]*)\s*$', re.MULTILINE)


def launches_path(arc: str) -> str:
    return os.path.join(arc, LAUNCHES)


def launches_read(arc: str) -> list[dict]:
    return loop._jsonl_read(launches_path(arc))


def launch_row(arc: str, case_id: str, attempt: int, workspace: str, launcher: str,
               prompt_text: str, out_path: str, log_path: str) -> dict:
    """One reservation as a row. The ONLY serialiser, so there is one field mapping.

    `out_path` and `log_path` are REQUIRED and never defaulted. They are the only durable pointer
    to what a spent slot produced, and a default would make every caller that forgot them look
    exactly like a caller that had nothing to point at.
    """
    return {
        'arc': loop.canonical_arc(arc),
        'caseId': case_id,
        'attempt': attempt,
        'workspace': workspace,
        'launcher': launcher,
        'promptSha256': hashlib.sha256(prompt_text.encode('utf-8')).hexdigest(),
        'outPath': os.path.abspath(out_path),
        'logPath': os.path.abspath(log_path),
    }


def completions_path(arc: str) -> str:
    return os.path.join(arc, COMPLETIONS)


def completions_read(arc: str) -> list[dict]:
    return loop._jsonl_read(completions_path(arc))


def completion_row(arc: str, case_id: str, attempt: int, returncode: int, elapsed: float,
                   measured_tokens, out_path: str, log_path: str) -> dict:
    """One completion as a row. The ONLY serialiser, as with the reservation."""
    return {
        'arc': loop.canonical_arc(arc),
        'caseId': case_id,
        'attempt': attempt,
        'returncode': returncode,
        'wallClockSeconds': round(float(elapsed), 3),
        'measuredTokens': measured_tokens,
        'outPath': os.path.abspath(out_path),
        'logPath': os.path.abspath(log_path),
    }


def completion_admission(existing, new) -> tuple[str, str]:
    """May this completion be appended? Same rule as its three sibling stores, its own words."""
    verdict, was, fields = loop.store_admission(existing, new, COMPLETION_KEY_FIELDS,
                                                COMPLETION_VALUE_FIELDS)
    if verdict == 'append':
        return 'append', ''
    if verdict == 'idempotent':
        return 'idempotent', (
            'attempt {} of case {} in arc {} already carries an identical completion; recorded '
            'once, so this retry appends nothing'
            .format(new.get('attempt'), new.get('caseId'), new.get('arc'))
        )
    return 'refuse', (
        'attempt {} of case {} in arc {} already carries a completion and this one differs on {}. '
        'A launch happens once, so two readings of what it cost is a defect rather than a later '
        'measurement. The stored row stands.'
        .format(new.get('attempt'), new.get('caseId'), new.get('arc'), ', '.join(fields))
    )


def record_completion(arc: str, case_id: str, attempt: int, returncode: int, elapsed: float,
                      measured_tokens, out_path: str, log_path: str) -> tuple[str, str]:
    """Append what one spent launch produced, as ONE transaction under the store's lock."""
    row = completion_row(arc, case_id, attempt, returncode, elapsed, measured_tokens,
                         out_path, log_path)
    return loop.store_record(completions_path(arc), row,
                             lambda rows, r: completion_admission(rows, r),
                             COMPLETION_STAMP, 'completion for this attempt')


def completions_for_arc(rows, arc: str) -> list[dict]:
    """Every completion belonging to `arc`, compared through the one canonical spelling."""
    want = loop.canonical_arc(arc)
    return [r for r in rows if loop.canonical_arc(str(r.get('arc') or '')) == want]


def unreconciled_launches(arc: str) -> list[dict]:
    """Reservations with no completion row: the slots a resume must account for by hand.

    This is what the pair of stores exists to answer. Before it, a crash between the reservation
    and the caller saving the returned dictionary left a spent slot whose artifacts nothing named.
    """
    done = {(r.get('caseId'), r.get('attempt')) for r in completions_for_arc(completions_read(arc), arc)}
    return [r for r in launches_for_arc(launches_read(arc), arc)
            if (r.get('caseId'), r.get('attempt')) not in done]


def launches_for_arc(rows, arc: str) -> list[dict]:
    """Every reservation belonging to `arc`, compared through the one CANONICAL spelling.

    A store read through a relative path, through an absolute one, and through a symlink are the
    same store, and a gate that counted them separately would hand out three more slots to a
    caller who happened to spell the arc differently. `abspath` alone did not close that: it
    normalises a relative prefix and leaves a symlink standing, so three launches reserved through
    a linked arc were invisible to a fourth call that used the real path.
    """
    want = loop.canonical_arc(arc)
    return [r for r in rows if loop.canonical_arc(str(r.get('arc') or '')) == want]


def next_attempt(rows, arc: str, case_id: str) -> int:
    """One more than the attempts this case already has in this arc. 1-based."""
    mine = [r for r in launches_for_arc(rows, arc) if str(r.get('caseId')) == str(case_id)]
    return len(mine) + 1


def launch_slot_verdict(rows, arc: str, approved: int = APPROVED_LAUNCHES) -> tuple[str, str]:
    """May another reviewer be launched in `arc`? Returns `('reserve' | 'refuse', reason)`.

    Pure, so the gate is exercisable without a filesystem and so a mutant that drops the
    comparison is killed by an assertion about the DECISION rather than about a file's line count.

    It counts ROWS, every row, whatever became of the launch each one reserved. A row with no
    outcome is an attempt that was interrupted, and §8.5 says it keeps its slot: it needs the user's
    word to be replaced, and is never silently retried into a fourth launch.
    """
    if not isinstance(approved, int) or isinstance(approved, bool) or approved < 0:
        raise ValueError(f'approved launches must be a non-negative int, got {approved!r}')
    spent = len(launches_for_arc(rows, arc))
    if spent < approved:
        return 'reserve', ''
    return 'refuse', (
        'refusing to launch: {} of {} approved case launches are already spent in arc {}. The '
        'gate counts LAUNCHES and not completions (§8.5), so an interrupted attempt keeps its '
        'slot. Decision 15 stops the run here for the user\'s word; raising the number is a '
        'deliberate edit of APPROVED_LAUNCHES in run_case.py, never something a run decides.'
        .format(spent, approved, arc)
    )


def launch_admission(existing, new) -> tuple[str, str]:
    """May this reservation be appended? Same rule as the two sibling stores, its own words."""
    verdict, was, fields = loop.store_admission(existing, new, LAUNCH_KEY_FIELDS,
                                                LAUNCH_VALUE_FIELDS)
    if verdict == 'append':
        return 'append', ''
    if verdict == 'idempotent':
        return 'idempotent', (
            'attempt {} of case {} in arc {} is already reserved with identical details; '
            'reserved once, so this retry appends nothing'
            .format(new.get('attempt'), new.get('caseId'), new.get('arc'))
        )
    return 'refuse', (
        'attempt {} of case {} in arc {} is already reserved and this reservation differs on {}. '
        'One attempt, one reservation: a second reading of one launch would let the gate count '
        'two launches as one. The stored row stands.'
        .format(new.get('attempt'), new.get('caseId'), new.get('arc'), ', '.join(fields))
    )


def reserve_launch_slot(arc: str, case_id: str, workspace: str, launcher: str, prompt_text: str,
                        out_path: str, log_path: str,
                        approved: int = APPROVED_LAUNCHES) -> tuple[str, str, dict | None]:
    """Spend one slot, as ONE transaction. Returns `(verdict, reason, the row or None)`.

    The gate is evaluated INSIDE the store's lock, together with the append. Evaluating it outside
    and appending afterwards is the shape where two runners both read two spent slots and both
    launch — `[[couple-an-effect-to-its-write-at-the-chokepoint]]`: the decision and the write that
    records it are one function and one transaction, never a caller's discipline.
    """
    os.makedirs(arc, exist_ok=True)
    path = launches_path(arc)
    state: dict = {}

    def decide(records, row):
        verdict, reason = launch_slot_verdict(records, arc, approved)
        if verdict == 'refuse':
            return 'refuse', reason
        attempt = next_attempt(records, arc, case_id)
        state['row'] = dict(row, attempt=attempt)
        admitted, why = launch_admission(records, state['row'])
        # Returned as the third element, so the row the key was CHECKED against is the row the
        # transaction writes. Returning only the verdict left the placeholder row to be stored.
        return admitted, why, state['row']

    # The attempt number is not knowable until the rows are read under the lock, so the row handed
    # to the transaction carries a placeholder and `decide` replaces it with the real one, then
    # hands that row back to be written. `state` keeps a copy for the return value.
    seed = launch_row(arc, case_id, 0, workspace, launcher, prompt_text, out_path, log_path)
    verdict, reason = loop.store_record(path, seed, lambda rows, _row: decide(rows, seed),
                                        LAUNCH_STAMP, 'reservation for this attempt')
    return verdict, reason, state.get('row')


def workspace_findings(workspace: str) -> list[str]:
    """Everything in `workspace` that must not be there, as one finding per problem.

    This is S10's assertion as a FUNCTION, so the same rule the test pins is the rule the runner
    can check before it launches, rather than two spellings of one property.

    Three kinds of finding, and the third is the one a name list would miss:

    - a member of `WORKSPACE_MEMBERS` that is absent, because a workspace with no diff reviews
      nothing and would score as a miss on every case;
    - an entry that is neither member, named with what it leaks;
    - a git repository, reachable from here by ANY route — `.git` in the workspace, or an ancestor
      directory that is itself a repository, which is what a `tempfile.mkdtemp()` inside a checkout
      would quietly give you.
    """
    findings = []
    try:
        entries = sorted(os.listdir(workspace))
    except OSError as exc:
        return [f'the workspace {workspace} cannot be listed: {exc}']

    for member in WORKSPACE_MEMBERS:
        if member not in entries:
            findings.append(f'{member} is missing from the workspace')

    for entry in entries:
        if entry in WORKSPACE_MEMBERS:
            continue
        lowered = entry.lower()
        leak = next((why for shape, why in ANSWER_SHAPES if lowered.startswith(shape)), None)
        findings.append(
            f'{entry} is in the workspace and is {leak}' if leak
            else f'{entry} is in the workspace and is not one of {", ".join(WORKSPACE_MEMBERS)}'
        )

    repo = git_toplevel(workspace)
    if repo is not None:
        findings.append(
            f'the workspace is inside the git repository at {repo}, so the case history is '
            'readable from it'
        )
    return findings


def git_toplevel(path: str) -> str | None:
    """The repository `path` is inside, or `None`. A failure to ask is reported as inside.

    Fail-closed on purpose: a `git` that cannot be run tells us nothing about whether this
    directory is in a repository, and the answer that costs something is the false "no".
    """
    try:
        done = subprocess.run(['git', '-C', path, 'rev-parse', '--show-toplevel'],
                              capture_output=True, text=True, timeout=30)
    except (OSError, subprocess.SubprocessError) as exc:
        return f'<unknown: git could not be run ({exc})>'
    if done.returncode != 0:
        return None
    return done.stdout.strip() or None


def materialise_workspace(case_dir: str, prompt_text: str, parent: str | None = None) -> str:
    """Build the answer-free workspace and return its path.

    `parent` defaults to the platform temporary directory, which is OUTSIDE every checkout. It is
    a parameter only so a test can prove the repository check fires; a caller passing a path inside
    a repository gets a workspace `workspace_findings` refuses, which is the point.
    """
    diff_source = os.path.join(case_dir, CASE_DIFF_NAME)
    if not os.path.isfile(diff_source):
        raise FileNotFoundError(
            f'{diff_source} does not exist, so there is nothing for the reviewer to read. A case '
            'with no introducing diff would score as a miss on a reviewer that did nothing wrong.'
        )
    if not prompt_text.strip():
        raise ValueError('the reviewer prompt is empty, so the launch would review nothing')

    workspace = tempfile.mkdtemp(prefix=WORKSPACE_PREFIX, dir=parent)
    with open(diff_source, encoding='utf-8') as src:
        diff_text = src.read()
    # Written rather than copied, so no mode, no extended attribute and no hard link follows the
    # file out of the tracked tree with it.
    with open(os.path.join(workspace, CASE_DIFF_NAME), 'w', encoding='utf-8') as out:
        out.write(diff_text)
    with open(os.path.join(workspace, PROMPT_NAME), 'w', encoding='utf-8') as out:
        out.write(prompt_text)
    return workspace


def launcher_argv(launcher: str, prompt_path: str, out_path: str, log_path: str,
                  workspace: str, codex_args=()) -> list[str]:
    """The ONE launcher entry point this harness names (§10.2, decision 14).

    One entry point and no reviewer interface to choose between: decision 14 says the grading tool
    is built for `codex-converge`'s reviewer only, so a second launch shape here would be the
    pluggable interface that decision declines.
    """
    return [
        launcher,
        '--policy-version', POLICY_VERSION,
        '--one-off',
        prompt_path, out_path, log_path, workspace, *codex_args,
    ]


def measured_tokens_from_log(log_text: str) -> int | None:
    """The tokens the launcher's own log reports, or `None` when it reports none.

    `None` and never 0, and never a projection from bytes. A spend gate that reported an estimate
    as a measurement would be reporting a number the user cannot act on, and 0 would read as a free
    run. `project_tokens_from_bytes` exists for admission and is not an answer to "what did this
    cost".
    """
    found = TOKENS_USED_RE.findall(log_text or '')
    if not found:
        return None
    return int(found[-1].replace(',', ''))


def run_case(arc: str, case_dir: str, prompt_text: str, launcher: str, out_path: str,
             log_path: str, case_id: str | None = None, codex_args=(),
             approved: int = APPROVED_LAUNCHES, launch=None,
             workspace_parent: str | None = None) -> dict:
    """Review one case. Returns the record of what happened, launched or refused.

    The order is the contract: materialise, CHECK the workspace is answer-free, reserve a slot,
    then launch. Checking after the launch would report a leak the reviewer had already read, and
    reserving before the check would spend a slot on a workspace that must not be used.

    `launch(argv) -> (returncode, log_text)` is injected so the test can drive every path without
    spending money on a real reviewer, which is the subject of the gate it is testing.
    """
    case = case_id if case_id is not None else os.path.basename(os.path.normpath(case_dir))
    workspace = materialise_workspace(case_dir, prompt_text, workspace_parent)
    # ONE release site, bound to leaving this scope rather than to returning from it. The
    # workspace holds the private introducing diff, and before this `finally` existed every exit
    # path leaked it into the platform temporary directory: the two refusals returned directly,
    # and an exception or a KeyboardInterrupt in the launcher bypassed cleanup entirely. A green
    # run reached neither of those paths, which is why a passing suite said nothing about it.
    try:
        findings = workspace_findings(workspace)
        if findings:
            return {'launched': False,
                    'reason': 'workspace is not answer-free: ' + '; '.join(findings),
                    'caseId': case, 'workspace': workspace, 'findings': findings}

        verdict, reason, row = reserve_launch_slot(arc, case, workspace, launcher, prompt_text,
                                                   out_path, log_path, approved)
        if verdict == 'refuse':
            return {'launched': False, 'reason': reason, 'caseId': case, 'workspace': workspace}

        argv = launcher_argv(launcher, os.path.join(workspace, PROMPT_NAME), out_path, log_path,
                             workspace, codex_args)
        started = time.monotonic()
        if launch is None:
            launch = _subprocess_launch
        # `log_path` is passed rather than taken from the end of `argv`, because `codex_args`
        # follow the positional arguments: reading `argv[-2]` would name a codex flag the moment a
        # caller passed one, and then report a run's cost as unmeasured for no stated reason.
        attempt = row['attempt'] if row else None
        try:
            rc, log_text = launch(argv, log_path)
            elapsed = time.monotonic() - started
            tokens = measured_tokens_from_log(log_text)
        except BaseException as exc:
            # The slot is already spent, so the completion is owed whatever the launcher did. An
            # interrupted launch that recorded nothing is the state `unreconciled_launches` had to
            # be invented for; recording it here means the reconciliation list holds only the
            # crashes that never reached this line at all.
            record_completion(arc, case, attempt, -1, time.monotonic() - started, None,
                              out_path, log_path)
            raise
        # The reservation and this row are the two halves of one effect, written by one function
        # inside one call. A caller that saves the returned dictionary adds nothing durable that
        # is not already on disk, and a caller that crashes before saving it loses nothing.
        recorded, record_reason = record_completion(arc, case, attempt, rc, elapsed, tokens,
                                                    out_path, log_path)
        return {
            'launched': True,
            'caseId': case,
            'attempt': attempt,
            'workspace': workspace,
            'returncode': rc,
            'wallClockSeconds': round(elapsed, 3),
            'measuredTokens': tokens,
            'reservation': verdict,
            'reason': reason,
            'completion': recorded,
            'completionReason': record_reason,
            'outPath': os.path.abspath(out_path),
            'logPath': os.path.abspath(log_path),
        }
    finally:
        shutil.rmtree(workspace, ignore_errors=True)


def _subprocess_launch(argv, log_path: str) -> tuple[int, str]:
    """Run the launcher and hand back its return code and its own log.

    The log the LAUNCHER wrote is the measurement's source, with the process's own streams as the
    fallback only when the launcher wrote no log at all — a launch that died before opening it.
    """
    done = subprocess.run(argv, capture_output=True, text=True)
    if log_path and os.path.isfile(log_path):
        with open(log_path, encoding='utf-8', errors='replace') as fh:
            return done.returncode, fh.read()
    return done.returncode, (done.stdout or '') + (done.stderr or '')
