#!/usr/bin/env python3
"""tracks_meet_test.py — W1: the one place both repositories are present at once.

## LOCAL ONLY. This file is NOT a continuous-integration check in either repository.

That is a property of the design and not an oversight. Each repository's automation checks out
only itself, so four assertions this arc owes have no home in either one: they are about the
agreement BETWEEN a published, repository-agnostic reviewer and the private repository whose cases
it grades. Measured 2026-10-26: the skill's repository has no workflow directory at all, so
nothing here can be discovered by a pipeline, and the repository under review checks out no copy
of this skill.

Run it by hand, from a checkout of each:

    REVIEW_EVAL_PRODUCT_REPO=<path to the repository under review> \\
    REVIEW_EVAL_SKILL_REPO=<path to this skill's repository> \\
    python3 tracks_meet_test.py [-k PATTERN]

Both parameters are REQUIRED and neither has a default. A default pointing at either repository
would make this file pass against whatever happened to be on the machine that ran it, which is the
failure it exists to prevent one level up. A missing parameter exits non-zero rather than skipping:
a skipped integration test is a green tick over an unmeasured agreement.

## What it asserts, and why each row could not live anywhere else

1. **The runner scores the scorable partition and nothing else.** Asserted in BOTH directions over
   the repository's real case tree, with the partition sets derived from `git ls-files` — a reader
   independent of the one under test, which also proves the cases are tracked.
2. **A malformed scorable case makes the loader refuse, and the refusal names the case.** Over a
   COPY of the real tree, because a real scorer and a real case tree only exist together here.
3. **The widening is invisible to the score, on the real data.** The schema widened `introducing`
   to a list; the fourteen real cases each carry one introducer, and the score read through the
   list schema equals the pre-widening reading's, with each case's verdicts written out
   absolutely rather than as one expression compared to another.
4. **Depth agreement over every row of the ordered depth table**, using the repository's own
   generated declaration and its own deep-review list.

Plus the TWIN comparisons: values written once in each repository that no single repository's
tests can compare. There are five, and the fifth — the launcher's `POLICY_VERSION` against
`run_case.POLICY_VERSION` — is already a real test inside this repository, so four live here.
Each twin row carries the ABSOLUTE value as well as the equality, because two wrong answers that
agree are still agreement.
"""
from __future__ import annotations

import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import review_eval as re_  # noqa: E402
import run_case  # noqa: E402

PRODUCT_ENV = 'REVIEW_EVAL_PRODUCT_REPO'
SKILL_ENV = 'REVIEW_EVAL_SKILL_REPO'

#: The repository under review supplies its case tree and its generated declarations under this
#: one directory. The name is this design's own schema, shared by both repositories, and it is the
#: only path either side may assume about the other.
REVIEW_EVAL_DIR = '.review-eval'

#: The bound on every derived set below, written beside the derivation so a change is a deliberate
#: edit of this line rather than a silently different measurement. Counted 2026-10-26.
EXPECTED_SCORABLE = 14
EXPECTED_CLEAN = 10
EXPECTED_DESIGN_STAGE = 3

#: The repository under review declares these two numbers once. They are repeated here as the
#: twin's absolute anchor, and the scan below proves this skill's shipped modules carry neither,
#: so there is no second copy to drift.
DECLARED_WINDOW_TOKENS = 258_400
DECLARED_ENVELOPE_TOKENS = 12_000
DECLARED_BYTES_PER_TOKEN = 3.5

#: The depth table's own witnesses for the shallow half, from the design's §6.7.
SHALLOW_WITNESSES = ('README.md', 'AGENTS.md', '.github/pull_request_template.md')


