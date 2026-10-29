#!/usr/bin/env python3
"""mutate_test.py — pins mutate.py's multi-select guard (`selected_tests`) against real vitest 4
summary-line shapes.

Run:  python3 mutate_test.py [-k PATTERN]
Prints a vitest-shaped `Test Files` / `Tests` summary at the end so mutate.py's own zero-match
guard (`tests_ran`) applies to THIS file's mutants too, the same way loop_test.py does for loop.py:
  mutate.py --src mutate.py --test mutate_test.py --copy-dir <copy> --mutants <json> \
            --test-cmd 'python3 {test} {filter}' --filter-flag -k
"""
from __future__ import annotations

import os
import sys
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import mutate  # noqa: E402


class TestSelectedTests(unittest.TestCase):
    """Pins `mutate.selected_tests` against real vitest 4.1 `Tests ...` summary shapes.

    The count is failed + passed — never skipped — because that is what a mutant's `test`
    filter actually SELECTED to run. A filter naming "S4" that also matches "S4b" and "S4c"
    (the measured instance this rule exists for) must read as 3 selected, not 1, or a mutant
    it kills reads as "killed by its named test" when a neighbour may have done the killing.
    """

    def test_one_passed_none_failed(self):
        self.assertEqual(mutate.selected_tests('Tests  1 passed | 104 skipped (105)'), 1)

    def test_one_failed_one_passed(self):
        self.assertEqual(mutate.selected_tests('Tests  1 failed | 1 passed | 103 skipped (105)'), 2)

    def test_failed_only_with_skipped(self):
        self.assertEqual(mutate.selected_tests('Tests  2 failed | 103 skipped (105)'), 2)

    def test_no_skipped_clause_when_nothing_filtered_out(self):
        # a filter that happens to select everything in the file omits the `| N skipped` clause
        self.assertEqual(mutate.selected_tests('Tests  3 passed (3)'), 3)

    def test_multi_digit_counts(self):
        self.assertEqual(mutate.selected_tests('Tests  12 failed | 34 passed | 5 skipped (51)'), 46)

    def test_leading_whitespace_is_tolerated(self):
        self.assertEqual(mutate.selected_tests('   Tests  1 passed | 2 skipped (3)'), 1)

    def test_ansi_colour_codes_are_stripped(self):
        line = '\x1b[32mTests\x1b[39m  \x1b[32m1 passed\x1b[39m | \x1b[2m104 skipped\x1b[22m (105)'
        self.assertEqual(mutate.selected_tests(line), 1)

    def test_plain_line_with_no_ansi_parses_the_same(self):
        # the control for the case above: coloured and plain must agree on the same content
        self.assertEqual(mutate.selected_tests('Tests  1 passed | 104 skipped (105)'),
                          mutate.selected_tests('\x1b[32mTests\x1b[39m  1 passed | 104 skipped (105)'))

    def test_none_is_not_a_summary(self):
        self.assertIsNone(mutate.selected_tests(None))

    def test_empty_string_is_not_a_summary(self):
        self.assertIsNone(mutate.selected_tests(''))

    def test_the_test_files_line_is_not_the_tests_line(self):
        self.assertIsNone(mutate.selected_tests('Test Files  1 passed (1)'))

    def test_garbage_is_not_a_summary(self):
        self.assertIsNone(mutate.selected_tests('not a vitest summary at all'))

    def test_tests_prefix_with_no_numbers_is_unparseable(self):
        self.assertIsNone(mutate.selected_tests('Tests  (something odd)'))


def main():
    argv = sys.argv[1:]
    prog = unittest.main(module=__name__, argv=[sys.argv[0]] + argv, exit=False, verbosity=1)
    res = prog.result
    failed = len(res.failures) + len(res.errors)
    passed = res.testsRun - failed - len(res.skipped)
    print(f'\nTest Files  {"1 failed" if failed else "1 passed"} (1)')
    print(f'Tests  {passed} passed' + (f' | {failed} failed' if failed else '') + (f' | {len(res.skipped)} skipped' if res.skipped else '') + f' ({res.testsRun})')
    return 1 if failed else 0



