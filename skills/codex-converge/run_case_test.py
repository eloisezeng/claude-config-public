#!/usr/bin/env python3
"""run_case_test.py — pins §8.1's answer-free workspace and §8.5's launch-counting spend gate.

Run:  python3 run_case_test.py [-k PATTERN]
Prints a vitest-shaped `Test Files` / `Tests` summary so mutate.py's zero-match guard applies:
  mutate.py --src=run_case.py --test=run_case_test.py --copy-dir=<copy> \
            --mutants=<json> --test-cmd='python3 {test} {filter}' --filter-flag=-k

Two properties are what this file exists for, and both have a positive control, because a guard
that has never been shown to FAIL is a guard that cannot pass for a known reason.

**The gate counts launches.** A completion counter passes the obvious "the fourth launch is
refused" row and fails `test_refuses_a_fourth_after_three_interrupted_launches`, which is decision
15's actual requirement — three interrupted attempts spend on three cases while a durable
completion counter still reads zero.

**The workspace is answer-free.** `test_a_workspace_holding_a_repair_diff_is_refused` builds a
workspace that DOES hold `repair.diff` and asserts the same rule reports it, so the green on the
real workspace is about that workspace rather than about a rule that reports nothing.
"""
from __future__ import annotations

import ast
import os
import re
import subprocess
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import run_case  # noqa: E402

PROMPT = 'Review the diff in introducing.diff and report every defect you find.\n'
DIFF = '--- a/x.ts\n+++ b/x.ts\n@@ -1,1 +1,1 @@\n-const a = 1\n+const a = 2\n'


def write(path: str, text: str) -> str:
    with open(path, 'w', encoding='utf-8') as fh:
        fh.write(text)
    return path


def case_tree(root: str, case_id: str = '101-202', *, diff: str | None = DIFF,
              extras=()) -> str:
    """A case directory as the harvester writes one: the diff, the answer, and the record."""
    case_dir = os.path.join(root, case_id)
    os.makedirs(case_dir, exist_ok=True)
    if diff is not None:
        write(os.path.join(case_dir, 'introducing.diff'), diff)
    # The two artefacts that must never reach the workspace are PRESENT in the case tree, which is
    # what makes the isolation a real property rather than an absence nobody created.
    write(os.path.join(case_dir, 'repair.diff'), '--- a/x.ts\n+++ b/x.ts\n@@ -1,1 +1,1 @@\n')
    write(os.path.join(case_dir, 'case.json'), '{"caseId": "101-202", "defectLocations": []}')
    for name, text in extras:
        write(os.path.join(case_dir, name), text)
    return case_dir


def recording_launch(calls: list, rc: int = 0, log: str = 'tokens used\n42,000\n'):
    def launch(argv, log_path):
        # Read the workspace AS THE LAUNCHER WOULD SEE IT, at launch time. Checking after the call
        # returns would describe a directory the reviewer had already finished reading.
        workspace = argv[-1]
        calls.append({'argv': list(argv), 'logPath': log_path,
                      'workspaceAtLaunch': sorted(os.listdir(workspace)),
                      'findingsAtLaunch': run_case.workspace_findings(workspace)})
        return rc, log
    return launch


def interrupted_launch(calls: list):
    """An attempt that dies after the reviewer was launched. The slot is already spent."""
    def launch(argv, log_path):
        calls.append({'argv': list(argv)})
        raise KeyboardInterrupt('the attempt was interrupted after the reviewer started')
    return launch


