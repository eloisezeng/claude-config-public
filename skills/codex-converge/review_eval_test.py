#!/usr/bin/env python3
"""review_eval_test.py — pins the catch rule, the keep rule, the depth rule and the publish guard.

Run:  python3 review_eval_test.py [-k PATTERN]
Prints a vitest-shaped `Test Files` / `Tests` summary at the end so mutate.py's zero-match guard
(`tests_ran`) applies to this file's own mutants:
  mutate.py --src review_eval.py --test review_eval_test.py --copy-dir <copy> --mutants <json> \
            --test-cmd 'python3 {test} {filter}' --filter-flag -k

Every rule here decides an outcome, so each is swept across both sides of its boundary rather
than pinned at one convenient point, and each degenerate input is asserted to produce its OWN
verdict rather than merely "not a catch".
"""
from __future__ import annotations

import itertools
import os
import random
import sys
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import review_eval as re_  # noqa: E402

F = 'a/b.ts'

#: The reviewed diff's file manifest for tests whose swept axis is the LINE range. `catch_verdict`
#: requires it (S1), and these tests fix it rather than default it, so the scope check is a
#: constant here and is swept on its own axis by the out-of-scope tests below.
FILES = (F, 'a/other.ts')


# Both helpers take the LINES positionally and the file by keyword, because the lines are what
# every test here sweeps and the file is what stays fixed. The first version had the file first
# and defaulted the lines, so `defect(100, 110)` silently passed 100 as the file name and the
# swept axis was pinned by the helper rather than by the test — the fixture's own default
# deciding the operand the test existed to vary.
def finding(start=10, end=20, file=F):
    return {'file': file, 'line_start': start, 'line_end': end}


def defect(start=10, end=20, file=F):
    loc = re_.parse_defect_location({'file': file, 'lineStart': start, 'lineEnd': end})
    assert loc is not None, 'the fixture itself must parse'
    return loc


class Boundary(unittest.TestCase):
    """The parsers are the only way in, so every refusal they make is a rule."""

    def test_a_well_formed_finding_parses(self):
        self.assertEqual(re_.parse_finding(finding()), re_.LineRange(F, 10, 20))

    def test_a_single_line_range_is_valid(self):
        self.assertEqual(re_.parse_finding(finding(start=7, end=7)), re_.LineRange(F, 7, 7))

    def test_each_malformed_shape_is_refused_for_its_own_reason(self):
        for raw, why in [
            (None, 'not a mapping at all'),
            ('a/b.ts:10', 'a string, not a mapping'),
            ([], 'a list'),
            ({'line_start': 1, 'line_end': 2}, 'no file'),
            ({'file': '', 'line_start': 1, 'line_end': 2}, 'an empty file name'),
            ({'file': 7, 'line_start': 1, 'line_end': 2}, 'a non-string file'),
            (finding(start=0), 'line 0, when numbering is 1-based'),
            (finding(start=-3), 'a negative line'),
            (finding(end=0), 'an end line of 0'),
            (finding(start=20, end=10), 'a reversed range'),
            ({'file': F, 'line_start': 1.5, 'line_end': 2}, 'a float line number'),
            ({'file': F, 'line_start': '1', 'line_end': '2'}, 'numeric strings'),
            ({'file': F, 'line_start': True, 'line_end': True}, 'booleans, which are ints in Python'),
            ({'file': F, 'line_start': None, 'line_end': 2}, 'a null line'),
            ({'file': F}, 'no lines at all'),
        ]:
            self.assertIsNone(re_.parse_finding(raw), f'must refuse {why}: {raw!r}')

    def test_the_two_parsers_read_their_own_field_names_and_not_each_others(self):
        """The reviewer writes line_start; the harvester writes lineStart. Mixing them silently
        would make every finding malformed or every defect unparseable, and both read as a grade."""
        self.assertIsNone(re_.parse_defect_location(finding()), 'the reviewer shape is not the case shape')
        self.assertIsNone(re_.parse_finding({'file': F, 'lineStart': 1, 'lineEnd': 2}),
                          'the case shape is not the reviewer shape')


class CatchRule(unittest.TestCase):
    def test_an_overlapping_finding_is_a_catch_and_names_the_location(self):
        v, m = re_.catch_verdict(finding(15, 25), [defect(10, 20)], FILES)
        self.assertEqual(v, re_.CATCH)
        self.assertEqual(m, defect(10, 20))

    def test_a_one_line_touch_at_each_end_still_overlaps(self):
        """Inclusive at BOTH ends. An exclusive comparison would drop exactly the findings that
        cite the first or last line of a hunk, which is where a reviewer most often points."""
        self.assertEqual(re_.catch_verdict(finding(20, 30), [defect(10, 20)], FILES)[0], re_.CATCH)
        self.assertEqual(re_.catch_verdict(finding(1, 10), [defect(10, 20)], FILES)[0], re_.CATCH)

    def test_containment_in_either_direction_is_a_catch(self):
        self.assertEqual(re_.catch_verdict(finding(12, 14), [defect(10, 20)], FILES)[0], re_.CATCH)
        self.assertEqual(re_.catch_verdict(finding(1, 99), [defect(10, 20)], FILES)[0], re_.CATCH)

    def test_the_near_miss_boundary_is_swept_on_both_sides(self):
        """A gap of exactly NEAR_MISS_GAP_LINES is still a near miss; one more line is a miss.
        Swept rather than pinned, so a changed constant cannot pass by matching one fixture."""
        gap = re_.NEAR_MISS_GAP_LINES
        d = [defect(100, 110)]
        for g in range(0, gap + 1):
            after = finding(110 + g + 1, 110 + g + 2)
            self.assertEqual(re_.catch_verdict(after, d, FILES)[0], re_.NEAR_MISS,
                             f'a gap of {g} line(s) after the defect is a near miss')
            before = finding(100 - g - 2, 100 - g - 1)
            self.assertEqual(re_.catch_verdict(before, d, FILES)[0], re_.NEAR_MISS,
                             f'a gap of {g} line(s) before the defect is a near miss')
        self.assertEqual(re_.catch_verdict(finding(110 + gap + 2, 110 + gap + 3), d, FILES)[0], re_.MISS,
                         'one line past the window is a miss, not a near miss')
        self.assertEqual(re_.catch_verdict(finding(100 - gap - 3, 100 - gap - 2), d, FILES)[0], re_.MISS,
                         'and symmetrically on the other side')

    def test_the_gap_is_measured_to_the_nearest_defect_when_several_are_in_one_file(self):
        d = [defect(100, 110), defect(200, 210)]
        v, m = re_.catch_verdict(finding(195, 198), d, FILES)
        self.assertEqual(v, re_.NEAR_MISS)
        self.assertEqual(m, defect(200, 210), 'the nearer defect, not the first in the list')

    def test_a_different_file_is_a_miss_however_close_the_lines(self):
        """Line numbers in two files are unrelated, so proximity across files is coincidence."""
        self.assertEqual(re_.catch_verdict(finding(10, 20, file='a/other.ts'), [defect(10, 20)], FILES)[0], re_.MISS)

    def test_a_file_outside_the_reviewed_diff_is_out_of_scope_and_not_a_miss(self):
        v, _ = re_.catch_verdict(finding(file='a/elsewhere.ts'), [defect()], diff_files=[F])
        self.assertEqual(v, re_.OUT_OF_SCOPE)

    def test_a_missing_file_manifest_RAISES_rather_than_scoring_a_miss(self):
        """This test's title and assertion are the inverse of what they were, and the inversion is
        the fix rather than a weakening. It used to read "without a file manifest the out-of-scope
        check is skipped" and assert MISS — it was pinning a fail-open: a caller who forgot the
        manifest got the reviewer marked down for citing a file it was never shown. The manifest is
        now a required parameter and `None` is refused, so the state that produced that `miss` is
        no longer reachable."""
        with self.assertRaises(ValueError) as cm:
            re_.catch_verdict(finding(file='a/elsewhere.ts'), [defect()], diff_files=None)
        self.assertIn('required', str(cm.exception))

    def test_a_malformed_finding_is_malformed_even_when_it_cites_a_defect_file(self):
        """Ordered before the scope check: nothing can be concluded from an unparseable finding."""
        v, _ = re_.catch_verdict({'file': F, 'line_start': 20, 'line_end': 10}, [defect()], diff_files=[F])
        self.assertEqual(v, re_.MALFORMED)

    def test_the_five_verdicts_are_all_reachable_and_all_distinct(self):
        """A rule whose values collapse onto each other cannot be read, so prove each is produced."""
        got = {
            re_.catch_verdict(finding(15, 16), [defect(10, 20)], [F])[0],
            re_.catch_verdict(finding(112, 113), [defect(100, 110)], [F])[0],
            re_.catch_verdict(finding(500, 501), [defect(10, 20)], [F])[0],
            re_.catch_verdict(finding(file='a/x.ts'), [defect()], [F])[0],
            re_.catch_verdict(None, [defect()], [F])[0],
        }
        self.assertEqual(got, set(re_.FINDING_VERDICTS))

    def test_property_a_finding_inside_a_defect_is_always_a_catch(self):
        rnd = random.Random(20261026)
        for _ in range(400):
            ds, de = sorted(rnd.sample(range(1, 2000), 2))
            fs = rnd.randint(ds, de)
            fe = rnd.randint(fs, de)
            self.assertEqual(re_.catch_verdict(finding(fs, fe), [defect(ds, de)], FILES)[0], re_.CATCH,
                             f'[{fs},{fe}] inside [{ds},{de}] must be a catch')

    def test_property_verdict_is_always_one_of_the_five_for_arbitrary_input(self):
        rnd = random.Random(7)
        pieces = [None, '', 0, -1, 1, 10, 10**9, 1.5, True, 'x', [], {}]
        for a, b in itertools.product(pieces, repeat=2):
            for file in (F, '', None, 'a/x.ts', 5):
                v, m = re_.catch_verdict({'file': file, 'line_start': a, 'line_end': b}, [defect()], [F])
                self.assertIn(v, re_.FINDING_VERDICTS)
                self.assertTrue(m is None or isinstance(m, re_.LineRange))
        for _ in range(200):
            v, _ = re_.catch_verdict(rnd.choice(pieces), [defect()], [F])
            self.assertIn(v, re_.FINDING_VERDICTS)

    def test_property_overlap_is_symmetric(self):
        rnd = random.Random(11)
        for _ in range(300):
            a1, a2 = sorted(rnd.sample(range(1, 500), 2))
            b1, b2 = sorted(rnd.sample(range(1, 500), 2))
            fwd = re_.catch_verdict(finding(a1, a2), [defect(b1, b2)], FILES)[0] == re_.CATCH
            rev = re_.catch_verdict(finding(b1, b2), [defect(a1, a2)], FILES)[0] == re_.CATCH
            self.assertEqual(fwd, rev, f'[{a1},{a2}] vs [{b1},{b2}] must agree in both directions')


