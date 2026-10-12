"""UI validation must not false-pass when XCTest executes no interactions."""
import unittest

from scripts.check_ui_results import check


class UIResultTests(unittest.TestCase):
    def summary(self):
        return dict(result="Passed", totalTestCount=34, passedTests=34,
                    failedTests=0, skippedTests=0, expectedFailures=0)

    def test_complete_run_is_accepted(self):
        self.assertEqual(check(self.summary()), 34)

    def test_empty_skipped_expected_and_failed_runs_are_rejected(self):
        for changes in [
            dict(totalTestCount=0, passedTests=0),
            dict(passedTests=33, skippedTests=1),
            dict(passedTests=33, expectedFailures=1),
            dict(result="Failed", passedTests=8, failedTests=26),
            dict(passedTests=33),
        ]:
            with self.subTest(changes=changes):
                summary = self.summary()
                summary.update(changes)
                with self.assertRaises(ValueError):
                    check(summary)

    def test_missing_or_malformed_counts_fail_closed(self):
        with self.assertRaises(ValueError):
            check([])
        for value in [None, True, "34", -1]:
            with self.subTest(value=value):
                summary = self.summary()
                summary["totalTestCount"] = value
                with self.assertRaises(ValueError):
                    check(summary)