class WorkspaceIsolation(unittest.TestCase):
    def test_the_workspace_holds_the_diff_and_the_prompt_and_nothing_else(self):
        with tempfile.TemporaryDirectory() as root:
            case_dir = case_tree(root)
            workspace = run_case.materialise_workspace(case_dir, PROMPT)
            self.assertEqual(sorted(os.listdir(workspace)),
                             ['introducing.diff', 'reviewer-prompt.txt'])
            self.assertEqual(run_case.workspace_findings(workspace), [])
            with open(os.path.join(workspace, 'introducing.diff'), encoding='utf-8') as fh:
                self.assertEqual(fh.read(), DIFF)

    def test_no_repair_artefact_and_no_case_record_reach_the_workspace(self):
        # Named separately from the membership assertion above because this is the property §8.1
        # is about, and the case tree it was copied from HOLDS both of them.
        with tempfile.TemporaryDirectory() as root:
            workspace = run_case.materialise_workspace(case_tree(root), PROMPT)
            entries = os.listdir(workspace)
            self.assertEqual([e for e in entries if e.startswith('repair')], [])
            self.assertNotIn('case.json', entries)

    def test_the_workspace_is_not_a_git_repository(self):
        with tempfile.TemporaryDirectory() as root:
            workspace = run_case.materialise_workspace(case_tree(root), PROMPT)
            done = subprocess.run(['git', '-C', workspace, 'rev-parse', 'HEAD'],
                                  capture_output=True, text=True)
            self.assertNotEqual(done.returncode, 0)
            self.assertIsNone(run_case.git_toplevel(workspace))

    def test_a_workspace_holding_a_repair_diff_is_refused(self):
        # THE POSITIVE CONTROL for every green above: the same rule, a workspace that does hold
        # the answer, and a finding that names it.
        with tempfile.TemporaryDirectory() as root:
            workspace = run_case.materialise_workspace(case_tree(root), PROMPT)
            write(os.path.join(workspace, 'repair.diff'), 'the answer')
            findings = run_case.workspace_findings(workspace)
            self.assertEqual(len(findings), 1, findings)
            self.assertIn('repair.diff', findings[0])
            self.assertIn('already fixed', findings[0])

    def test_every_answer_shape_is_refused_not_only_the_one_name(self):
        # A name list would admit `repair-2.diff` and `expected-findings.json`. The rule is by
        # SHAPE, so a future artefact of the same kind is caught without being enumerated.
        for leaked in ('repair.diff', 'repair-2.diff', 'repairs.json', 'case.json',
                       'expected-findings.json'):
            with tempfile.TemporaryDirectory() as root:
                workspace = run_case.materialise_workspace(case_tree(root), PROMPT)
                write(os.path.join(workspace, leaked), 'x')
                findings = run_case.workspace_findings(workspace)
                self.assertEqual(len(findings), 1, (leaked, findings))
                self.assertIn(leaked, findings[0])

    def test_an_unrecognised_entry_is_refused_rather_than_ignored(self):
        with tempfile.TemporaryDirectory() as root:
            workspace = run_case.materialise_workspace(case_tree(root), PROMPT)
            write(os.path.join(workspace, 'notes.md'), 'x')
            findings = run_case.workspace_findings(workspace)
            self.assertEqual(len(findings), 1, findings)
            self.assertIn('notes.md', findings[0])

    def test_a_missing_member_is_a_finding(self):
        # A workspace with no diff reviews nothing and would score as a miss against a reviewer
        # that did nothing wrong, so its absence is a finding and not an empty success.
        with tempfile.TemporaryDirectory() as workspace:
            findings = run_case.workspace_findings(workspace)
            self.assertEqual(sorted(findings), [
                'introducing.diff is missing from the workspace',
                'reviewer-prompt.txt is missing from the workspace',
            ])

    def test_a_workspace_inside_a_repository_is_refused(self):
        # P11c, the assertion plan round 1 moved here: the only repository that can see
        # `run_case.py` is this one. `tempfile.mkdtemp(dir=…)` inside a checkout is exactly how a
        # caller would do this by accident, and the history would then be readable.
        with tempfile.TemporaryDirectory() as root:
            subprocess.run(['git', 'init', '-q', root], check=True, capture_output=True)
            case_dir = case_tree(os.path.join(root, 'cases'))
            workspace = run_case.materialise_workspace(case_dir, PROMPT, parent=root)
            findings = run_case.workspace_findings(workspace)
            self.assertEqual(len(findings), 1, findings)
            self.assertIn('is inside the git repository at', findings[0])
            self.assertIn('history is', findings[0])

    def test_materialising_refuses_a_case_with_no_introducing_diff(self):
        with tempfile.TemporaryDirectory() as root:
            case_dir = case_tree(root, diff=None)
            with self.assertRaises(FileNotFoundError) as caught:
                run_case.materialise_workspace(case_dir, PROMPT)
            self.assertIn('nothing for the reviewer to read', str(caught.exception))

    def test_materialising_refuses_an_empty_prompt(self):
        with tempfile.TemporaryDirectory() as root:
            for empty in ('', '   \n\t'):
                with self.assertRaises(ValueError):
                    run_case.materialise_workspace(case_tree(root), empty)

    def test_git_toplevel_reports_inside_when_it_cannot_ask(self):
        # Fail-closed: a `git` that cannot run says nothing about whether this is a repository,
        # and the answer that costs something is the false "no".
        answer = run_case.git_toplevel(os.path.join(HERE, 'does-not-exist-' + 'x' * 8))
        self.assertTrue(answer is None or 'unknown' in answer,
                        f'expected None or an unknown marker, got {answer!r}')