def required_path(variable: str) -> str:
    value = os.environ.get(variable)
    if not value:
        raise SystemExit(
            f'{variable} is required and has no default. This is W1\'s local-only integration '
            f'test: it compares two repositories and must be told where both are.\n'
            f'  {PRODUCT_ENV}=<repository under review> {SKILL_ENV}=<this skill\'s repository> '
            f'python3 {os.path.basename(__file__)}')
    resolved = os.path.realpath(os.path.expanduser(value))
    if not os.path.isdir(resolved):
        raise SystemExit(f'{variable}={value!r} is not a directory (resolved to {resolved})')
    return resolved


PRODUCT_REPO = required_path(PRODUCT_ENV)
SKILL_REPO = required_path(SKILL_ENV)
REVIEW_EVAL_ROOT = os.path.join(PRODUCT_REPO, REVIEW_EVAL_DIR)
PRODUCT_SCRIPTS = os.path.join(PRODUCT_REPO, 'scripts', 'review-eval')


def node_json(imports: str, expression: str):
    """Evaluate an expression in the repository under review's own modules and return its JSON.

    The twins cannot be imported across the language boundary, so the comparison runs the other
    side's real code rather than a restatement of it. A restatement is the defect being tested.
    """
    script = (f'{imports}\nprocess.stdout.write(JSON.stringify({expression}))\n')
    done = subprocess.run(['node', '--input-type=module', '-e', script],
                          capture_output=True, text=True, cwd=PRODUCT_REPO)
    if done.returncode != 0:
        raise AssertionError(f'node failed ({done.returncode}): {done.stderr.strip()[:2000]}')
    return json.loads(done.stdout)


def product_module(name: str) -> str:
    return json.dumps(os.path.join(PRODUCT_SCRIPTS, name))


def git_case_ids(partition: str) -> tuple[str, ...]:
    """The case ids of one partition, read from the git index rather than from the filesystem.

    A reader independent of `run_case.case_ids_in`, and one that also answers a second question:
    an untracked case is not in the set, which is what decision 12's "cases live in this
    repository, tracked" means operationally.
    """
    prefix = f'{REVIEW_EVAL_DIR}/{partition}/'
    out = subprocess.run(['git', '-C', PRODUCT_REPO, 'ls-files', '-z', prefix + '*/case.json'],
                         capture_output=True, text=True, check=True).stdout
    ids = {entry[len(prefix):].split('/')[0] for entry in out.split('\0') if entry}
    return tuple(sorted(ids))


class Parameters(unittest.TestCase):
    def test_the_skill_parameter_resolves_to_the_tree_this_file_runs_from(self):
        """Otherwise the required parameter is decoration: it would be possible to point this run
        at one checkout while importing the modules of another, and every twin row below would
        compare the wrong pair."""
        self.assertEqual(os.path.realpath(os.path.commonpath([SKILL_REPO, HERE])), SKILL_REPO)

    def test_the_product_parameter_points_at_a_tree_carrying_the_case_directory(self):
        self.assertTrue(os.path.isdir(REVIEW_EVAL_ROOT), REVIEW_EVAL_ROOT)
        self.assertTrue(os.path.isdir(PRODUCT_SCRIPTS), PRODUCT_SCRIPTS)

    def test_this_file_is_not_wired_into_any_pipeline_in_either_repository(self):
        """The header claims it; this measures it, because a claim in a docstring is not a fact
        about a tree somebody may have added a workflow to since."""
        for repo in (SKILL_REPO, PRODUCT_REPO):
            hits = subprocess.run(['git', '-C', repo, 'grep', '-l', os.path.basename(__file__)],
                                  capture_output=True, text=True).stdout.split()
            self.assertEqual([h for h in hits if '.github/' in h or 'workflow' in h], [],
                             f'{repo} references this file from its automation')


