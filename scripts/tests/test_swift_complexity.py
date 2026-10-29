import importlib.util
import os
import unittest
from pathlib import Path

SPEC = importlib.util.spec_from_file_location(
    "complexity", Path(__file__).parents[1] / "check_swift_complexity.py")
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class ComplexityRatchetTests(unittest.TestCase):
    def test_new_or_worse_function_fails_without_count_tradeoffs(self):
        old = {("File.swift", "func old()", "cyclomatic_complexity"): 12}
        new_key = ("File.swift", "func new()", "cyclomatic_complexity")
        worse = {**old, new_key: 11}
        self.assertEqual(len(MODULE.regressions(old, worse)), 1)
        self.assertEqual(len(MODULE.regressions(old, {next(iter(old)): 13})), 1)
        self.assertEqual(len(MODULE.regressions(old, {new_key: 12})), 1)

    def test_unchanged_improved_removed_and_reordered_functions_pass(self):
        first = ("File.swift", "func first()", "function_body_length")
        second = ("File.swift", "func second()", "function_body_length")
        old = {first: 60, second: 70}
        for new in (old, {first: 55}, {second: 70, first: 60}, {}):
            self.assertEqual(MODULE.regressions(old, new), [])

    def test_reports_use_declarations_not_line_numbers(self):
        source = "func first() {\n}\n\nfunc second() {\n}\n"
        report = [{"file": "File.swift", "line": 1, "rule_id": "function_body_length",
                   "reason": "Function body should span 50 lines or less excluding comments and whitespace: currently spans 60 lines"}]
        old = MODULE.metrics(report, {"File.swift": source})
        shifted = "\n\n" + source
        new = MODULE.metrics([{**report[0], "line": 3}], {"File.swift": shifted})
        self.assertEqual(old, new)

    def test_duplicate_declarations_keep_separate_budgets(self):
        report = [{"file": "File.swift", "line": 1, "rule_id": "cyclomatic_complexity",
                   "reason": "Function should have complexity 10 or less; currently complexity is 12"}]
        files = {"File.swift": "func same() {\n}\nfunc same() {\n}\n"}
        report.append({**report[0], "line": 3})
        result = MODULE.metrics(report, files)
        self.assertEqual(len(result), 2)
        self.assertEqual(result, MODULE.metrics(report, files))
        changed = {"File.swift": "// changed\n" + files["File.swift"]}
        moved = [{**item, "line": item["line"] + 1} for item in report]
        self.assertTrue(MODULE.regressions(result, MODULE.metrics(moved, changed)))

    def test_unknown_analyzer_output_fails_closed(self):
        with self.assertRaises(ValueError):
            MODULE.metrics([{"file": "File.swift", "line": 1,
                             "rule_id": "cyclomatic_complexity", "reason": "changed format"}],
                           {"File.swift": "func f() {}"})


    @unittest.skipUnless(os.environ.get("SWIFTLINT"), "set SWIFTLINT for native analyzer fixtures")
    def test_actual_analyzer_rejects_growth_and_inline_disabling(self):
        tool = os.environ["SWIFTLINT"]
        source = "func complex() {\n" + "if true {}\n" * 12 + "}\n"
        old_files = {"Fixture.swift": source}
        old = MODULE.metrics(MODULE.analyze(tool, old_files), old_files)
        self.assertTrue(old)
        for candidate in (source.replace("}\n", "if true {}\n}\n", 1),
                          source + "func long() {\n" + "print(1)\n" * 55 + "}\n"):
            new_files = {"Fixture.swift": "// swiftlint:disable all\n" + candidate}
            new = MODULE.metrics(MODULE.analyze(tool, new_files), new_files)
            self.assertTrue(MODULE.regressions(old, new))
        moved = {"Moved.swift": "\n" + source}
        metrics = MODULE.metrics(MODULE.analyze(tool, moved), moved,
                                 {"Moved.swift": "Fixture.swift"})
        self.assertEqual(MODULE.regressions(old, metrics), [])
        other = source.replace("complex()", "other()")
        original = {"Fixture.swift": source + other}
        reordered = {"Fixture.swift": other + source}
        before = MODULE.metrics(MODULE.analyze(tool, original), original)
        after = MODULE.metrics(MODULE.analyze(tool, reordered), reordered)
        self.assertEqual(MODULE.regressions(before, after), [])


if __name__ == "__main__":
    unittest.main()