class SpendGate(unittest.TestCase):
    def rows(self, arc: str, n: int, case_prefix: str = 'case'):
        return [run_case.launch_row(arc, f'{case_prefix}{i}', 1, '/w', '/l', PROMPT, '/o', '/g')
                for i in range(n)]

    def test_the_pure_gate_reserves_up_to_the_approved_count_and_then_refuses(self):
        arc = '/tmp/arc'
        for spent in (0, 1, 2):
            self.assertEqual(run_case.launch_slot_verdict(self.rows(arc, spent), arc)[0],
                             'reserve', f'{spent} spent must still reserve')
        verdict, reason = run_case.launch_slot_verdict(self.rows(arc, 3), arc)
        self.assertEqual(verdict, 'refuse')
        self.assertIn('3 of 3 approved case launches', reason)
        self.assertIn('counts LAUNCHES and not completions', reason)
        self.assertIn('APPROVED_LAUNCHES', reason)

    def test_the_gate_counts_only_this_arcs_rows_and_compares_paths_absolutely(self):
        rows = self.rows('/tmp/arc-a', 3) + self.rows('/tmp/arc-b', 3, 'other')
        self.assertEqual(run_case.launch_slot_verdict(rows, '/tmp/arc-c')[0], 'reserve')
        self.assertEqual(run_case.launch_slot_verdict(rows, '/tmp/arc-a')[0], 'refuse')
        # One store spelled two ways is one store. A gate that counted them separately would hand
        # out three more slots to a caller who wrote the arc relatively.
        here = os.path.abspath('.')
        self.assertEqual(
            run_case.launch_slot_verdict(self.rows(here, 3), '.')[0], 'refuse')

    def test_approved_zero_refuses_the_first_launch(self):
        verdict, reason = run_case.launch_slot_verdict([], '/tmp/arc', approved=0)
        self.assertEqual(verdict, 'refuse')
        self.assertIn('0 of 0', reason)

    def test_a_negative_or_non_integer_approval_is_refused_outright(self):
        for bad in (-1, 1.5, True, '3', None):
            with self.assertRaises(ValueError, msg=f'{bad!r} must not be an approval'):
                run_case.launch_slot_verdict([], '/tmp/arc', approved=bad)

    def test_next_attempt_is_per_case_and_one_based(self):
        arc = '/tmp/arc'
        rows = [run_case.launch_row(arc, 'a', 1, '/w', '/l', PROMPT, '/o', '/g'),
                run_case.launch_row(arc, 'a', 2, '/w', '/l', PROMPT, '/o', '/g'),
                run_case.launch_row(arc, 'b', 1, '/w', '/l', PROMPT, '/o', '/g')]
        self.assertEqual(
            (run_case.next_attempt(rows, arc, 'a'), run_case.next_attempt(rows, arc, 'b'),
             run_case.next_attempt(rows, arc, 'c')),
            (3, 2, 1))

    def test_reserving_is_one_transaction_and_a_repeat_appends_nothing(self):
        with tempfile.TemporaryDirectory() as arc:
            first = run_case.reserve_launch_slot(arc, 'c1', '/w', '/l', PROMPT, '/o', '/g')
            self.assertEqual((first[0], first[2]['attempt']), ('append', 1))
            # A second call for the same case is a second ATTEMPT, so it is a new row and spends a
            # slot. That is the difference between counting launches and counting cases.
            second = run_case.reserve_launch_slot(arc, 'c1', '/w', '/l', PROMPT, '/o', '/g')
            self.assertEqual((second[0], second[2]['attempt']), ('append', 2))
            self.assertEqual(len(run_case.launches_read(arc)), 2)

    def test_an_identical_reservation_for_one_attempt_is_idempotent(self):
        with tempfile.TemporaryDirectory() as arc:
            row = run_case.launch_row(arc, 'c1', 1, '/w', '/l', PROMPT, '/o', '/g')
            self.assertEqual(run_case.launch_admission([], row)[0], 'append')
            self.assertEqual(run_case.launch_admission([row], row)[0], 'idempotent')
            differing = dict(row, workspace='/elsewhere')
            verdict, reason = run_case.launch_admission([row], differing)
            self.assertEqual(verdict, 'refuse')
            self.assertIn('workspace', reason)
            self.assertIn('count two launches as one', reason)

    def test_refuses_the_fourth_launch(self):
        calls: list = []
        with tempfile.TemporaryDirectory() as root:
            arc = os.path.join(root, 'arc')
            case_dir = case_tree(root)
            out, log = os.path.join(root, 'o.json'), os.path.join(root, 'l.log')
            for i in range(3):
                result = run_case.run_case(arc, case_dir, PROMPT, '/bin/true', out, log,
                                           case_id=f'c{i}', launch=recording_launch(calls))
                self.assertTrue(result['launched'], result)
            fourth = run_case.run_case(arc, case_dir, PROMPT, '/bin/true', out, log,
                                       case_id='c3', launch=recording_launch(calls))
            self.assertFalse(fourth['launched'])
            self.assertIn('3 of 3 approved case launches', fourth['reason'])
            self.assertEqual(len(calls), 3, 'the fourth reviewer must never have been launched')

    def test_refuses_a_fourth_after_three_interrupted_launches(self):
        # DECISION 15's ACTUAL REQUIREMENT, and the row a completion counter fails. None of these
        # three attempts completes, so a counter of completions reads 0 and would launch three
        # more — spending on six cases while reporting three.
        calls: list = []
        with tempfile.TemporaryDirectory() as root:
            arc = os.path.join(root, 'arc')
            case_dir = case_tree(root)
            out, log = os.path.join(root, 'o.json'), os.path.join(root, 'l.log')
            for i in range(3):
                with self.assertRaises(KeyboardInterrupt):
                    run_case.run_case(arc, case_dir, PROMPT, '/bin/true', out, log,
                                      case_id=f'c{i}', launch=interrupted_launch(calls))
            self.assertEqual(len(calls), 3)
            # The slots are spent on the ledger even though nothing completed.
            self.assertEqual(len(run_case.launches_read(arc)), 3)
            fourth = run_case.run_case(arc, case_dir, PROMPT, '/bin/true', out, log,
                                       case_id='c3', launch=recording_launch(calls))
            self.assertFalse(fourth['launched'])
            self.assertIn('an interrupted attempt keeps its', fourth['reason'])
            self.assertEqual(len(calls), 3, 'the fourth reviewer must never have been launched')

    def test_a_retry_of_one_interrupted_case_also_spends_a_slot(self):
        # The same case twice is two launches. Keying on the case alone would make the retry
        # idempotent and leave a fourth case launchable.
        calls: list = []
        with tempfile.TemporaryDirectory() as root:
            arc = os.path.join(root, 'arc')
            case_dir = case_tree(root)
            out, log = os.path.join(root, 'o.json'), os.path.join(root, 'l.log')
            with self.assertRaises(KeyboardInterrupt):
                run_case.run_case(arc, case_dir, PROMPT, '/bin/true', out, log, case_id='c0',
                                  launch=interrupted_launch(calls))
            again = run_case.run_case(arc, case_dir, PROMPT, '/bin/true', out, log, case_id='c0',
                                      launch=recording_launch(calls))
            self.assertEqual((again['launched'], again['attempt']), (True, 2))
            self.assertEqual(len(run_case.launches_read(arc)), 2)
            self.assertEqual(run_case.launch_slot_verdict(run_case.launches_read(arc), arc)[0],
                             'reserve')

    def test_a_refused_launch_appends_no_row(self):
        with tempfile.TemporaryDirectory() as root:
            arc = os.path.join(root, 'arc')
            case_dir = case_tree(root)
            out, log = os.path.join(root, 'o.json'), os.path.join(root, 'l.log')
            run_case.run_case(arc, case_dir, PROMPT, '/bin/true', out, log, case_id='c0',
                              launch=recording_launch([]), approved=1)
            before = len(run_case.launches_read(arc))
            run_case.run_case(arc, case_dir, PROMPT, '/bin/true', out, log, case_id='c1',
                              launch=recording_launch([]), approved=1)
            self.assertEqual(len(run_case.launches_read(arc)), before)

    def test_a_leaking_workspace_is_refused_before_a_slot_is_spent(self):
        # Order is the contract: reserving before the check would spend a slot on a workspace that
        # must not be used, and checking after the launch would report a leak already read.
        calls: list = []
        with tempfile.TemporaryDirectory() as root:
            arc = os.path.join(root, 'arc')
            case_dir = case_tree(root)
            subprocess.run(['git', 'init', '-q', root], check=True, capture_output=True)
            out, log = os.path.join(root, 'o.json'), os.path.join(root, 'l.log')
            result = run_case.run_case(arc, case_dir, PROMPT, '/bin/true', out, log,
                                       case_id='c0', launch=recording_launch(calls),
                                       workspace_parent=root)
            self.assertFalse(result['launched'])
            self.assertIn('workspace is not answer-free', result['reason'])
            self.assertEqual(calls, [])
            self.assertEqual(run_case.launches_read(arc), [])


