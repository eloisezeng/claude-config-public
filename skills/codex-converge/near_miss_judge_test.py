#!/usr/bin/env python3
"""near_miss_judge_test.py — pins §3.10's judge contract, both halves.

Run:  python3 near_miss_judge_test.py [-k PATTERN]
Prints a vitest-shaped `Test Files` / `Tests` summary so mutate.py's zero-match guard applies:
  mutate.py --src=near_miss_judge.py --test=near_miss_judge_test.py --copy-dir=<copy> \
            --mutants=<json> --test-cmd='python3 {test} {filter}' --filter-flag=-k

The failure-path rows and the SUCCESS rows are both here, and the reason is the whole design of
this file. Every failure path is required to leave the catch total unchanged, so a judge mapping
EVERY result — a valid `yes` included — to `unjudged` satisfies all of them and never promotes
anything. A suite of failure paths alone is therefore satisfied by a judge that does nothing.
"""
from __future__ import annotations

import os
import sys
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import near_miss_judge as nmj  # noqa: E402
import review_eval as re_  # noqa: E402

F = 'a/b.ts'
FILES = (F, 'a/other.ts')


def finding(start, end, file=F):
    return {'file': file, 'line_start': start, 'line_end': end}


def defect(start, end, file=F):
    return re_.LineRange(file=file, start=start, end=end)


#: A defect at 100-110 and a finding at 115-116 sit 4 lines apart, inside NEAR_MISS_GAP_LINES, so
#: the verdict is `near-miss` and the judge is the only thing that can promote it. Both numbers
#: are asserted below rather than assumed, because a fixture that silently stopped producing a
#: near miss would make every promotion row vacuous.
DEFECT = defect(100, 110)
NEAR = finding(115, 116)
HIT = finding(105, 106)
MISS = finding(400, 401)


def score(case_id, raw_findings):
    return re_.score_escape_case(case_id, raw_findings, [DEFECT], FILES)


def request(case_id='c1', index=0, **over):
    base = dict(
        case_id=case_id,
        finding_index=index,
        finding_title='the summary log prints before the pen path returns',
        finding_body='The call at 115 runs on every path, so the count is read early.',
        finding_range=defect(115, 116),
        location=DEFECT,
        finding_excerpt='  log.info(summary)\n',
        location_excerpt='  const pending = await pen(name)\n',
    )
    base.update(over)
    return nmj.JudgeRequest(**base)


class Fixture(unittest.TestCase):
    def test_the_fixture_really_produces_a_near_miss(self):
        # Without this the promotion rows below would pass against a scorer that produced no near
        # misses at all, which is the degenerate reading of every one of them.
        self.assertEqual(re_.NEAR_MISS_GAP_LINES, 10)
        self.assertEqual(score('c1', [NEAR]).verdicts, (re_.NEAR_MISS,))
        self.assertEqual(score('c1', [NEAR]).near_misses, (0,))
        self.assertFalse(score('c1', [NEAR]).caught)
        self.assertTrue(score('c1', [NEAR]).scorable)


class TheResultEnum(unittest.TestCase):
    def test_is_exactly_three_values(self):
        self.assertEqual(nmj.JUDGE_RESULTS, ('yes', 'no', 'unjudged'))
        self.assertEqual(
            nmj.JUDGE_RESULT_SCHEMA['properties']['result']['enum'], ['yes', 'no', 'unjudged'])
        self.assertEqual(nmj.JUDGE_RESULT_SCHEMA['required'], ['result'])

    def test_the_question_is_about_the_same_defect_and_not_about_relevance(self):
        # The wording is part of the contract: `relevant` and `near` both conform to a looser
        # question and produce a different catch total, so the words are pinned, not described.
        self.assertIn('SAME underlying defect', nmj.JUDGE_QUESTION)
        self.assertNotIn('relevant', nmj.JUDGE_QUESTION.lower())
        self.assertNotIn('near', nmj.JUDGE_QUESTION.lower())
        self.assertIn(nmj.JUDGE_QUESTION, nmj.build_judge_prompt(request()))

    def test_at_most_two_retries_after_the_first_attempt(self):
        self.assertEqual(nmj.MAX_RETRIES, 2)


class ThePromptIsRedacted(unittest.TestCase):
    def test_carries_only_the_six_declared_inputs(self):
        prompt = nmj.build_judge_prompt(request())
        for fragment in ('the summary log prints before the pen path returns',
                         'The call at 115 runs on every path',
                         'log.info(summary)', 'const pending = await pen(name)',
                         '115', '116', '100', '110', F):
            self.assertIn(fragment, prompt)

    def test_has_no_field_for_the_repair_diff_or_the_expected_answer(self):
        # Asserted on the BUILT prompt string, and also in the shape: `JudgeRequest` has no field
        # either could arrive through, so there is no call site that could pass one by accident.
        prompt = nmj.build_judge_prompt(request())
        # Named leak CONCEPTS rather than loose words. A bare `answer` would fire on the prompt's
        # own output instruction ("Answer with JSON"), which is not a leak, and a check that
        # reddens on a correct prompt gets loosened until it reddens on nothing.
        for leak in ('repair', 'expected answer', 'ground truth', 'correct answer',
                     'was caught', 'should be caught'):
            self.assertNotIn(leak, prompt.lower(), f'{leak!r} leaked into the judge prompt')
        self.assertEqual(
            set(nmj.JudgeRequest.__dataclass_fields__),
            {'case_id', 'finding_index', 'finding_title', 'finding_body', 'finding_range',
             'location', 'finding_excerpt', 'location_excerpt'})