class ScorableSelection(unittest.TestCase):
    """Acceptance 1: the runner scores `cases/` and nothing else."""

    def test_each_partition_matches_the_git_index_exactly(self):
        for partition, expected_count in ((run_case.SCORABLE, EXPECTED_SCORABLE),
                                          (run_case.CLEAN, EXPECTED_CLEAN),
                                          (run_case.DESIGN_STAGE, EXPECTED_DESIGN_STAGE)):
            directory = partition[0]
            from_runner = run_case.case_ids_in(REVIEW_EVAL_ROOT, partition)
            from_git = git_case_ids(directory)
            self.assertEqual(from_runner, from_git, directory)
            self.assertEqual(len(from_runner), expected_count,
                             f'{directory} holds {len(from_runner)} cases, and the bound written '
                             f'in this file is {expected_count}; a new case is a deliberate edit')

    def test_the_scored_set_is_the_scorable_partition_in_BOTH_directions(self):
        scorable = set(run_case.case_ids_in(REVIEW_EVAL_ROOT, run_case.SCORABLE))
        design = set(run_case.case_ids_in(REVIEW_EVAL_ROOT, run_case.DESIGN_STAGE))
        clean = set(run_case.case_ids_in(REVIEW_EVAL_ROOT, run_case.CLEAN))

        # Forward: no design-stage or clean case is scored as an escape.
        self.assertEqual(scorable & design, set())
        self.assertEqual(scorable & clean, set())
        # Backward, and this is the direction that matters: every member of the scorable partition
        # IS scored. "No design-stage case was scored" is also true of a runner that scored none.
        self.assertEqual(scorable, set(git_case_ids(run_case.SCORABLE[0])))
        self.assertTrue(scorable and design and clean)

    def test_every_scorable_case_loads_and_declares_the_escape_kind(self):
        for case_dir in run_case.scorable_case_dirs(REVIEW_EVAL_ROOT):
            case = run_case.load_case(case_dir)
            self.assertEqual(case.kind, 'escape', case.case_id)
            self.assertTrue(case.defects, case.case_id)
            self.assertTrue(case.files, case.case_id)

    def test_the_empty_defect_raise_is_UNREACHABLE_from_the_real_scorable_set(self):
        """The scorer's raise on an empty defect set is correct and stays. This asserts nothing
        routes a case into it, which is the invariant the product side's own negative control
        could not reach."""
        for case_dir in run_case.scorable_case_dirs(REVIEW_EVAL_ROOT):
            case = run_case.load_case(case_dir)
            re_.score_escape_case(case.case_id, [], case.defects, case.files)


class MalformedCaseRefusal(unittest.TestCase):
    """Acceptance 2: a malformed SCORABLE case refuses, and the refusal names the case."""

    def test_an_unparseable_defect_location_in_a_real_case_refuses_by_name(self):
        victim = run_case.case_ids_in(REVIEW_EVAL_ROOT, run_case.SCORABLE)[0]
        with tempfile.TemporaryDirectory() as workspace:
            copy_root = os.path.join(workspace, REVIEW_EVAL_DIR)
            shutil.copytree(os.path.join(REVIEW_EVAL_ROOT, run_case.SCORABLE[0]),
                            os.path.join(copy_root, run_case.SCORABLE[0]))
            record_path = os.path.join(copy_root, run_case.SCORABLE[0], victim, 'case.json')
            with open(record_path, encoding='utf-8') as fh:
                record = json.load(fh)
            # Line 0 in a 1-based numbering is the producer saying it did not know, which is
            # exactly the shape a half-finished harvest writes.
            record['defectLocations'][0] = dict(record['defectLocations'][0], lineStart=0)
            with open(record_path, 'w', encoding='utf-8') as fh:
                json.dump(record, fh)

            with self.assertRaises(ValueError) as caught:
                run_case.load_case(os.path.join(copy_root, run_case.SCORABLE[0], victim))
            self.assertIn(victim, str(caught.exception))
            self.assertIn('entry 0', str(caught.exception))
            # Positive control: the untouched sibling in the same copied tree still loads, so the
            # refusal is about the case that was corrupted and not about the copy.
            survivor = run_case.case_ids_in(REVIEW_EVAL_ROOT, run_case.SCORABLE)[1]
            run_case.load_case(os.path.join(copy_root, run_case.SCORABLE[0], survivor))

    def test_the_real_tree_is_untouched_by_that_corruption(self):
        """The corruption above runs on a copy. Asserted rather than assumed, in the same file,
        because a mutation that escaped into the tracked tree would be committed by a sibling."""
        done = subprocess.run(['git', '-C', PRODUCT_REPO, 'status', '--porcelain',
                               f'{REVIEW_EVAL_DIR}/{run_case.SCORABLE[0]}'],
                              capture_output=True, text=True, check=True)
        self.assertEqual(done.stdout.strip(), '')