class LaunchShape(unittest.TestCase):
    def test_the_launcher_sees_an_answer_free_workspace_at_launch_time(self):
        calls: list = []
        with tempfile.TemporaryDirectory() as root:
            arc = os.path.join(root, 'arc')
            out, log = os.path.join(root, 'o.json'), os.path.join(root, 'l.log')
            run_case.run_case(arc, case_tree(root), PROMPT, '/bin/true', out, log,
                              case_id='c0', launch=recording_launch(calls))
            self.assertEqual(calls[0]['workspaceAtLaunch'],
                             ['introducing.diff', 'reviewer-prompt.txt'])
            self.assertEqual(calls[0]['findingsAtLaunch'], [])
            self.assertEqual(calls[0]['logPath'], log)

    def test_the_argv_is_a_one_off_launch_carrying_the_acknowledged_policy_version(self):
        argv = run_case.launcher_argv('/p/run-codex.sh', '/w/reviewer-prompt.txt', '/a/o.json',
                                      '/a/l.log', '/w')
        self.assertEqual(argv, ['/p/run-codex.sh', '--policy-version', run_case.POLICY_VERSION,
                                '--one-off', '/w/reviewer-prompt.txt', '/a/o.json', '/a/l.log',
                                '/w'])
        # Codex arguments follow the four positionals, which is why `run_case` passes the log path
        # to the launch rather than reading it off the end of argv.
        with_args = run_case.launcher_argv('/p/run-codex.sh', '/w/p.txt', '/a/o', '/a/l', '/w',
                                           ('-p', 'sol'))
        self.assertEqual(with_args[-3:], ['/w', '-p', 'sol'])

    def test_the_acknowledged_policy_version_equals_the_launchers_own(self):
        # A HANDSHAKE, not a label: `run-codex.sh` refuses a launch whose acknowledged version is
        # not its own. The constant here is a COPY of the launcher's default, and this is the twin
        # comparison that stops the two drifting — both files are in this one repository, so the
        # comparison is a real test rather than a note saying someone should check.
        with open(os.path.join(HERE, 'run-codex.sh'), encoding='utf-8') as fh:
            launcher = fh.read()
        declared = re.findall(r'^POLICY_VERSION="([^"]+)"', launcher, re.MULTILINE)
        self.assertEqual(len(declared), 1, f'expected one POLICY_VERSION= line, got {declared}')
        self.assertEqual(run_case.POLICY_VERSION, declared[0])

    def test_the_module_names_exactly_one_launcher_entry_point(self):
        # P11a, the guard plan round 1 moved here (§10.2): decision 14 says the grading tool is
        # built for codex-converge's reviewer only, so a second launcher named here IS the
        # pluggable reviewer interface that decision declines.
        named = launcher_literals_in(os.path.join(HERE, 'run_case.py'))
        self.assertEqual(named, ['run-codex.sh'])

    def test_CONTROL_a_second_launcher_entry_point_reddens(self):
        # Without this the assertion above also passes for a scanner that finds nothing at all.
        with open(os.path.join(HERE, 'run_case.py'), encoding='utf-8') as fh:
            source = fh.read()
        mutated = source.replace("LAUNCHER = os.path.join(HERE, 'run-codex.sh')",
                                 "LAUNCHER = os.path.join(HERE, 'run-codex.sh')\n"
                                 "FALLBACK = os.path.join(HERE, 'run-other-reviewer.sh')")
        self.assertNotEqual(mutated, source)
        with tempfile.TemporaryDirectory() as root:
            copy = write(os.path.join(root, 'run_case.py'), mutated)
            self.assertEqual(launcher_literals_in(copy),
                             ['run-codex.sh', 'run-other-reviewer.sh'])