class Parsing(unittest.TestCase):
    def test_accepts_a_declared_result_and_refuses_everything_else(self):
        self.assertEqual(nmj.parse_judge_result({'result': 'yes'}), 'yes')
        self.assertEqual(nmj.parse_judge_result('{"result": "no"}'), 'no')
        for bad in (None, {}, {'result': 'maybe'}, {'result': None}, {'verdict': 'yes'},
                    'not json', '{"result": true}', [{'result': 'yes'}], {'result': 'YES'}):
            self.assertIsNone(nmj.parse_judge_result(bad), f'{bad!r} parsed')

    def test_refuses_unjudged_from_the_model_itself(self):
        # `unjudged` is the harness's word for "the question was not answered". A model returning
        # it would let the model decline, which is a different fact from a failure and would be
        # recorded as the same one.
        self.assertIsNone(nmj.parse_judge_result({'result': 'unjudged'}))


class EveryFailurePathResolvesToUnjudged(unittest.TestCase):
    def _assert_unjudged(self, invoke, label):
        outcome = nmj.judge_near_miss(request(), invoke)
        self.assertEqual(outcome.result, 'unjudged', label)
        self.assertEqual(outcome.attempts, 1 + nmj.MAX_RETRIES, label)
        self.assertIsNotNone(outcome.failure, label)

    def test_timeout(self):
        def invoke(_prompt):
            raise TimeoutError('the launcher did not answer')
        self._assert_unjudged(invoke, 'timeout')

    def test_unparseable_output(self):
        self._assert_unjudged(lambda _p: 'I think it is the same bug, probably', 'unparseable')

    def test_missing_field(self):
        self._assert_unjudged(lambda _p: {'confidence': 0.9}, 'missing field')

    def test_value_outside_the_enum(self):
        self._assert_unjudged(lambda _p: {'result': 'same-ish'}, 'outside the enum')

    def test_launcher_failure(self):
        def invoke(_prompt):
            raise OSError('run-codex.sh exited 7')
        self._assert_unjudged(invoke, 'launcher failure')

    def test_retries_exhausted_and_no_more(self):
        calls = []

        def invoke(_prompt):
            calls.append(1)
            raise TimeoutError('again')
        nmj.judge_near_miss(request(), invoke)
        # At most TWO retries after the first attempt. A judge that retried forever would turn a
        # dead launcher into a hang rather than an `unjudged`.
        self.assertEqual(len(calls), 3)

    def test_the_catch_total_is_byte_identical_with_and_without_every_failure(self):
        # This identity is the assertion. "It did not crash" is not.
        scores = [score('c1', [NEAR]), score('c2', [HIT]), score('c3', [MISS])]
        clean = {'clean-1': 0}
        without = re_.build_run_summary(scores, clean, 'h')
        for invoke, label in (
            (_raiser(TimeoutError), 'timeout'),
            (lambda _p: 'garbage', 'unparseable'),
            (lambda _p: {'confidence': 1}, 'missing field'),
            (_raiser(OSError), 'launcher failure'),
        ):
            outcome = nmj.judge_near_miss(request(), invoke)
            judged = nmj.apply_judgements(scores, [outcome])
            with_failure = re_.build_run_summary(judged, clean, 'h')
            self.assertEqual(with_failure.catches, without.catches, label)
            self.assertEqual(with_failure.caught_case_ids, without.caught_case_ids, label)
            self.assertEqual(with_failure.scorable_case_ids, without.scorable_case_ids, label)


def _raiser(exc):
    def invoke(_prompt):
        raise exc('failed')
    return invoke