class CaseScoring(unittest.TestCase):
    def test_a_case_is_caught_when_any_finding_overlaps(self):
        s = re_.score_escape_case('c1', [finding(500, 501), finding(15, 16)], [defect(10, 20)], [F])
        self.assertTrue(s.caught)
        self.assertEqual(s.verdicts, (re_.MISS, re_.CATCH))
        self.assertEqual(s.near_misses, ())

    def test_near_misses_are_reported_by_index_for_the_judge(self):
        s = re_.score_escape_case('c1', [finding(500, 501), finding(112, 113)], [defect(100, 110)], [F])
        self.assertFalse(s.caught)
        self.assertEqual(s.near_misses, (1,))

    def test_a_case_with_no_defect_location_raises_rather_than_scoring_zero(self):
        with self.assertRaises(ValueError) as cm:
            re_.score_escape_case('c-empty', [finding()], [], [F])
        msg = str(cm.exception)
        self.assertIn('c-empty', msg, 'the refusal must name the case or nobody can act on it')
        self.assertIn('not an escape', msg, 'and must say what an empty set actually means')

    def test_a_case_with_no_findings_at_all_is_an_honest_uncaught_case(self):
        s = re_.score_escape_case('c1', [], [defect()], [F])
        self.assertFalse(s.caught)
        self.assertEqual(s.verdicts, ())

    def test_false_alarms_count_only_the_two_harmful_outcomes(self):
        self.assertEqual(re_.false_alarms_on_clean_case(
            [re_.OUTCOME_REVIEWER_WRONG, re_.OUTCOME_NOT_REACHABLE]), 2)
        self.assertEqual(re_.false_alarms_on_clean_case(
            [re_.OUTCOME_INTENTIONAL, re_.OUTCOME_DIDNT_MATTER, re_.OUTCOME_DEFERRED, re_.OUTCOME_FIXED]), 0,
            'right about the code and wrong about importance is noise, not harm')
        self.assertEqual(re_.false_alarms_on_clean_case([]), 0)

    def test_every_outcome_in_the_closed_set_is_counted_one_way_or_the_other(self):
        """Sweeps the whole set, so adding a seventh outcome without classifying it reddens."""
        for o in re_.FINDING_OUTCOMES:
            n = re_.false_alarms_on_clean_case([o])
            self.assertIn(n, (0, 1))
            self.assertEqual(n, 1 if o in re_.FALSE_ALARM_OUTCOMES else 0, f'{o!r} is classified')

    def test_an_unrecognised_outcome_raises_rather_than_being_skipped(self):
        """Skipping would UNDER-count false alarms, which is the direction that approves a change
        the keep rule should reject."""
        with self.assertRaises(ValueError):
            re_.false_alarms_on_clean_case([re_.OUTCOME_FIXED, 'wontfix'])