class MeasuredCost(unittest.TestCase):
    def test_reads_the_token_count_the_launchers_log_reports(self):
        self.assertEqual(run_case.measured_tokens_from_log('tokens used\n143,636\n'), 143_636)
        self.assertEqual(run_case.measured_tokens_from_log('noise\ntokens used\n38,188\nmore\n'),
                         38_188)
        self.assertEqual(run_case.measured_tokens_from_log('tokens used\n907\n'), 907)

    def test_the_last_reported_count_wins(self):
        # A retried launch appends a second usage line; the run's cost is the last one.
        self.assertEqual(
            run_case.measured_tokens_from_log('tokens used\n1,000\nx\ntokens used\n2,500\n'),
            2_500)

    def test_an_unmeasured_run_reports_None_and_never_zero(self):
        for text in ('', 'no usage here', 'tokens used\nnot a number\n', None):
            self.assertIsNone(run_case.measured_tokens_from_log(text), repr(text))

    def test_a_completed_run_records_its_measured_cost(self):
        with tempfile.TemporaryDirectory() as root:
            arc = os.path.join(root, 'arc')
            out, log = os.path.join(root, 'o.json'), os.path.join(root, 'l.log')
            result = run_case.run_case(arc, case_tree(root), PROMPT, '/bin/true', out, log,
                                       case_id='c0', launch=recording_launch([]))
            self.assertEqual(result['measuredTokens'], 42_000)
            self.assertGreaterEqual(result['wallClockSeconds'], 0.0)
            self.assertEqual(result['returncode'], 0)

    def test_a_run_whose_log_reports_nothing_records_an_unmeasured_cost(self):
        with tempfile.TemporaryDirectory() as root:
            arc = os.path.join(root, 'arc')
            out, log = os.path.join(root, 'o.json'), os.path.join(root, 'l.log')
            result = run_case.run_case(arc, case_tree(root), PROMPT, '/bin/true', out, log,
                                       case_id='c0',
                                       launch=recording_launch([], rc=1, log='it died'))
            self.assertIsNone(result['measuredTokens'])
            self.assertEqual(result['returncode'], 1)


def launcher_literals_in(path: str) -> list[str]:
    """Every launcher script this module NAMES, as string literals and never as prose.

    An AST walk and not a grep: a docstring explaining which launcher is used is a MENTION, and
    `[[a-mention-is-not-a-property]]` — the property is which executable the code can actually
    invoke. Docstrings are string constants too, so they are excluded by position rather than by
    guessing from their content.
    """
    with open(path, encoding='utf-8') as fh:
        tree = ast.parse(fh.read())
    docstrings = set()
    for node in ast.walk(tree):
        body = getattr(node, 'body', None)
        if isinstance(body, list) and body and isinstance(body[0], ast.Expr) \
                and isinstance(body[0].value, ast.Constant) and isinstance(body[0].value.value, str):
            docstrings.add(id(body[0].value))
    found = set()
    for node in ast.walk(tree):
        if isinstance(node, ast.Constant) and isinstance(node.value, str) \
                and id(node) not in docstrings and re.fullmatch(r'run-[A-Za-z0-9._-]+\.sh',
                                                                node.value):
            found.add(node.value)
    return sorted(found)


def partition_tree(root: str, members) -> str:
    """A case tree with named members in named partitions: `(partition_dir, case_id, kind)`."""
    for directory, case_id, kind in members:
        case_dir = os.path.join(root, directory, case_id)
        os.makedirs(case_dir, exist_ok=True)
        write(os.path.join(case_dir, 'case.json'),
              '{"caseId": "%s", "kind": "%s", "defectLocations": []}' % (case_id, kind))
        write(os.path.join(case_dir, 'introducing.diff'), DIFF)
    return root


class CasePartitions(unittest.TestCase):
    """`case_ids_in` / `scorable_case_dirs` — which cases a grading run may score.

    The property is that the scorable set is the scorable partition and nothing else, and it is
    asserted in BOTH directions, because "the design-stage cases were not scored" is also what a
    runner that scored nothing at all would report.
    """

    MEMBERS = (
        ('cases', 'a-1', 'escape'),
        ('cases', 'a-2', 'escape'),
        ('clean', 'c-1', 'clean'),
        ('design-stage', 'd-1', 'design-stage'),
        ('design-stage', 'd-2', 'design-stage'),
    )

    def test_each_partition_reads_back_exactly_its_own_members(self):
        with tempfile.TemporaryDirectory() as root:
            partition_tree(root, self.MEMBERS)
            self.assertEqual(run_case.case_ids_in(root, run_case.SCORABLE), ('a-1', 'a-2'))
            self.assertEqual(run_case.case_ids_in(root, run_case.CLEAN), ('c-1',))
            self.assertEqual(run_case.case_ids_in(root, run_case.DESIGN_STAGE), ('d-1', 'd-2'))

    def test_the_scorable_set_and_the_design_stage_set_are_disjoint_both_ways(self):
        with tempfile.TemporaryDirectory() as root:
            partition_tree(root, self.MEMBERS)
            scorable = set(run_case.case_ids_in(root, run_case.SCORABLE))
            design = set(run_case.case_ids_in(root, run_case.DESIGN_STAGE))
            self.assertEqual(scorable & design, set())
            # Both directions, and both non-empty: an empty scorable set satisfies "no
            # design-stage case was scored" while grading the reviewer as having caught nothing.
            self.assertTrue(scorable and design)
            self.assertEqual(sorted(scorable | design), ['a-1', 'a-2', 'd-1', 'd-2'])

    def test_a_case_misfiled_into_the_scorable_partition_is_REFUSED_BY_NAME(self):
        """The one reading a directory glob cannot reach. A design-stage case moved into the
        scorable partition is indistinguishable, downstream, from an escape case with no defect
        locations — and that is the raise the design keeps deliberately unreachable."""
        with tempfile.TemporaryDirectory() as root:
            partition_tree(root, self.MEMBERS + (('cases', 'moved-1', 'design-stage'),))
            with self.assertRaises(ValueError) as caught:
                run_case.case_ids_in(root, run_case.SCORABLE)
            self.assertIn('moved-1', str(caught.exception))
            self.assertIn('design-stage', str(caught.exception))

    def test_a_missing_partition_RAISES_rather_than_reading_as_an_empty_set(self):
        with tempfile.TemporaryDirectory() as root:
            partition_tree(root, (('clean', 'c-1', 'clean'),))
            with self.assertRaises(FileNotFoundError) as caught:
                run_case.case_ids_in(root, run_case.SCORABLE)
            self.assertIn('caught nothing', str(caught.exception))

    def test_a_directory_with_no_case_record_is_not_a_case(self):
        with tempfile.TemporaryDirectory() as root:
            partition_tree(root, self.MEMBERS)
            os.makedirs(os.path.join(root, 'cases', '.notes'), exist_ok=True)
            write(os.path.join(root, 'cases', 'README.md'), 'not a case\n')
            self.assertEqual(run_case.case_ids_in(root, run_case.SCORABLE), ('a-1', 'a-2'))

    def test_scorable_case_dirs_are_the_scorable_ids_as_directories_in_id_order(self):
        with tempfile.TemporaryDirectory() as root:
            partition_tree(root, self.MEMBERS)
            self.assertEqual(
                run_case.scorable_case_dirs(root),
                (os.path.join(root, 'cases', 'a-1'), os.path.join(root, 'cases', 'a-2')))

    def test_the_three_partitions_name_three_distinct_directories_and_three_distinct_kinds(self):
        self.assertEqual(len({d for d, _ in run_case.PARTITIONS}), 3)
        self.assertEqual(len({k for _, k in run_case.PARTITIONS}), 3)