class WideningIsInvisibleToTheScore(unittest.TestCase):
    """Acceptance 3: the list-shaped schema and the pre-widening reading score identically.

    The synthetic half of this property is pinned in this repository already. What only exists
    here is the real data: fourteen harvested cases, each with one introducer, where the schema
    says `introducing` is a list.

    The absolute anchor is per case: a finding placed exactly on the first defect location is a
    CATCH, a finding far away in the same file is a MISS, and a finding naming a file the diff
    does not carry is OUT-OF-SCOPE. A loader that dropped a location, read the wrong side of the
    diff headers, or returned a smaller file manifest moves one of those three.
    """

    @staticmethod
    def findings_for(case):
        first = case.defects[0]
        return [
            {'file': first.file, 'line_start': first.start, 'line_end': first.end},
            {'file': first.file, 'line_start': first.end + 10_000, 'line_end': first.end + 10_001},
            {'file': 'no/such/file.xyz', 'line_start': 1, 'line_end': 1},
        ]

    @staticmethod
    def pre_widening_inputs(case_dir):
        """The reading a pre-widening loader would have produced: `introducing` as ONE mapping.

        Written here rather than kept in production, where one field may have one reading. The
        record is rewritten into its old shape on a copy and read by this old-shaped reader, so
        the two sides are genuinely two code paths over the same bytes.
        """
        with open(os.path.join(case_dir, 'case.json'), encoding='utf-8') as fh:
            record = json.load(fh)
        introducing = record['introducing']
        assert isinstance(introducing, list) and len(introducing) == 1, introducing
        single = introducing[0]
        assert isinstance(single, dict) and 'landingSha' in single, single
        defects = [re_.parse_defect_location(raw) for raw in record['defectLocations']]
        assert all(d is not None for d in defects)
        with open(os.path.join(case_dir, 'introducing.diff'), encoding='utf-8') as fh:
            files = run_case.diff_files(fh.read())
        return tuple(defects), files

    def test_all_fourteen_real_cases_carry_exactly_one_introducer(self):
        counts = []
        for case_dir in run_case.scorable_case_dirs(REVIEW_EVAL_ROOT):
            with open(os.path.join(case_dir, 'case.json'), encoding='utf-8') as fh:
                counts.append(len(json.load(fh)['introducing']))
        self.assertEqual(counts, [1] * EXPECTED_SCORABLE)

    def test_the_two_readings_score_identically_AND_to_the_written_down_verdicts(self):
        expected = (re_.CATCH, re_.MISS, re_.OUT_OF_SCOPE)
        caught_cases = 0
        for case_dir in run_case.scorable_case_dirs(REVIEW_EVAL_ROOT):
            case = run_case.load_case(case_dir)
            findings = self.findings_for(case)
            old_defects, old_files = self.pre_widening_inputs(case_dir)

            through_list = re_.score_escape_case(case.case_id, findings, case.defects, case.files)
            through_old = re_.score_escape_case(case.case_id, findings, old_defects, old_files)

            self.assertEqual(through_list, through_old, case.case_id)
            self.assertEqual(through_list.verdicts, expected, case.case_id)
            self.assertTrue(through_list.scorable, case.case_id)
            self.assertEqual(through_list.out_of_scope, 1, case.case_id)
            caught_cases += 1 if through_list.caught else 0
        self.assertEqual(caught_cases, EXPECTED_SCORABLE)