class SummaryLineIsFoundOnColouredOutput(unittest.TestCase):
    """Pins `mutate.summary_line` against the bytes vitest ACTUALLY writes to a pipe.

    Every case in `SelectedTests` above hands `selected_tests` a string that is already
    stripped, so all of them passed while the caller that had to FIND that line could not see
    it at all.  Measured 2026-10-03: a five-mutant battery with a green baseline and five
    correct mutants reported 0/5, every one MULTI-SELECT, because `summary` was ''.

    The raw strings below are captured output, not hand-typed approximations — that is the
    whole point, since a hand-typed uncoloured case is what hid this for a release.
    """

    # vitest 2.1.9, `npx vitest run <file> -t <name>`, stdout redirected to a pipe.
    COLOURED = (
        '\x1b[2m Test Files \x1b[22m\x1b[1m\x1b[32m1 passed\x1b[39m\x1b[22m\x1b[90m (1)\x1b[39m\n'
        '\x1b[2m      Tests \x1b[22m\x1b[1m\x1b[32m1 passed\x1b[39m\x1b[22m\x1b[2m | \x1b[22m'
        '\x1b[33m8 skipped\x1b[39m\x1b[90m (9)\x1b[39m\n'
    )

    def test_finds_the_coloured_summary_line(self):
        self.assertEqual(mutate.summary_line(self.COLOURED), 'Tests 1 passed | 8 skipped (9)')

    def test_the_found_line_parses_to_one_selected_test(self):
        # The two halves together, which is the thing the battery depends on and the thing
        # neither half proved on its own.
        self.assertEqual(mutate.selected_tests(mutate.summary_line(self.COLOURED)), 1)

    def test_still_finds_an_uncoloured_summary(self):
        self.assertEqual(
            mutate.summary_line('   Test Files  1 passed (1)\n   Tests  3 passed (3)\n'),
            'Tests  3 passed (3)',
        )

    def test_absent_summary_is_empty_not_a_guess(self):
        # '' is what `selected_tests` turns into None, which is how a caller tells
        # "could not tell" from a real zero.
        self.assertEqual(mutate.summary_line('no summary here\n'), '')
        self.assertIsNone(mutate.selected_tests(mutate.summary_line('no summary here\n')))

    def test_a_coloured_test_files_line_is_not_mistaken_for_the_tests_line(self):
        # Control: ' Test Files ' also contains 'Test', and matching it would report the
        # FILE count as the number of selected tests — a 1 that happens to look right.
        self.assertEqual(
            mutate.summary_line(
                '\x1b[2m Test Files \x1b[22m2 passed (2)\n\x1b[2m      Tests \x1b[22m7 passed (7)\n'
            ),
            'Tests 7 passed (7)',
        )

    def test_failing_lines_are_found_through_colour(self):
        coloured = (
            '\x1b[31m   \x1b[31m\u00d7\x1b[31m a suite > a test name\x1b[39m\n'
            '\x1b[31m\x1b[1m\x1b[7m FAIL \x1b[27m\x1b[22m\x1b[39m tests/x.test.ts\n'
        )
        found = mutate.failing_lines(coloured)
        self.assertEqual(len(found), 2)
        self.assertTrue(found[0].startswith('\u00d7'))
        self.assertTrue(found[1].startswith('FAIL '))

    def test_failing_lines_are_empty_when_nothing_failed(self):
        self.assertEqual(mutate.failing_lines(self.COLOURED), [])



class NodeTestRunnerSummary(unittest.TestCase):
    """`summary_line` on `node --test`, whose counters are not one line (loop.node_test_counts)."""

    NODE_GREEN = (
        "\x1b[34m\u2139 tests 9\x1b[39m\n\x1b[34m\u2139 pass 9\x1b[39m\n"
        "\x1b[34m\u2139 fail 0\x1b[39m\n\x1b[34m\u2139 skipped 0\x1b[39m\n")

    def test_a_node_summary_is_synthesised_into_vitest_shape(self):
        self.assertEqual(mutate.selected_tests(mutate.summary_line(self.NODE_GREEN)), 9)

    def test_one_selected_failing_test_counts_as_one(self):
        out = "\u2139 tests 1\n\u2139 pass 0\n\u2139 fail 1\n"
        self.assertEqual(mutate.selected_tests(mutate.summary_line(out)), 1)

    def test_vitest_still_wins_when_both_shapes_are_present(self):
        both = "\x1b[2m      Tests \x1b[22m1 passed | 8 skipped (9)\n" + self.NODE_GREEN
        self.assertEqual(mutate.selected_tests(mutate.summary_line(both)), 1)

    def test_no_summary_at_all_is_still_unreadable(self):
        self.assertEqual(mutate.summary_line("nothing here\n"), '')
        self.assertIsNone(mutate.selected_tests(mutate.summary_line("nothing here\n")))


if __name__ == '__main__':
    sys.exit(main())