def full_case(root: str, case_id: str = 'a-1', *, kind: str = 'escape',
              locations=({'file': 'one.ts', 'lineStart': 5, 'lineEnd': 7},),
              introducing=({'prNumber': 1, 'landingSha': 'abc', 'mergeShape': 'squash'},),
              diff: str = '--- a/one.ts\n+++ b/one.ts\n@@ -5,1 +5,1 @@\n-a\n+b\n') -> str:
    import json as _json
    case_dir = os.path.join(root, case_id)
    os.makedirs(case_dir, exist_ok=True)
    write(os.path.join(case_dir, 'introducing.diff'), diff)
    write(os.path.join(case_dir, 'case.json'), _json.dumps({
        'caseId': case_id, 'kind': kind, 'introducing': list(introducing),
        'defectLocations': list(locations), 'measuredTokens': 99}))
    return case_dir


class DiffFileManifest(unittest.TestCase):
    def test_it_reads_the_post_image_side_in_first_appearance_order(self):
        text = ('--- a/b.ts\n+++ b/b.ts\n@@ -1,1 +1,1 @@\n'
                '--- a/a.ts\n+++ b/a.ts\n@@ -1,1 +1,1 @@\n'
                '--- a/b.ts\n+++ b/b.ts\n@@ -9,1 +9,1 @@\n')
        self.assertEqual(run_case.diff_files(text), ('b.ts', 'a.ts'))

    def test_a_deletion_contributes_no_post_image_path(self):
        text = '--- a/gone.ts\n+++ /dev/null\n@@ -1,1 +0,0 @@\n'
        self.assertEqual(run_case.diff_files(text), ())

    def test_the_pre_image_side_is_NOT_the_manifest(self):
        """A rename shows the old path on the `---` side; the reviewer cites the new one, so
        reading the wrong side scores every finding on a renamed file as out-of-scope."""
        text = '--- a/old.ts\n+++ b/new.ts\n@@ -1,1 +1,1 @@\n'
        self.assertEqual(run_case.diff_files(text), ('new.ts',))


class LoadCase(unittest.TestCase):
    def test_it_reads_the_scorers_inputs_from_the_record_and_the_diff(self):
        with tempfile.TemporaryDirectory() as root:
            case = run_case.load_case(full_case(root))
            self.assertEqual(case.case_id, 'a-1')
            self.assertEqual(case.kind, 'escape')
            self.assertEqual(case.files, ('one.ts',))
            self.assertEqual(case.measured_tokens, 99)
            self.assertEqual([(d.file, d.start, d.end) for d in case.defects], [('one.ts', 5, 7)])

    def test_an_unparseable_defect_location_RAISES_and_is_not_dropped(self):
        """A dropped location scores a catch as a miss, which moves the grade for a data error."""
        with tempfile.TemporaryDirectory() as root:
            case_dir = full_case(root, locations=(
                {'file': 'one.ts', 'lineStart': 5, 'lineEnd': 7},
                {'file': 'one.ts', 'lineStart': 0, 'lineEnd': 7}))
            with self.assertRaises(ValueError) as caught:
                run_case.load_case(case_dir)
            self.assertIn('a-1', str(caught.exception))
            self.assertIn('entry 1', str(caught.exception))
            self.assertIn('scores a catch as a miss', str(caught.exception))

    def test_an_empty_defect_location_set_is_refused_BY_NAME_here_too(self):
        with tempfile.TemporaryDirectory() as root:
            with self.assertRaises(ValueError) as caught:
                run_case.load_case(full_case(root, locations=()))
            self.assertIn('a-1', str(caught.exception))
            self.assertIn('not an escape', str(caught.exception))

    def test_the_PRE_WIDENING_single_introducer_shape_is_refused(self):
        """One field, one reading. Accepting both shapes in production is how two readings of one
        field live on forever; the schema is the list."""
        with tempfile.TemporaryDirectory() as root:
            case_dir = full_case(root)
            path = os.path.join(case_dir, 'case.json')
            import json as _json
            record = _json.loads(open(path, encoding='utf-8').read())
            record['introducing'] = record['introducing'][0]
            write(path, _json.dumps(record))
            with self.assertRaises(ValueError) as caught:
                run_case.load_case(case_dir)
            self.assertIn('introducing', str(caught.exception))
            self.assertIn('LIST', str(caught.exception))

    def test_a_diff_with_no_post_image_header_is_refused_rather_than_scored(self):
        with tempfile.TemporaryDirectory() as root:
            with self.assertRaises(ValueError) as caught:
                run_case.load_case(full_case(root, diff='no headers here\n'))
            self.assertIn('a-1', str(caught.exception))
            self.assertIn('out-of-scope', str(caught.exception))

    def test_an_unreadable_record_names_the_case_and_the_path(self):
        with tempfile.TemporaryDirectory() as root:
            case_dir = full_case(root)
            write(os.path.join(case_dir, 'case.json'), 'NOT JSON {{')
            with self.assertRaises(ValueError) as caught:
                run_case.load_case(case_dir)
            self.assertIn('a-1', str(caught.exception))
            self.assertIn('case.json', str(caught.exception))