class DepthAgreement(unittest.TestCase):
    """Acceptance 4: one depth per changed-file set, from the repository's own declarations.

    This is where the glob-shaped `reviewOnly` entries meet a matcher, and W1 measured the answer
    before changing either side: `_path_matches` is the DEEP list's matcher and answers 1 of the 3
    shallow witnesses, so the shallow half has its own closed grammar in both repositories and
    `_path_matches` was left alone. The row that would have failed is `README.md`.
    """

    @classmethod
    def setUpClass(cls):
        with open(os.path.join(REVIEW_EVAL_ROOT, 'depth.json'), encoding='utf-8') as fh:
            cls.config = json.load(fh)
        with open(os.path.join(REVIEW_EVAL_ROOT, 'deep-review-list.json'), encoding='utf-8') as fh:
            cls.deep = tuple(json.load(fh))
        # Held in a one-element tuple: a plain function stored on a class is bound as a method
        # and would be handed `self` as its path.
        cls.shallow = (re_.shallow_path_predicate(cls.config['shallowPaths']),)
        # Derived, never restated: a witness UNDER the repository's own first deep entry.
        cls.deep_witness = f'{cls.deep[0]}/one.ts'

    def depth(self, files):
        return re_.depth_verdict(files, self.deep, self.shallow[0])[0]

    def test_every_row_of_the_ordered_table_answers_the_depth_it_declares(self):
        rows = (
            ('1: any file on the deep list', [self.deep_witness], re_.DEEP),
            ('1: deep wins over shallow', [SHALLOW_WITNESSES[0], self.deep_witness], re_.DEEP),
            ('2: every file shallow', list(SHALLOW_WITNESSES), re_.SINGLE_LENS),
            ('2: all, never any', [SHALLOW_WITNESSES[0], 'lib/one.ts'], re_.STANDARD),
            ('3: the empty list', [], re_.STANDARD),
            ('4: ordinary production', ['lib/one.ts'], re_.STANDARD),
            ('4: tests only keeps the panel', ['lib/one.test.ts'], re_.STANDARD),
            ('4: mixed docs and tests', [SHALLOW_WITNESSES[0], 'lib/one.test.ts'], re_.STANDARD),
        )
        self.assertEqual([(label, self.depth(files)) for label, files, _ in rows],
                         [(label, expected) for label, _, expected in rows])

    def test_the_three_shallow_witnesses_reach_the_single_lens_one_at_a_time(self):
        """Each on its own, because a list of three passes if any one of them carries the others.
        This is the assertion that reusing the deep matcher failed for two of the three."""
        self.assertEqual([self.depth([w]) for w in SHALLOW_WITNESSES],
                         [re_.SINGLE_LENS] * len(SHALLOW_WITNESSES))

    def test_the_declared_lens_mapping_names_a_panel_for_every_depth(self):
        mapping = self.config['lensMapping']
        self.assertEqual(sorted(mapping), sorted(re_.DEPTHS))
        self.assertEqual(mapping[re_.SINGLE_LENS], ['correctness'])
        self.assertEqual(mapping[re_.STANDARD], ['correctness', 'lifecycle', 'test-quality'])
        self.assertEqual(mapping[re_.DEEP][:3], mapping[re_.STANDARD])
        self.assertEqual(mapping[re_.DEEP][3], {'lens': 'money-security-migration',
                                                'tier': 'escalated'})

    def test_a_deep_entry_matches_only_at_a_directory_boundary_on_the_real_list(self):
        """The deep list's own matcher, over the repository's real entries rather than a fixture:
        a sibling directory sharing a name stem must not inherit the deepest review."""
        self.assertEqual(self.depth([f'{self.deep[0]}-sibling/one.ts']), re_.STANDARD)
        self.assertEqual(self.depth([self.deep_witness]), re_.DEEP)