class TheSuccessHalf(unittest.TestCase):
    """Without these a judge mapping everything to `unjudged` satisfies the whole file."""

    def setUp(self):
        self.scores = [score('c1', [NEAR]), score('c2', [HIT]), score('c3', [MISS])]
        self.before = re_.build_run_summary(self.scores, {'clean-1': 0}, 'h')
        self.assertEqual(self.before.caught_case_ids, ('c2',))

    def test_a_yes_promotes_exactly_one_case_named_by_id(self):
        judged = nmj.apply_judgements(
            self.scores, [nmj.judge_near_miss(request('c1'), lambda _p: {'result': 'yes'})])
        after = re_.build_run_summary(judged, {'clean-1': 0}, 'h')
        self.assertEqual(sorted(after.caught_case_ids), ['c1', 'c2'])
        self.assertEqual(after.catches, self.before.catches + 1)
        # Named by id: c3 did not move, and nothing else did either.
        self.assertNotIn('c3', after.caught_case_ids)
        self.assertEqual(after.case_ids, self.before.case_ids)

    def test_a_second_yes_in_the_same_case_changes_nothing(self):
        # §3.1.1 is per CASE and not per finding, so two promoted findings in one case are one
        # catch. An implementation counting findings passes the row above and fails this one.
        two_near = score('c1', [NEAR, finding(112, 113)])
        self.assertEqual(two_near.near_misses, (0, 1))
        scores = [two_near, self.scores[1], self.scores[2]]
        yes = lambda _p: {'result': 'yes'}  # noqa: E731
        one = re_.build_run_summary(
            nmj.apply_judgements(scores, [nmj.judge_near_miss(request('c1', 0), yes)]), {}, 'h')
        both = re_.build_run_summary(nmj.apply_judgements(scores, [
            nmj.judge_near_miss(request('c1', 0), yes),
            nmj.judge_near_miss(request('c1', 1), yes),
        ]), {}, 'h')
        # The EXACT values, not merely that the two agree. A mutation battery caught the earlier
        # version of this row: a mutant that promoted nothing at all made both readings 1 and the
        # row passed, because two wrong answers that agree are still agreement.
        self.assertEqual(sorted(one.caught_case_ids), ['c1', 'c2'])
        self.assertEqual(one.catches, 2)
        self.assertEqual(sorted(both.caught_case_ids), ['c1', 'c2'])
        self.assertEqual(both.catches, 2)

    def test_a_no_leaves_the_total_alone_and_the_case_scorable(self):
        judged = nmj.apply_judgements(
            self.scores, [nmj.judge_near_miss(request('c1'), lambda _p: {'result': 'no'})])
        after = re_.build_run_summary(judged, {'clean-1': 0}, 'h')
        self.assertEqual(after.caught_case_ids, self.before.caught_case_ids)
        self.assertIn('c1', after.scorable_case_ids)

    def test_a_retry_then_a_yes_promotes(self):
        attempts = []

        def invoke(_prompt):
            attempts.append(1)
            if len(attempts) == 1:
                raise TimeoutError('first attempt')
            return {'result': 'yes'}
        outcome = nmj.judge_near_miss(request('c1'), invoke)
        self.assertEqual(outcome.result, 'yes')
        self.assertEqual(outcome.attempts, 2)
        after = re_.build_run_summary(
            nmj.apply_judgements(self.scores, [outcome]), {'clean-1': 0}, 'h')
        self.assertEqual(sorted(after.caught_case_ids), ['c1', 'c2'])


class TheJudgeMayOnlyBeAskedAboutANearMiss(unittest.TestCase):
    def setUp(self):
        self.scores = [score('c1', [NEAR]), score('c2', [HIT]), score('c3', [MISS])]

    def test_refuses_a_judgement_about_a_catch_or_a_miss(self):
        # §3.9: catch, miss, out-of-scope and malformed are decided mechanically and never
        # re-judged, so the grade does not drift when the judge changes. Refused at the boundary,
        # because a judgement silently ignored is one a caller believes was applied.
        yes = lambda _p: {'result': 'yes'}  # noqa: E731
        for case_id, index, word in (('c2', 0, 'catch'), ('c3', 0, 'miss')):
            with self.assertRaises(ValueError) as cm:
                nmj.apply_judgements(
                    self.scores, [nmj.judge_near_miss(request(case_id, index), yes)])
            self.assertIn(word, str(cm.exception))

    def test_refuses_a_judgement_about_an_unknown_case_or_finding(self):
        yes = lambda _p: {'result': 'yes'}  # noqa: E731
        with self.assertRaises(ValueError):
            nmj.apply_judgements(self.scores, [nmj.judge_near_miss(request('c9'), yes)])
        with self.assertRaises(ValueError):
            nmj.apply_judgements(self.scores, [nmj.judge_near_miss(request('c1', 7), yes)])


class Provenance(unittest.TestCase):
    def test_the_identity_travels_as_one_object_and_reaches_the_run_summary_row(self):
        identity = nmj.JudgeIdentity(model='gpt-5.6-sol', effort='high')
        self.assertEqual(identity.as_row(), {'model': 'gpt-5.6-sol', 'effort': 'high'})
        # Read back from the row loop.py persists, which is where a drift becomes attributable.
        import loop  # noqa: PLC0415
        row = loop.run_summary_row(
            'arc', 'run-1',
            re_.build_run_summary([score('c1', [NEAR])], {}, 'h'),
            identity.as_row())
        self.assertEqual(row['judge'], {'model': 'gpt-5.6-sol', 'effort': 'high'})

    def test_refuses_an_identity_missing_either_half(self):
        # A model identity with no effort does not identify the judge that ran.
        for model, effort in (('', 'high'), ('gpt-5.6-sol', ''), ('gpt-5.6-sol', None)):
            with self.assertRaises(ValueError):
                nmj.JudgeIdentity(model=model, effort=effort)


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
