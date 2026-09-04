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


if __name__ == '__main__':
    sys.exit(main())