class CanonicalArcKey(unittest.TestCase):
    """The spend gate counts rows keyed on the arc, so the KEY decides whether a slot is spent.

    `abspath` normalises a relative prefix and leaves a symlink standing, so three launches
    reserved through a linked arc were invisible to a fourth call that spelled the arc by its real
    path, and the gate reserved a fourth. Every row in these tests is written through the real
    `launch_row`, so the key under test is the one production writes.
    """

    def test_the_fixture_really_exercises_the_difference(self):
        # The control. Without this row the symlink test below would pass just as well on a
        # platform where the two spellings were already equal, and would be measuring nothing.
        with tempfile.TemporaryDirectory() as root:
            real = os.path.join(root, 'arc')
            os.makedirs(real)
            link = os.path.join(root, 'linked-arc')
            os.symlink(real, link)
            self.assertNotEqual(os.path.abspath(link), os.path.abspath(real))
            self.assertEqual(run_case.loop.canonical_arc(link), run_case.loop.canonical_arc(real))

    def test_three_launches_through_a_symlinked_arc_refuse_a_fourth_through_the_real_path(self):
        calls: list = []
        with tempfile.TemporaryDirectory() as root:
            real = os.path.join(root, 'arc')
            os.makedirs(real)
            link = os.path.join(root, 'linked-arc')
            os.symlink(real, link)
            case_dir = case_tree(root)
            out, log = os.path.join(root, 'o.json'), os.path.join(root, 'l.log')
            for i in range(3):
                result = run_case.run_case(link, case_dir, PROMPT, '/bin/true', out, log,
                                           case_id=f'c{i}', launch=recording_launch(calls))
                self.assertTrue(result['launched'], result)
            fourth = run_case.run_case(real, case_dir, PROMPT, '/bin/true', out, log,
                                       case_id='c3', launch=recording_launch(calls))
            self.assertFalse(fourth['launched'], fourth)
            self.assertIn('3 of 3 approved case launches', fourth['reason'])
            self.assertEqual(len(calls), 3, 'the fourth reviewer must never have been launched')

    def test_a_relative_spelling_of_one_arc_counts_as_that_arc(self):
        with tempfile.TemporaryDirectory() as root:
            real = os.path.realpath(os.path.join(root, 'arc'))
            os.makedirs(real)
            rows = [run_case.launch_row(os.path.join(real, '.', ''), 'c0', 1, '/w', '/l', PROMPT,
                                        '/o', '/g')]
            self.assertEqual(len(run_case.launches_for_arc(rows, real)), 1)