class KeepRule(unittest.TestCase):
    #: Every field is passed by keyword and NONE is defaulted inside `RunSummary` itself, which is
    #: the point of S1: a construction site that forgets one fails at the compiler rather than
    #: silently skipping a gate. The defaults live HERE, in the fixture, where a test that sweeps a
    #: field overrides it — and the two set-valued fields are derived from `ids` rather than given
    #: their own default, because a fixture default on a swept axis pins the axis.
    def run_(self, catches=5, false_alarms=2, n_clean=10, ids=None,
             caught=None, scorable=None, clean_ids=None, manifest='manifest-h0',
             malformed=0, out_of_scope=0):
        ids = tuple(f'e{i}' for i in range(10)) if ids is None else tuple(ids)
        caught = ids[:catches] if caught is None else tuple(caught)
        scorable = ids if scorable is None else tuple(scorable)
        clean_ids = tuple(f'k{i}' for i in range(n_clean)) if clean_ids is None else tuple(clean_ids)
        return re_.RunSummary(
            false_alarms=false_alarms,
            case_ids=ids,
            caught_case_ids=caught,
            scorable_case_ids=scorable,
            clean_case_ids=clean_ids,
            case_manifest_hash=manifest,
            malformed_findings=malformed,
            out_of_scope_findings=out_of_scope,
        )

    def test_every_field_is_required_so_one_forgotten_site_fails_at_construction(self):
        """S1's whole shape. A defaulted `case_ids` skipped the like-with-like gate and a defaulted
        `diff_files` skipped the out-of-scope check, and both read green. A required field fails at
        EVERY call site at once, in one run, instead of on one production path later."""
        for missing in ('false_alarms', 'case_ids', 'caught_case_ids', 'scorable_case_ids',
                        'clean_case_ids', 'case_manifest_hash', 'malformed_findings',
                        'out_of_scope_findings'):
            kw = dict(
                false_alarms=0, case_ids=('e0',), caught_case_ids=(),
                scorable_case_ids=('e0',), clean_case_ids=('k0',), case_manifest_hash='h',
                malformed_findings=0, out_of_scope_findings=0,
            )
            del kw[missing]
            with self.assertRaises(TypeError, msg=f'{missing} must have no default'):
                re_.RunSummary(**kw)

    def test_catches_is_derived_from_the_caught_set_and_cannot_be_supplied(self):
        """A per-finding sum passed where a per-case count belongs is the defect this kills: the
        catch rule is binary per case (one case contributes at most 1), and an integer field
        accepts a finding-level total without complaint."""
        r = self.run_(catches=3)
        self.assertEqual(r.catches, 3)
        self.assertEqual(r.catches, len(r.caught_case_ids))
        with self.assertRaises(TypeError):
            re_.RunSummary(
                catches=99, false_alarms=0, case_ids=('e0',), caught_case_ids=(),
                scorable_case_ids=('e0',), clean_case_ids=('k0',), case_manifest_hash='h',
                malformed_findings=0, out_of_scope_findings=0,
            )

    def test_an_impossible_count_is_now_unconstructible_rather_than_refused(self):
        """This replaces `test_more_catches_than_cases_refuses_as_an_impossible_count`, and the
        replacement is deliberate rather than a weakening. That test pinned a GATE-time refusal of
        `catches > escape_cases`. Both counts are now derived from sets, with the caught set
        required to be a subset of the case set, so the state the gate refused can no longer be
        built — which is the stronger guarantee, because it fails at the producer instead of at the
        one consumer that happened to check."""
        with self.assertRaises(ValueError) as cm:
            re_.RunSummary(
                false_alarms=0, case_ids=('e0', 'e1'), caught_case_ids=('e0', 'e1', 'e2'),
                scorable_case_ids=('e0', 'e1'), clean_case_ids=('k0',), case_manifest_hash='h',
                malformed_findings=0, out_of_scope_findings=0,
            )
        self.assertIn('e2', str(cm.exception), 'the refusal names the id that is not a case')
        with self.assertRaises(ValueError):
            re_.RunSummary(
                false_alarms=0, case_ids=('e0',), caught_case_ids=(),
                scorable_case_ids=('e0', 'e9'), clean_case_ids=('k0',), case_manifest_hash='h',
                malformed_findings=0, out_of_scope_findings=0,
            )

    def test_a_different_scorable_subset_refuses_even_when_the_case_sets_match(self):
        """The reachable path: a reviewer returns well-formed findings that ALL cite files outside
        the supplied diff, so the case is unscorable and leaves the catch total. Two runs can then
        report identical case sets and different scorable subsets, and comparing their catch counts
        is not like with like."""
        ids = tuple(f'e{i}' for i in range(10))
        v, why = re_.keep_verdict(
            self.run_(ids=ids, scorable=ids),
            self.run_(ids=ids, scorable=ids[:9]),
        )
        self.assertEqual(v, re_.REFUSE)
        self.assertIn('only in baseline', why)
        self.assertIn('e9', why)

    def test_a_different_case_manifest_hash_refuses_and_quotes_both(self):
        """Two runs can name the same case IDs over cases whose CONTENT was corrected in place.
        The IDs are stable and the comparison is still meaningless."""
        v, why = re_.keep_verdict(self.run_(manifest='aaa111'), self.run_(manifest='bbb222'))
        self.assertEqual(v, re_.REFUSE)
        self.assertIn('aaa111', why)
        self.assertIn('bbb222', why)

    def test_an_empty_clean_case_set_refuses_on_either_side(self):
        """Carried over from the count-shaped version: a run with no clean case has a vacuously
        zero false-alarm count, and the noise half of the rule would pass unconditionally."""
        v, why = re_.keep_verdict(self.run_(n_clean=0), self.run_())
        self.assertEqual(v, re_.REFUSE)
        self.assertIn('vacuously zero', why)
        self.assertEqual(re_.keep_verdict(self.run_(), self.run_(n_clean=0))[0], re_.REFUSE)

    def test_a_run_that_scored_NOTHING_refuses_on_either_side(self):
        """Found by probing whether an empty scorable subset could reach the set comparison at all,
        and the answer exposed a hole the set comparison cannot close: two runs that each scored
        nothing have equal (empty) scorable subsets, so they compare as like with like and the rule
        returns KEEP on 0 catches against 0 catches. A reviewer change that broke scoring entirely
        would therefore have been KEPT. The refusal is per run, before any comparison."""
        ids = ('e0', 'e1')
        nothing = self.run_(ids=ids, catches=0, scorable=())
        self.assertEqual(re_.keep_verdict(nothing, self.run_())[0], re_.REFUSE)
        self.assertEqual(re_.keep_verdict(self.run_(), nothing)[0], re_.REFUSE)
        v, why = re_.keep_verdict(nothing, nothing)
        self.assertEqual(v, re_.REFUSE, 'both sides scoring nothing is the fail-open case')
        self.assertIn('vacuously zero', why)

    def test_a_different_clean_case_set_refuses_too(self):
        """The same defect as the scorable-subset one, one field over: equal clean COUNTS over
        different clean cases make the false-alarm halves incomparable. Found by applying the
        scorable-subset finding's own reasoning to the sibling field rather than by a second
        review round."""
        v, why = re_.keep_verdict(
            self.run_(clean_ids=('k0', 'k1')),
            self.run_(clean_ids=('k1', 'k2')),
        )
        self.assertEqual(v, re_.REFUSE)
        self.assertIn('clean', why)

    def test_no_baseline_refuses_and_never_keeps(self):
        v, why = re_.keep_verdict(None, self.run_())
        self.assertEqual(v, re_.REFUSE)
        self.assertIn('baseline', why)

    def test_equal_on_both_halves_is_kept_because_the_rule_is_do_not_get_worse(self):
        self.assertEqual(re_.keep_verdict(self.run_(), self.run_())[0], re_.KEEP)

    def test_more_catches_and_fewer_false_alarms_is_kept(self):
        self.assertEqual(
            re_.keep_verdict(self.run_(catches=5, false_alarms=3),
                             self.run_(catches=7, false_alarms=1))[0], re_.KEEP)

    def test_a_single_lost_catch_drops_the_change(self):
        v, why = re_.keep_verdict(self.run_(5), self.run_(4))
        self.assertEqual(v, re_.DROP)
        self.assertIn('catches fell from 5 to 4', why)

    def test_a_single_extra_false_alarm_drops_the_change_even_when_catches_rose(self):
        """Both halves are required. A change that finds one more real defect and two more
        phantom ones is not an improvement under this rule."""
        v, why = re_.keep_verdict(self.run_(catches=5, false_alarms=2),
                                  self.run_(catches=9, false_alarms=3))
        self.assertEqual(v, re_.DROP)
        self.assertIn('false alarms rose from 2 to 3', why)

    def test_an_empty_escape_case_set_refuses_on_either_side(self):
        self.assertEqual(re_.keep_verdict(self.run_(catches=0, ids=()), self.run_())[0], re_.REFUSE)
        self.assertEqual(re_.keep_verdict(self.run_(), self.run_(catches=0, ids=()))[0], re_.REFUSE)

    def test_a_negative_false_alarm_count_refuses(self):
        """`catches` can no longer be negative — it is the length of a tuple — so this sweeps the
        one count that is still an integer a caller supplies."""
        self.assertEqual(re_.keep_verdict(self.run_(), self.run_(false_alarms=-1))[0], re_.REFUSE)

    def test_different_case_sets_refuse_and_name_both_differences(self):
        v, why = re_.keep_verdict(self.run_(ids=('a', 'b')), self.run_(ids=('b', 'c')))
        self.assertEqual(v, re_.REFUSE)
        self.assertIn("only in baseline: ['a']", why)
        self.assertIn("only in candidate: ['c']", why)

    def test_the_same_case_set_in_a_different_order_still_compares(self):
        """Order is how the harness happened to iterate, not part of the identity of the set."""
        self.assertEqual(re_.keep_verdict(self.run_(ids=('a', 'b')), self.run_(ids=('a', 'b')))[0], re_.KEEP)

    def test_property_the_verdict_is_one_of_three_and_a_drop_always_names_a_worsened_half(self):
        rnd = random.Random(99)

        def rand_run():
            n = rnd.randint(0, 10)
            ids = tuple(f'e{i}' for i in range(n))
            # The caught and scorable sets are sampled from `ids` because the dataclass refuses a
            # non-subset outright; the fuzz sweeps what is still REACHABLE, which after S1 is a
            # strictly smaller state space than before. `false_alarms` keeps its negative range,
            # since it is the one count a caller still supplies as an integer.
            # Scorable is sampled first and caught is sampled FROM it, because S2 made an
            # unscorable catch unconstructible too: a catch needs a finding that parsed and cited
            # a file inside the diff, so it cannot come from a case whose every finding failed
            # one of those. Sampling the two independently would fuzz an impossible state and the
            # dataclass would raise, which is the producer refusal working rather than a finding.
            scorable = tuple(i for i in ids if rnd.random() < 0.8)
            return re_.RunSummary(
                false_alarms=rnd.randint(-1, 11),
                case_ids=ids,
                caught_case_ids=tuple(i for i in scorable if rnd.random() < 0.5),
                scorable_case_ids=scorable,
                clean_case_ids=tuple(f'k{i}' for i in range(rnd.randint(0, 10))),
                case_manifest_hash=rnd.choice(('h1', 'h2')),
                malformed_findings=rnd.randint(0, 5),
                out_of_scope_findings=rnd.randint(0, 5),
            )

        for _ in range(600):
            b = rand_run()
            c = rand_run()
            v, why = re_.keep_verdict(b, c)
            self.assertIn(v, re_.KEEP_VERDICTS)
            self.assertTrue(why, 'every verdict carries a reason')
            if v == re_.DROP:
                self.assertTrue(c.catches < b.catches or c.false_alarms > b.false_alarms,
                                'a drop is only ever one of the two stated halves')
            if v == re_.KEEP:
                self.assertGreaterEqual(c.catches, b.catches)
                self.assertLessEqual(c.false_alarms, b.false_alarms)