class Twins(unittest.TestCase):
    """The values written once in each repository, compared with both checkouts present."""

    def shipped_modules(self):
        return [f for f in sorted(os.listdir(HERE))
                if f.endswith('.py') and not f.endswith('_test.py')]

    def test_twin_1_the_conservative_bytes_per_token_divisor_and_its_projection(self):
        product = node_json(
            f'import * as slice from {product_module("slice.mjs")}',
            '{ divisor: slice.CONSERVATIVE_BYTES_PER_TOKEN, '
            'projected: [0, 1, 7, 3500, 671509].map(slice.projectedTokens) }')

        self.assertEqual(product['divisor'], DECLARED_BYTES_PER_TOKEN)
        self.assertEqual(re_.CONSERVATIVE_BYTES_PER_TOKEN, DECLARED_BYTES_PER_TOKEN)
        # The constant agreeing is not the function agreeing: both round UP, and a projection that
        # rounded down would under-state in the direction that admits a case which will not fit.
        self.assertEqual(product['projected'],
                         [re_.project_tokens_from_bytes(n) for n in (0, 1, 7, 3500, 671509)])
        self.assertEqual(product['projected'], [0, 1, 2, 1000, 191860])

    def test_twin_2_and_3_the_effective_window_and_the_prompt_envelope(self):
        product = node_json(
            f'import * as harvest from {product_module("harvest.mjs")}',
            '{ nominal: harvest.NOMINAL_CONTEXT_WINDOW_TOKENS, '
            'percent: harvest.EFFECTIVE_CONTEXT_PERCENT, '
            'window: harvest.EFFECTIVE_WINDOW_TOKENS, '
            'envelope: harvest.PROMPT_ENVELOPE_TOKENS }')

        self.assertEqual(product['window'], DECLARED_WINDOW_TOKENS)
        self.assertEqual(product['envelope'], DECLARED_ENVELOPE_TOKENS)
        # The window is DERIVED there, so the twin pins the derivation and not only its result.
        self.assertEqual(product['nominal'] * product['percent'] // 100, product['window'])

        # This skill holds no second copy of either number: there is nothing here to drift. A
        # scan, because an absent copy is the kind of claim that quietly stops being true.
        for module in self.shipped_modules():
            with open(os.path.join(HERE, module), encoding='utf-8') as fh:
                text = fh.read()
            for literal in ('258400', '258_400', '12000', '12_000'):
                self.assertNotIn(literal, text, f'{module} carries {literal}')

    def test_twin_2_and_3_the_sweep_constants_in_this_repository_agree_with_the_declaration(self):
        """Those two numbers do appear in this repository's TESTS, which sweep the admission
        boundary against them. A sweep anchored to a different window from the one the repository
        under review declares sweeps the wrong boundary and says nothing."""
        with open(os.path.join(HERE, 'review_eval_test.py'), encoding='utf-8') as fh:
            text = fh.read()
        found = {name: int(value.replace('_', ''))
                 for name, value in re.findall(r'^(WINDOW_TOKENS|ENVELOPE_TOKENS) = ([0-9_]+)$',
                                               text, re.MULTILINE)}
        self.assertEqual(found, {'WINDOW_TOKENS': DECLARED_WINDOW_TOKENS,
                                 'ENVELOPE_TOKENS': DECLARED_ENVELOPE_TOKENS})

    def test_twin_4_the_admission_rule_including_its_boundary(self):
        window, envelope = DECLARED_WINDOW_TOKENS, DECLARED_ENVELOPE_TOKENS
        rows = (
            (0, 0, 1, True),
            (1, 0, 1, True),                                   # the `<=` boundary, exactly
            (2, 0, 1, False),
            (window - envelope, envelope, window, True),        # the boundary at the real numbers
            (window - envelope + 1, envelope, window, False),
            (178_003, envelope, window, True),                  # the largest real case
            (250_000, envelope, window, False),
        )
        product = node_json(
            f'import * as harvest from {product_module("harvest.mjs")}',
            '[' + ','.join(f'harvest.admitsCase({m},{e},{w}).admitted' for m, e, w, _ in rows)
            + ']')

        self.assertEqual(product, [expected for *_, expected in rows])
        self.assertEqual([re_.admits_case(m, e, w)[0] for m, e, w, _ in rows],
                         [expected for *_, expected in rows])

    def test_twin_5_the_shallow_path_predicate(self):
        """The twin W1 created. Both sides parse the SAME declaration, read from the repository
        under review, and the witness answers are written out."""
        witnesses = list(SHALLOW_WITNESSES) + [
            'docs/one.md', 'docs/one.txt', '.claude/memory/one.md',
            'README.txt', 'notes/deep/sub/one.md', '.github/workflows/one.yml', 'lib/one.ts',
        ]
        expected = [True, True, True, True, True, True, False, False, False, False]

        config_path = json.dumps(os.path.join(REVIEW_EVAL_ROOT, 'depth.json'))
        product = node_json(
            f'import * as gen from {product_module("gen-depth-config.mjs")}\n'
            f'import {{ readFileSync }} from "node:fs"\n'
            f'const config = JSON.parse(readFileSync({config_path}, "utf8"))',
            f'{json.dumps(witnesses)}.map(gen.shallowPathPredicate(config))')

        with open(os.path.join(REVIEW_EVAL_ROOT, 'depth.json'), encoding='utf-8') as fh:
            config = json.load(fh)
        skill = [re_.shallow_path_predicate(config['shallowPaths'])(w) for w in witnesses]

        self.assertEqual(product, expected)
        self.assertEqual(skill, expected)

    def test_twin_5_the_two_grammars_refuse_the_same_patterns(self):
        """A matcher that merely agrees on well-formed patterns can still disagree about what is
        well-formed, and the side that returns False instead of raising is the one that silently
        stops applying a rule."""
        bad = ['**/*.md', '*', '*md', 'doc*/one.md', '*.md*']
        product = node_json(
            f'import * as gen from {product_module("gen-depth-config.mjs")}',
            json.dumps(bad) + '.map((p) => { try { gen.matchesReviewOnlyPattern("README.md", p); '
            'return "no-raise" } catch { return "raise" } })')

        self.assertEqual(product, ['raise'] * len(bad))
        for pattern in bad:
            with self.assertRaises(ValueError, msg=pattern):
                re_.matches_shallow_pattern('README.md', pattern)

    def test_twin_5_has_a_positive_control_that_the_node_side_is_really_running(self):
        """Every row above would also pass if `node_json` silently returned the Python answer.
        This one asserts the other side is reached by asking it something only it can answer."""
        self.assertEqual(node_json('', '[typeof process.versions.node === "string", 2 + 2]'),
                         [True, 4])
        with self.assertRaises(AssertionError):
            node_json('', 'JSON.parse("{")')


if __name__ == '__main__':
    runner = unittest.TextTestRunner(verbosity=1)
    loader = unittest.defaultTestLoader
    suite = loader.loadTestsFromModule(sys.modules['__main__'])
    if len(sys.argv) > 2 and sys.argv[1] == '-k':
        pattern = sys.argv[2]
        suite = unittest.TestSuite(
            case for group in loader.loadTestsFromModule(sys.modules['__main__'])
            for case in (group if isinstance(group, unittest.TestSuite) else [group])
            if pattern in case.id())
    result = runner.run(suite)
    total = result.testsRun
    failed = len(result.failures) + len(result.errors)
    print(f'\n Test Files  {"1 failed (1)" if failed else "1 passed (1)"}')
    print(f'      Tests  '
          f'{f"{failed} failed | {total - failed} passed" if failed else f"{total} passed"} '
          f'({total})')
    sys.exit(1 if failed else 0)