class CompletionIsWrittenWithItsLaunch(unittest.TestCase):
    """A reservation says a slot was spent; the completion says what the spending bought.

    Before this they were one durable write and one returned dictionary, so a crash between the
    reviewer finishing and the caller saving that dictionary left a spent launch whose cost and
    artifacts nothing named.
    """

    def test_a_completed_launch_writes_one_completion_row_naming_its_artifacts(self):
        calls: list = []
        with tempfile.TemporaryDirectory() as root:
            arc = os.path.join(root, 'arc')
            case_dir = case_tree(root)
            out, log = os.path.join(root, 'o.json'), os.path.join(root, 'l.log')
            result = run_case.run_case(arc, case_dir, PROMPT, '/bin/true', out, log,
                                       case_id='c0', launch=recording_launch(calls))
            self.assertTrue(result['launched'], result)
            rows = run_case.completions_read(arc)
            self.assertEqual(len(rows), 1)
            row = rows[0]
            self.assertEqual(row['caseId'], 'c0')
            self.assertEqual(row['attempt'], 1)
            self.assertEqual(row['outPath'], os.path.abspath(out))
            self.assertEqual(row['logPath'], os.path.abspath(log))
            self.assertEqual(row['returncode'], result['returncode'])
            self.assertEqual(row['measuredTokens'], result['measuredTokens'])
            self.assertEqual(run_case.unreconciled_launches(arc), [])

    def test_an_interrupted_launch_still_records_what_its_slot_bought(self):
        calls: list = []
        with tempfile.TemporaryDirectory() as root:
            arc = os.path.join(root, 'arc')
            case_dir = case_tree(root)
            out, log = os.path.join(root, 'o.json'), os.path.join(root, 'l.log')
            with self.assertRaises(KeyboardInterrupt):
                run_case.run_case(arc, case_dir, PROMPT, '/bin/true', out, log, case_id='c0',
                                  launch=interrupted_launch(calls))
            rows = run_case.completions_read(arc)
            self.assertEqual(len(rows), 1)
            self.assertEqual(rows[0]['returncode'], -1)
            self.assertIsNone(rows[0]['measuredTokens'])
            self.assertEqual(run_case.unreconciled_launches(arc), [])

    def test_a_reservation_with_no_completion_is_the_one_thing_a_resume_must_look_at(self):
        # The positive control for `unreconciled_launches`: a reservation written WITHOUT going
        # through `run_case` is exactly the state a crash before the completion leaves behind.
        with tempfile.TemporaryDirectory() as root:
            arc = os.path.join(root, 'arc')
            verdict, _reason, row = run_case.reserve_launch_slot(arc, 'c9', '/w', '/l', PROMPT,
                                                                 '/o', '/g')
            self.assertEqual(verdict, 'append')
            left = run_case.unreconciled_launches(arc)
            self.assertEqual([r['caseId'] for r in left], ['c9'])
            self.assertEqual(left[0]['outPath'], os.path.abspath('/o'))

    def test_two_readings_of_one_completion_are_refused(self):
        with tempfile.TemporaryDirectory() as root:
            arc = os.path.join(root, 'arc')
            os.makedirs(arc)
            first = run_case.record_completion(arc, 'c0', 1, 0, 1.0, 100, '/o', '/g')
            self.assertEqual(first[0], 'append')
            same = run_case.record_completion(arc, 'c0', 1, 0, 1.0, 100, '/o', '/g')
            self.assertEqual(same[0], 'idempotent')
            differing = run_case.record_completion(arc, 'c0', 1, 0, 1.0, 999, '/o', '/g')
            self.assertEqual(differing[0], 'refuse')
            self.assertIn('measuredTokens', differing[1])


class TheWorkspaceIsReleasedOnEveryPath(unittest.TestCase):
    """The workspace holds the private introducing diff, and it had no release site at all.

    Every exit path is driven here, because the one a green run reaches is the only one the old
    code would have cleaned up had it cleaned up anything: a passing suite was structurally blind
    to this class.
    """

    def test_a_completed_run_leaves_no_workspace_behind(self):
        calls: list = []
        with tempfile.TemporaryDirectory() as root:
            arc = os.path.join(root, 'arc')
            out, log = os.path.join(root, 'o.json'), os.path.join(root, 'l.log')
            result = run_case.run_case(arc, case_tree(root), PROMPT, '/bin/true', out, log,
                                       case_id='c0', launch=recording_launch(calls))
            self.assertTrue(result['launched'], result)
            self.assertFalse(os.path.exists(result['workspace']), result['workspace'])

    def test_a_spend_gate_refusal_leaves_no_workspace_behind(self):
        calls: list = []
        with tempfile.TemporaryDirectory() as root:
            arc = os.path.join(root, 'arc')
            case_dir = case_tree(root)
            out, log = os.path.join(root, 'o.json'), os.path.join(root, 'l.log')
            for i in range(3):
                run_case.run_case(arc, case_dir, PROMPT, '/bin/true', out, log,
                                  case_id=f'c{i}', launch=recording_launch(calls))
            fourth = run_case.run_case(arc, case_dir, PROMPT, '/bin/true', out, log,
                                       case_id='c3', launch=recording_launch(calls))
            self.assertFalse(fourth['launched'])
            self.assertFalse(os.path.exists(fourth['workspace']), fourth['workspace'])

    def test_an_interrupted_launch_leaves_no_workspace_behind(self):
        calls: list = []
        seen: list = []
        with tempfile.TemporaryDirectory() as root:
            arc = os.path.join(root, 'arc')
            out, log = os.path.join(root, 'o.json'), os.path.join(root, 'l.log')

            def watching(argv, log_path):
                seen.append(argv[-2] if len(argv) >= 2 else None)
                return interrupted_launch(calls)(argv, log_path)

            with self.assertRaises(KeyboardInterrupt):
                run_case.run_case(arc, case_tree(root), PROMPT, '/bin/true', out, log,
                                  case_id='c0', launch=watching)
            self.assertEqual(len(seen), 1)
            self.assertTrue(seen[0])
            self.assertFalse(os.path.exists(seen[0]), seen[0])

if __name__ == '__main__':
    runner = unittest.TextTestRunner(verbosity=1)
    suite = unittest.defaultTestLoader.loadTestsFromModule(sys.modules['__main__'])
    if len(sys.argv) > 2 and sys.argv[1] == '-k':
        pattern = sys.argv[2]
        filtered = unittest.TestSuite(
            t for t in unittest.defaultTestLoader.loadTestsFromModule(sys.modules['__main__'])._tests
            for t in (t if isinstance(t, unittest.TestSuite) else [t])
            if pattern in t.id())
        suite = filtered
    result = runner.run(suite)
    total = result.testsRun
    failed = len(result.failures) + len(result.errors)
    print(f'\n Test Files  {"1 failed (1)" if failed else "1 passed (1)"}')
    print(f'      Tests  {f"{failed} failed | {total - failed} passed" if failed else f"{total} passed"} ({total})')
    sys.exit(1 if failed else 0)