class DepthRule(unittest.TestCase):
    # `engine/core` is a fictional deep directory, not this pilot's own `src/core`: a
    # project directory name standing in as a fixture publishes the private tree's shape,
    # which is what `publishing_guard_test.py` scans every test module for.
    DEEP = ('money', 'engine/core', 'one.ts')

    @staticmethod
    def shallow(p):
        return p.startswith('notes/') and p.endswith('.md')

    def d(self, files):
        return re_.depth_verdict(files, self.DEEP, self.shallow)

    def test_a_deep_path_is_deep(self):
        self.assertEqual(self.d(['engine/core/x.ts'])[0], re_.DEEP)

    def test_a_whole_file_entry_matches_exactly(self):
        self.assertEqual(self.d(['one.ts'])[0], re_.DEEP)

    def test_a_prefix_matches_only_at_a_directory_boundary(self):
        """`src/core` must not match `src/corelib`. A substring rule would silently widen the
        deep-review list to every sibling directory sharing a name stem."""
        self.assertEqual(self.d(['src/corelib/x.ts'])[0], re_.STANDARD)
        self.assertEqual(self.d(['moneyish/x.ts'])[0], re_.STANDARD)
        self.assertEqual(self.d(['one.ts.bak'])[0], re_.STANDARD)

    def test_deep_wins_over_shallow_in_the_same_change(self):
        self.assertEqual(self.d(['notes/a.md', 'engine/core/x.ts'])[0], re_.DEEP)

    def test_single_lens_requires_every_file_to_be_shallow(self):
        self.assertEqual(self.d(['notes/a.md', 'notes/b.md'])[0], re_.SINGLE_LENS)
        self.assertEqual(self.d(['notes/a.md', 'lib/x.ts'])[0], re_.STANDARD,
                         'one code file among notes is still a code change')

    def test_a_tests_only_change_keeps_the_ordinary_depth(self):
        """The decision is explicit that tests-only keeps the full panel, so the shallow
        predicate must not be allowed to claim a test file."""
        self.assertEqual(self.d(['lib/x.test.ts'])[0], re_.STANDARD)

    def test_an_empty_change_is_standard_not_single_lens(self):
        v, why = self.d([])
        self.assertEqual(v, re_.STANDARD)
        self.assertIn('cannot be lowered', why)

    def test_an_empty_deep_list_still_answers(self):
        self.assertEqual(re_.depth_verdict(['engine/core/x.ts'], [], self.shallow)[0],
                         re_.STANDARD)

    def test_property_the_rule_is_TOTAL_over_every_combination_of_its_three_inputs(self):
        """Totality was a sentence in the spec; this is the sentence as an assertion.

        The rule has three independent binary inputs — does the change touch a deep path, is every
        file shallow, is the file list empty — and the spec's ordered table has four rows. A rule
        that answered `None`, or raised, or returned a word outside the enum for some corner is a
        rule the runner cannot dispatch on, and the corner would be found in production. So sweep
        the whole cross product rather than the four rows the table happens to name: 2^3 of the
        combinations are reachable and the unreachable ones are asserted unreachable here too,
        which is what stops a later edit from making one of them reachable and unanswered.
        """
        deep_f, shallow_f, code_f = 'engine/core/x.ts', 'notes/a.md', 'lib/x.ts'
        combos = []
        for has_deep in (False, True):
            for has_shallow in (False, True):
                for has_code in (False, True):
                    files = ([deep_f] if has_deep else []) \
                        + ([shallow_f] if has_shallow else []) \
                        + ([code_f] if has_code else [])
                    combos.append((has_deep, has_shallow, has_code, files))
        self.assertEqual(len(combos), 8, 'the cross product is swept, not sampled')
        for has_deep, has_shallow, has_code, files in combos:
            v, why = self.d(files)
            self.assertIn(v, re_.DEPTHS, f'{files!r} produced {v!r}, which no runner can dispatch')
            self.assertTrue(why, f'{files!r} produced a verdict with no reason')
            # And the verdict is the one the ordered table requires, so totality is not satisfied
            # by a rule that answers the same word for everything.
            if has_deep:
                expected = re_.DEEP
            elif has_shallow and not has_code:
                expected = re_.SINGLE_LENS
            else:
                expected = re_.STANDARD
            self.assertEqual(v, expected, f'{files!r}')
        # The empty list is the eighth combination and is STANDARD by the "I do not know" rule.
        self.assertEqual(self.d([])[0], re_.STANDARD)

    def test_property_adding_a_file_never_lowers_the_depth(self):
        """Monotonicity is the property that matters: a reviewer must not be able to reduce its
        own depth by touching one more file."""
        rnd = random.Random(5)
        pool = ['engine/core/a.ts', 'notes/a.md', 'lib/a.ts', 'money/a.ts', 'one.ts',
                'engine/corelib/a.ts']
        order = {d: i for i, d in enumerate(re_.DEPTHS)}
        for _ in range(400):
            files = rnd.sample(pool, rnd.randint(1, len(pool) - 1))
            extra = rnd.choice(pool)
            before = order[self.d(files)[0]]
            after = order[self.d(files + [extra])[0]]
            self.assertGreaterEqual(after, before, f'{files} + {extra} lowered the depth')


class PublishGuard(unittest.TestCase):
    def test_the_shipped_module_carries_no_project_literal(self):
        with open(os.path.join(HERE, 'review_eval.py')) as fh:
            src = fh.read()
        self.assertEqual(re_.assert_no_project_literals(src), [],
                         'this module is published to a public mirror; it may name no project')

    def test_the_guard_catches_each_shape_it_claims_to(self):
        """A positive control per shape. Without one, the test above passes for a guard that
        found nothing because its patterns match nothing."""
        # GUARD-CONTROL-BEGIN  These three strings must stay DIRTY. The guard's own scan
        # removes this region, which is a region a reader can SEE in the file rather than a file
        # name on an exemption list that could quietly cover a literal added elsewhere in it.
        controls = [
            ('see #123 for the repair', re_.PULL_REQUEST_NUMBER),
            ('read plugins/thing/file.ts', re_.PROJECT_SOURCE_PATH),
            ('under app/companies/x', re_.PROJECT_DIRECTORY_LITERAL),
        ]
        # GUARD-CONTROL-END
        for dirty, what in controls:
            hits = re_.assert_no_project_literals(dirty)
            self.assertTrue(hits, f'the guard must catch {what} in {dirty!r}')

    def test_the_guard_does_not_report_its_own_patterns(self):
        """Measured the hard way: a guard that scans its own source reports its own rule, and
        then nobody can tell a real hit from the pattern that defines one."""
        with open(os.path.join(HERE, 'review_eval.py')) as fh:
            src = fh.read()
        self.assertIn('# GUARD-PATTERNS-BEGIN', src, 'the excluded region must actually be marked')
        self.assertIn('# GUARD-PATTERNS-END', src)

    def test_a_clean_string_is_clean(self):
        self.assertEqual(re_.assert_no_project_literals('a pure function over line ranges'), [])



#: A file the reviewed diff does NOT contain. Named once so that every out-of-scope row below is
#: out of scope for the same reason, and so a later widening of `FILES` cannot silently turn these
#: rows into in-scope ones while they keep their titles.
OUTSIDE = 'z/elsewhere.ts'


class UnscorableCases(unittest.TestCase):
    """S2. `caught=False` used to mean two different things, and only one of them is a miss.

    A reviewer that read the diff and reported nothing MISSED the defect. A reviewer whose every
    finding was unparseable, or cited a file it was never shown, was never graded at all — the
    plumbing failed. Counting the second as a miss moves the grade for a reason that has nothing
    to do with reviewing, and it moves it DOWNWARD, which is the direction that drops a reviewer
    change that was actually fine.

    Every row asserts `scorable`, both per-verdict counts, and the case's membership in the run
    summary's scorable subset, because the field and the set are two readings of one fact and a
    test that checked only the field would pass for a summary that disagreed with it.
    """

    def score(self, raw_findings, case_id='c1'):
        return re_.score_escape_case(case_id, raw_findings, [defect(10, 20)], FILES)

    def in_scorable_subset(self, s):
        """The case's own answer, read back off a run summary built from it by the one producer."""
        r = re_.build_run_summary([s], {'k0': 0}, 'h')
        return s.case_id in r.scorable_case_ids

    def test_a_case_whose_every_finding_is_out_of_scope_is_not_scorable(self):
        """Row 1. Three WELL-FORMED findings, every one citing a file outside the diff. This is
        the reachable write path: a reviewer handed the wrong manifest, or a case whose slice
        dropped the file the reviewer was asked about."""
        s = self.score([finding(1, 2, file=OUTSIDE),
                        finding(3, 4, file=OUTSIDE),
                        finding(5, 6, file=OUTSIDE)])
        self.assertEqual(s.verdicts, (re_.OUT_OF_SCOPE,) * 3)
        self.assertFalse(s.scorable)
        self.assertEqual((s.malformed, s.out_of_scope), (0, 3))
        self.assertFalse(s.caught)
        self.assertFalse(self.in_scorable_subset(s))

    def test_a_case_mixing_the_two_unscorable_verdicts_is_still_not_scorable(self):
        """Row 2. Neither verdict carries information about aim, so a case made of both carries
        none either. An implementation keyed on `all malformed` alone passes row 1 and this row's
        sibling below while leaving THIS one an ordinary miss."""
        s = self.score([None, {'file': F}, finding(1, 2, file=OUTSIDE), finding(3, 4, file=OUTSIDE)])
        self.assertEqual(s.verdicts,
                         (re_.MALFORMED, re_.MALFORMED, re_.OUT_OF_SCOPE, re_.OUT_OF_SCOPE))
        self.assertFalse(s.scorable)
        self.assertEqual((s.malformed, s.out_of_scope), (2, 2))
        self.assertFalse(self.in_scorable_subset(s))

    def test_one_out_of_scope_finding_among_valid_ones_leaves_the_case_scorable(self):
        """Row 3. The case was graded; one finding simply told us nothing. Dropping the whole case
        here would throw away a real measurement, which is the over-correction this row pins."""
        s = self.score([finding(1, 2, file=OUTSIDE), finding(500, 501), finding(600, 601)])
        self.assertEqual(s.verdicts, (re_.OUT_OF_SCOPE, re_.MISS, re_.MISS))
        self.assertTrue(s.scorable)
        self.assertEqual((s.malformed, s.out_of_scope), (0, 1))
        self.assertTrue(self.in_scorable_subset(s))

    def test_the_rejected_remedy_one_malformed_finding_among_nineteen_valid_ones(self):
        """Row 4, and it is the REJECTED remedy pinned so nobody re-implements it: 'drop any case
        containing a malformed finding' is a rule that would discard a twenty-finding case, catch
        included, over one unparseable row."""
        raws = [None] + [finding(10 + i, 11 + i) for i in range(19)]
        s = self.score(raws)
        self.assertEqual(s.verdicts[0], re_.MALFORMED)
        self.assertEqual(len(s.verdicts), 20)
        self.assertTrue(s.scorable)
        self.assertTrue(s.caught, 'a catch among the valid nineteen still counts')
        self.assertEqual((s.malformed, s.out_of_scope), (1, 0))
        self.assertTrue(self.in_scorable_subset(s))

    def test_a_case_whose_every_finding_is_malformed_is_not_scorable(self):
        s = self.score([None, 'a/b.ts:10', {'file': F, 'line_start': 0, 'line_end': 2}])
        self.assertEqual(s.verdicts, (re_.MALFORMED,) * 3)
        self.assertFalse(s.scorable)
        self.assertEqual((s.malformed, s.out_of_scope), (3, 0))

    def test_a_case_with_NO_findings_is_scorable_because_silence_is_an_honest_miss(self):
        """The boundary the rule is written on. `any(informative)` and `not all(unscorable)`
        disagree on the empty list, and this is the side the empty case must fall: the reviewer
        was shown the diff and said nothing, which is precisely what the grade measures."""
        s = self.score([])
        self.assertEqual(s.verdicts, ())
        self.assertTrue(s.scorable)
        self.assertEqual((s.malformed, s.out_of_scope), (0, 0))
        self.assertTrue(self.in_scorable_subset(s))

    def test_every_unscorable_verdict_is_one_of_the_five_finding_verdicts(self):
        """The two vocabularies cannot drift: a verdict named unscorable that no finding can carry
        would make the rule dead, and a sixth finding verdict added without classifying it here
        would fall silently on the scorable side."""
        for v in re_.UNSCORABLE_VERDICTS:
            self.assertIn(v, re_.FINDING_VERDICTS)
        self.assertEqual(set(re_.UNSCORABLE_VERDICTS), {re_.MALFORMED, re_.OUT_OF_SCOPE})

    def test_score_escape_case_REQUIRES_the_diff_manifest(self):
        """The same fail-open default S1 closed on `catch_verdict`, one level up: this function
        defaulted `diff_files=None` and passed it down, so a caller that forgot it reached the
        refusal at run time on one path instead of at the call site on all of them."""
        with self.assertRaises(TypeError):
            re_.score_escape_case('c1', [finding()], [defect()])  # type: ignore[call-arg]


class RunSummaryProducer(unittest.TestCase):
    """S2's aggregation half. One producer, so the four sets are four readings of ONE run."""

    def scores(self):
        caught = re_.score_escape_case('e-caught', [finding(15, 16)], [defect(10, 20)], FILES)
        missed = re_.score_escape_case('e-missed', [finding(500, 501)], [defect(10, 20)], FILES)
        unscorable = re_.score_escape_case(
            'e-unscorable', [finding(1, 2, file=OUTSIDE)], [defect(10, 20)], FILES)
        return caught, missed, unscorable

    def test_the_producer_derives_every_set_from_the_scores(self):
        caught, missed, unscorable = self.scores()
        r = re_.build_run_summary([caught, missed, unscorable], {'k0': 1, 'k1': 0}, 'mh')
        self.assertEqual(r.case_ids, ('e-caught', 'e-missed', 'e-unscorable'))
        self.assertEqual(r.caught_case_ids, ('e-caught',))
        self.assertEqual(r.scorable_case_ids, ('e-caught', 'e-missed'))
        self.assertEqual(r.clean_case_ids, ('k0', 'k1'))
        self.assertEqual(r.false_alarms, 1)
        self.assertEqual(r.catches, 1)
        self.assertEqual(r.escape_cases, 3)
        self.assertEqual(r.clean_cases, 2)
        self.assertEqual(r.case_manifest_hash, 'mh')

    def test_the_unscorable_case_is_absent_from_the_scorable_subset_in_both_directions(self):
        caught, missed, unscorable = self.scores()
        r = re_.build_run_summary([caught, missed, unscorable], {'k0': 0}, 'mh')
        self.assertIn('e-unscorable', r.case_ids, 'it was covered')
        self.assertNotIn('e-unscorable', r.scorable_case_ids, 'and it was not graded')

    def test_the_finding_counts_are_summed_over_the_cases(self):
        malformed = re_.score_escape_case('e-m', [None, None], [defect(10, 20)], FILES)
        oos = re_.score_escape_case(
            'e-o', [finding(1, 2, file=OUTSIDE)], [defect(10, 20)], FILES)
        r = re_.build_run_summary([malformed, oos], {'k0': 0}, 'mh')
        self.assertEqual((r.malformed_findings, r.out_of_scope_findings), (2, 1))

    def test_a_duplicate_case_id_is_refused_and_named(self):
        """A case scored twice would weight it twice in a denominator the keep rule compares, and
        would make `case_ids` and the sets derived from it disagree about how many cases ran."""
        s = re_.score_escape_case('e-dup', [finding(15, 16)], [defect(10, 20)], FILES)
        with self.assertRaises(ValueError) as cm:
            re_.build_run_summary([s, s], {'k0': 0}, 'mh')
        self.assertIn('e-dup', str(cm.exception))

    def test_a_negative_clean_count_is_refused_at_the_producer(self):
        s = re_.score_escape_case('e0', [finding(15, 16)], [defect(10, 20)], FILES)
        with self.assertRaises(ValueError):
            re_.build_run_summary([s], {'k0': -1}, 'mh')

    def test_a_negative_finding_count_is_unconstructible(self):
        with self.assertRaises(ValueError):
            re_.RunSummary(
                false_alarms=0, case_ids=('e0',), caught_case_ids=(),
                scorable_case_ids=('e0',), clean_case_ids=('k0',), case_manifest_hash='h',
                malformed_findings=-1, out_of_scope_findings=0,
            )

    def test_a_catch_on_an_unscorable_case_is_unconstructible(self):
        """The two sets cannot contradict each other: a catch needs a finding that parsed AND
        cited a file inside the diff, so it cannot come out of a case whose every finding failed
        one of those."""
        with self.assertRaises(ValueError) as cm:
            re_.RunSummary(
                false_alarms=0, case_ids=('e0',), caught_case_ids=('e0',),
                scorable_case_ids=(), clean_case_ids=('k0',), case_manifest_hash='h',
                malformed_findings=0, out_of_scope_findings=0,
            )
        self.assertIn('e0', str(cm.exception))


class TwoIntroducerGeneralisation(unittest.TestCase):
    """The owner's 2026-10-26 widening, as the property that makes it invisible to the scorer.

    The widening lets a defect have more than one introducing change. The premise this arc
    inherited — that `score_escape_case` 'takes a single introducing diff' and must learn to take
    several — is false, measured against the shipped signature: it takes a FLAT list of
    already-derived defect LOCATIONS. Deriving those locations from one introducer or from two is
    `git blame` provenance and belongs to the harvester in the other repository.

    So what is owed here is the control: locations derived from one introducer and locations
    derived from two must score IDENTICALLY when the resulting range sets are equal. The fixture
    is synthetic on purpose — the case data is private and lives in the repository under test
    (decision 12), and this module publishes to a public mirror. The real-case control is W1's,
    where both repositories are present at once.
    """

    FINDINGS = [finding(15, 16), finding(35, 36), finding(500, 501), None]

    def test_one_introducer_and_two_introducers_score_identically_on_an_equal_range_set(self):
        from_one = [defect(10, 20), defect(30, 40)]
        # The same set, as the union of what two separate introducers each accounted for.
        from_two = [defect(10, 20)] + [defect(30, 40)]
        a = re_.score_escape_case('c', self.FINDINGS, from_one, FILES)
        b = re_.score_escape_case('c', self.FINDINGS, from_two, FILES)
        self.assertEqual(a, b)

    def test_the_order_the_union_was_assembled_in_does_not_move_the_score(self):
        """A union is a set; a concatenation has an order. If the scorer's answer moved with the
        order, the harvester's choice of which introducer to walk first would move the grade."""
        a = re_.score_escape_case('c', self.FINDINGS, [defect(10, 20), defect(30, 40)], FILES)
        b = re_.score_escape_case('c', self.FINDINGS, [defect(30, 40), defect(10, 20)], FILES)
        self.assertEqual(a.verdicts, b.verdicts)
        self.assertEqual(a.caught, b.caught)
        self.assertEqual(a.near_misses, b.near_misses)

    def test_the_control_a_DIFFERENT_range_set_does_move_the_score(self):
        """Without this row the two above also pass for a scorer that ignores `defects` entirely,
        which is the implementation that makes every case a miss."""
        one_only = re_.score_escape_case('c', self.FINDINGS, [defect(10, 20)], FILES)
        both = re_.score_escape_case('c', self.FINDINGS, [defect(10, 20), defect(30, 40)], FILES)
        self.assertEqual(one_only.verdicts,
                         (re_.CATCH, re_.MISS, re_.MISS, re_.MALFORMED))
        self.assertEqual(both.verdicts,
                         (re_.CATCH, re_.CATCH, re_.MISS, re_.MALFORMED))
        self.assertNotEqual(one_only.verdicts, both.verdicts)


class CleanCaseScoring(unittest.TestCase):
    """S3. A clean case has no defect, so it cannot go through the escape scorer at all.

    `score_escape_case` refuses an empty defect-location set, and that refusal is correct: an
    escape case with no known location cannot be graded. A clean case has no location BY
    DEFINITION — it is a merged change no repair ever named — so routing one through that function
    would turn the definitional difference into a crash. The exemption is in the shape: this
    function has no `defects` parameter to be empty.
    """

    def test_a_clean_case_with_no_findings_scores_zero_rather_than_raising(self):
        """Zero findings on a clean case is the BEST result, not a missing measurement. This is
        the asymmetry between the keep rule's two halves: zero catches is evidence of a bad
        reviewer, zero false alarms is evidence of a good one."""
        self.assertEqual(re_.score_clean_case('k0', []), 0)

    def test_the_escape_scorer_would_RAISE_on_the_same_case(self):
        """The control that makes the row above mean something. Without it, 'a clean case scores
        zero' is satisfied by any function at all."""
        with self.assertRaises(ValueError):
            re_.score_escape_case('k0', [], [], FILES)

    def test_only_the_two_harmful_outcomes_count_against_the_reviewer(self):
        self.assertEqual(re_.score_clean_case('k0', [
            re_.OUTCOME_REVIEWER_WRONG,
            re_.OUTCOME_NOT_REACHABLE,
        ]), 2)
        self.assertEqual(re_.score_clean_case('k0', [
            re_.OUTCOME_INTENTIONAL,
            re_.OUTCOME_DIDNT_MATTER,
        ]), 0, 'right about the code and wrong about its importance is noise, not harm')

    def test_deferred_counts_neither_way_because_it_has_not_been_judged(self):
        self.assertEqual(re_.score_clean_case('k0', [re_.OUTCOME_DEFERRED]), 0)

    def test_every_outcome_is_classified_and_a_mixed_case_sums_only_the_harmful_ones(self):
        """Swept over the whole closed set, so a seventh outcome added without classifying it
        reddens here rather than falling silently on the harmless side."""
        for o in re_.FINDING_OUTCOMES:
            self.assertEqual(
                re_.score_clean_case('k0', [o]),
                1 if o in re_.FALSE_ALARM_OUTCOMES else 0,
                f'{o!r} must be classified one way or the other',
            )
        mixed = list(re_.FINDING_OUTCOMES)
        self.assertEqual(re_.score_clean_case('k0', mixed), len(re_.FALSE_ALARM_OUTCOMES))

    def test_an_unrecognised_outcome_RAISES_and_the_refusal_names_the_CASE(self):
        """Skipping it would under-count false alarms, which is the direction that approves a
        reviewer change the keep rule should reject. The case id is in the message because a count
        over twenty-seven cases is unactionable without knowing which one carried the bad row."""
        with self.assertRaises(ValueError) as cm:
            re_.score_clean_case('k-seven', [re_.OUTCOME_FIXED, 'wontfix'])
        msg = str(cm.exception)
        self.assertIn('k-seven', msg)
        self.assertIn('wontfix', msg, 'and the value that was not recognised')

    def test_the_score_feeds_the_run_summary_producer_unchanged(self):
        """The count and the set it came from travel as ONE object into the summary, so a clean
        count can never be reported beside a clean id list it does not match."""
        counts = {k: re_.score_clean_case(k, o) for k, o in (
            ('k0', [re_.OUTCOME_REVIEWER_WRONG]),
            ('k1', []),
            ('k2', [re_.OUTCOME_INTENTIONAL, re_.OUTCOME_NOT_REACHABLE]),
        )}
        caught = re_.score_escape_case('e0', [finding(15, 16)], [defect(10, 20)], FILES)
        r = re_.build_run_summary([caught], counts, 'h')
        self.assertEqual(r.clean_case_ids, ('k0', 'k1', 'k2'))
        self.assertEqual(r.false_alarms, 2)
        self.assertEqual(r.clean_cases, 3)


#: The effective context window this project's reviewer runs in, read live from the model catalog
#: at spec time: 272,000 nominal, discounted to 95%. A named constant because two tests sweep
#: against it and a literal repeated at each would let them drift apart.
WINDOW_TOKENS = 258_400

#: Everything a run carries BESIDE the case diff — prompt, schema, instructions, and the
#: reviewer's own output. It is named here so the admission rows below have one envelope and not
#: four, and it must equal what the repository under review DECLARES: a sweep anchored to a
#: different envelope from the live one sweeps the wrong boundary and says nothing.
#:
#: It was the plan's unmeasured working allowance until W1 measured the three parts over this
#: arc's own nineteen Codex runs — lens prompt 1,958-3,366 tokens, output schema 806, the
#: reviewer's own output 180-3,053 — a worst case of 7,225 that 12,000 bounds with 66% headroom.
#: The repository under review was carrying 2,500, below its own largest single prompt, and was
#: raised to this figure. `tracks_meet_test.py` reads this line and pins the two together.
ENVELOPE_TOKENS = 12_000

#: The fourteen kept cases' production-slice sizes, as the bytes/4 ESTIMATES that were recorded
#: for them. They are labelled estimates because that is what they are: the largest was later
#: measured with the real tokenizer at 178,003 against its 167,877 estimate, so the estimate
#: UNDER-counted by 6.0%. No case number appears here — this module publishes to a public mirror
#: and the case data is private (decision 12), so the sizes travel without their identities.
KEPT_SLICE_TOKEN_ESTIMATES = (
    1_738, 2_783, 6_208, 6_857, 12_604, 13_465, 17_259,
    18_347, 27_936, 30_837, 41_371, 44_505, 54_567, 167_877,
)

#: The largest kept case's MEASURED token count (tiktoken 0.14.0, o200k_base), against the
#: 167,877 estimate above. This is the number an admission decision is allowed to use.
LARGEST_KEPT_MEASURED_TOKENS = 178_003


class CapacityAdmission(unittest.TestCase):
    """S4. Nothing refused an over-window case, so a case too large to review would be launched.

    The bound is `measured + envelope <= window`, and the envelope is a separate argument because
    a bound comparing the diff ALONE to the window admits a case that fits with nothing else in
    the window, which never happens: the prompt, the schema and the reviewer's own output are all
    in there too.
    """

    def admits(self, measured, envelope=ENVELOPE_TOKENS, window=WINDOW_TOKENS):
        return re_.admits_case(measured, envelope, window)[0]

    # ---- the three rows that make the envelope OBSERVABLE -------------------------------------
    #
    # Without these, every row in this class also passes for an implementation that ignores
    # `envelope_tokens` entirely: all fourteen real cases fit without it, and a 300,000-token
    # case exceeds the window on its own. A ceiling that cannot fail in one direction is not a
    # cheap test, it is an absent one.

    def test_the_envelope_is_what_refuses_a_case_that_fits_on_its_own(self):
        """250,000 is under the window. 250,000 + 12,000 is not. A mutant ignoring the envelope
        answers True here, and THIS is the test named as its killer."""
        admitted, why = re_.admits_case(250_000, ENVELOPE_TOKENS, WINDOW_TOKENS)
        self.assertFalse(admitted)
        self.assertIn('250000', why, 'a refusal names the size that did not fit')
        self.assertIn('3600', why, 'and by how much')

    def test_a_case_that_fits_WITH_the_envelope_is_admitted(self):
        self.assertTrue(self.admits(240_000))

    def test_exact_equality_is_admitted_and_the_boundary_is_decided_here(self):
        """246,400 + 12,000 is exactly 258,400. The bound is `<=`, stated rather than left open,
        because an undecided boundary is resolved differently by each reader — which is how one
        case acquires two admission answers."""
        admitted, why = re_.admits_case(246_400, ENVELOPE_TOKENS, WINDOW_TOKENS)
        self.assertTrue(admitted)
        self.assertIn('0 spare', why)
        self.assertFalse(self.admits(246_401), 'and one token past it is refused')

    # ---- the real population, which is the evidence the bound admits what it must -------------

    def test_the_largest_kept_case_is_admitted_at_its_MEASURED_size(self):
        admitted, why = re_.admits_case(
            LARGEST_KEPT_MEASURED_TOKENS, ENVELOPE_TOKENS, WINDOW_TOKENS)
        self.assertTrue(admitted)
        self.assertIn('178003', why)
        self.assertIn('68397', why, 'the spare headroom, by exact value')

    def test_every_kept_case_is_admitted_at_its_CONSERVATIVE_projection(self):
        """Swept at the projection rather than at the estimate, and the distinction is the point:
        only the largest case has a measured count, so for the other thirteen the honest input is
        the conservative UPPER bound on their tokens. If the over-statement is admitted, the
        measurement is too."""
        for est in KEPT_SLICE_TOKEN_ESTIMATES:
            projected = re_.project_tokens_from_bytes(est * 4)
            self.assertTrue(
                self.admits(projected),
                f'a kept case projected at {projected} tokens must be admitted',
            )

    def test_the_projection_over_states_the_largest_case_rather_than_under_stating_it(self):
        """The direction is the whole reason the projection is a separate function: 3.5 bytes per
        token over-states a real 3.77, and over-stating refuses a case rather than admitting one
        that will not fit. `bytes / 4` under-stated this case by 6.0% and that is the dangerous
        direction."""
        projected = re_.project_tokens_from_bytes(671_509)
        self.assertEqual(projected, 191_860)
        self.assertGreater(projected, LARGEST_KEPT_MEASURED_TOKENS)
        self.assertEqual(671_509 // 4, 167_877, 'the estimate that under-counted')
        self.assertLess(671_509 // 4, LARGEST_KEPT_MEASURED_TOKENS)

    def test_a_synthetic_over_window_case_is_refused_and_its_size_is_named(self):
        admitted, why = re_.admits_case(300_000, ENVELOPE_TOKENS, WINDOW_TOKENS)
        self.assertFalse(admitted)
        self.assertIn('300000', why)
        self.assertIn('258400', why)
        self.assertIn('53600', why, 'by how much it overflows, so the reason is actionable')

    # ---- degenerate inputs, each refused for its own reason ------------------------------------

    def test_a_zero_token_case_with_room_for_the_envelope_is_admitted(self):
        self.assertTrue(self.admits(0))

    def test_a_negative_count_raises_rather_than_answering(self):
        for measured, envelope in ((-1, ENVELOPE_TOKENS), (1, -1)):
            with self.assertRaises(ValueError):
                re_.admits_case(measured, envelope, WINDOW_TOKENS)

    def test_a_non_positive_window_raises_because_it_is_a_CALLER_fault(self):
        """A zero window admits nothing, which would read as every case being too large. The
        caller failed to read the model catalog; that is not a property of any case."""
        for window in (0, -1):
            with self.assertRaises(ValueError) as cm:
                re_.admits_case(1, 0, window)
            self.assertIn('window_tokens', str(cm.exception))

    def test_the_projection_refuses_a_negative_byte_count(self):
        with self.assertRaises(ValueError):
            re_.project_tokens_from_bytes(-1)

    def test_the_conservative_divisor_bounds_the_worst_measured_ratio(self):
        """3.5 against a measured worst of 3.70. Asserted so that raising the divisor — which
        would make the projection under-state — reddens here with the reason attached."""
        self.assertEqual(re_.CONSERVATIVE_BYTES_PER_TOKEN, 3.5)
        self.assertLess(re_.CONSERVATIVE_BYTES_PER_TOKEN, 3.70)

    def test_property_admission_is_monotonic_in_the_case_size(self):
        """A smaller case is never refused where a larger one was admitted. The bound is a sum, so
        this holds by construction — asserted because a later special case would break it
        silently."""
        rnd = random.Random(17)
        for _ in range(400):
            smaller = rnd.randint(0, 300_000)
            larger = smaller + rnd.randint(0, 50_000)
            if self.admits(larger):
                self.assertTrue(self.admits(smaller))

class ShallowPatternGrammar(unittest.TestCase):
    """`matches_shallow_pattern` and `shallow_path_predicate` — the shallow list's own matcher.

    W1 measured why this exists rather than reusing the deep list's matcher: pointed at the
    glob-shaped entries a repository declares, `_path_matches` answered correctly for 1 of the 3
    witnesses the design names, because two of them are not whole paths and not directory
    prefixes. The two matchers answer different input classes.
    """

    #: One row per shape of the grammar, with the answer written out. Two expressions agreeing
    #: with each other would be the same defect this twin exists to catch.
    ROWS = (
        ('AGENTS.md', 'AGENTS.md', True),
        ('README.md', 'AGENTS.md', False),
        ('README.md', '*.md', True),
        ('AGENTS.md', '*.md', True),
        ('README.txt', '*.md', False),
        ('.github/one.md', '.github/*.md', True),
        ('.github/one.md', '*.md', False),
        ('notes/deep/sub/a.md', '*.md', False),
        ('.github/sub/a.md', '.github/*.md', False),
    )

    def test_every_shape_of_the_grammar_answers_exactly(self):
        self.assertEqual(
            [re_.matches_shallow_pattern(path, pattern) for path, pattern, _ in self.ROWS],
            [expected for _, _, expected in self.ROWS])

    def test_a_wildcard_never_crosses_a_directory_boundary(self):
        """The wide reading is the DANGEROUS one: it makes a deep code change's sibling
        documentation claim the whole change as shallow, which lowers the review depth."""
        self.assertFalse(re_.matches_shallow_pattern('notes/deep/sub/a.md', '*.md'))
        self.assertFalse(re_.matches_shallow_pattern('.github/sub/a.md', '.github/*.md'))

    def test_a_pattern_outside_the_grammar_raises_rather_than_matching_nothing(self):
        """A silent non-match is a rule that stopped applying with no diff line to point at, and
        nothing downstream could tell it from "no file matched"."""
        for pattern in ('**/*.md', '*', '*md', 'doc*/a.md', '*.md*'):
            with self.assertRaises(ValueError, msg=pattern):
                re_.matches_shallow_pattern('README.md', pattern)
        with self.assertRaises(TypeError):
            re_.matches_shallow_pattern('README.md', 42)

    def test_the_predicate_reads_BOTH_halves_from_the_declaration(self):
        is_shallow = re_.shallow_path_predicate({
            'ciDocsOnly': {'prefixes': ['notes/'], 'extensions': ['.md', '.txt']},
            'reviewOnly': ['*.md', 'AGENTS.md', '.github/*.md'],
        })
        self.assertEqual(
            [is_shallow(p) for p in ('notes/a.md', 'notes/a.txt', 'notes/a.ts', 'README.md',
                                     'AGENTS.md', '.github/one.md', 'other/a.md', '')],
            [True, True, False, True, True, True, False, False])

    def test_the_ci_half_requires_BOTH_a_prefix_AND_an_extension(self):
        """A prefix is necessary and never sufficient, which is how the repository under review
        defines its own rule; widening it here would loosen a rule about running a test suite."""
        is_shallow = re_.shallow_path_predicate(
            {'ciDocsOnly': {'prefixes': ['notes/'], 'extensions': ['.md']}, 'reviewOnly': []})
        self.assertEqual([is_shallow('notes/a.md'), is_shallow('notes/a.ts'), is_shallow('x.md')],
                         [True, False, False])

    def test_a_malformed_declaration_raises_rather_than_answering_False(self):
        """A predicate answering False for everything reviews every documentation change at the
        ordinary depth; one answering True reviews code at a single lens. Neither may be reached
        by a missing field."""
        with self.assertRaises(TypeError):
            re_.shallow_path_predicate(None)
        for bad in ({}, {'ciDocsOnly': {}, 'reviewOnly': []},
                    {'ciDocsOnly': {'prefixes': [], 'extensions': []}, 'reviewOnly': 'x'}):
            with self.assertRaises(ValueError, msg=repr(bad)):
                re_.shallow_path_predicate(bad)

    def test_it_drives_depth_verdict_to_the_single_lens_the_declaration_asks_for(self):
        """The integration this whole function exists for: the declaration's own witnesses must
        reach `SINGLE_LENS`, which is where reusing the deep matcher gave `STANDARD`."""
        is_shallow = re_.shallow_path_predicate({
            'ciDocsOnly': {'prefixes': ['notes/'], 'extensions': ['.md']},
            'reviewOnly': ['*.md', 'AGENTS.md', '.github/*.md'],
        })
        for path in ('README.md', 'AGENTS.md', '.github/one.md', 'notes/a.md'):
            self.assertEqual(re_.depth_verdict([path], ('money',), is_shallow)[0],
                             re_.SINGLE_LENS, path)
        # And the wide reading is still refused through the whole selector, not only the matcher.
        # The control path sits OUTSIDE every declared CI prefix on purpose: `notes/deep/sub/a.md`
        # is shallow by the CI half, which would have made this row pass for the wrong reason.
        self.assertEqual(re_.depth_verdict(['other/deep/sub/a.md'], ('money',), is_shallow)[0],
                         re_.STANDARD)


def main():
    argv = sys.argv[1:]
    prog = unittest.main(module=__name__, argv=[sys.argv[0]] + argv, exit=False, verbosity=1)
    res = prog.result
    failed = len(res.failures) + len(res.errors)
    passed = res.testsRun - failed - len(res.skipped)
    print(f'\nTest Files  {"1 failed" if failed else "1 passed"} (1)')
    print(f'Tests  {passed} passed' + (f' | {failed} failed' if failed else '')
          + (f' | {len(res.skipped)} skipped' if res.skipped else '') + f' ({res.testsRun})')
    return 1 if failed else 0


if __name__ == '__main__':
    sys.exit(main())
