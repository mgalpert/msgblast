"""Build timing parses xcodebuild output and only ever wipes its own folder under build/."""
import argparse
import importlib.util
import os
from pathlib import Path
import tempfile
import unittest
from unittest import mock


ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('build_timing', ROOT / 'scripts/build_timing.py')
timing = importlib.util.module_from_spec(spec)
spec.loader.exec_module(timing)


class BuildTimingTests(unittest.TestCase):
    def test_counts_distinct_compiled_sources_including_batches(self):
        log = '\n'.join([
            "SwiftCompile normal arm64 Compiling\\ Models.swift /src/msgblast/Core/Models.swift (in target 'msgblastCore' from project 'msgblast')",
            'SwiftCompile normal arm64 Compiling\\ A.swift,\\ B.swift /src/msgblast/A.swift /src/msgblast/B.swift',
            'SwiftCompile normal arm64 /src/msgblast/A.swift',
            'SwiftEmitModule normal arm64 Emitting\\ module\\ for\\ msgblastCore',
            'note: /src/msgblast/C.swift is not a compile line',
        ])
        self.assertEqual(timing.compiled_files(log), 3)
        self.assertEqual(timing.compiled_files('Build succeeded'), 0)

    def test_slowest_type_checks_are_project_only_deduplicated_and_ranked(self):
        source = ROOT / 'msgblast'
        log = '\n'.join([
            f"{source}/Windows/Views.swift:10:5: warning: instance method 'body' took 250ms to type-check (limit: 200ms)",
            f"{source}/Windows/Views.swift:10:5: warning: instance method 'body' took 250ms to type-check (limit: 200ms)",
            f'{source}/Core/Models.swift:3:9: warning: expression took 900ms to type-check (limit: 200ms)',
            f"{ROOT}/build/SourcePackages/checkouts/Kit/A.swift:1:1: warning: global function 'f()' took 999ms to type-check (limit: 200ms)",
        ])
        slowest = timing.slowest_type_checks(log, source, 15)
        self.assertEqual([item['ms'] for item in slowest], [900.0, 250.0])
        self.assertEqual(slowest[0]['location'], 'msgblast/Core/Models.swift:3:9')
        self.assertEqual(slowest[1]['what'], "instance method 'body'")
        self.assertEqual(len(timing.slowest_type_checks(log, source, 1)), 1)

    def test_work_folder_must_be_inside_build(self):
        self.assertEqual(timing.owned_build_dir(ROOT / 'build/build-timing'), ROOT / 'build/build-timing')
        for unsafe in [ROOT / 'build', ROOT, ROOT / 'msgblast', Path.home() / 'Library/Developer/Xcode/DerivedData',
                       ROOT / 'build/../msgblast']:
            with self.assertRaises(SystemExit, msg=str(unsafe)):
                timing.owned_build_dir(unsafe)

    def test_touch_keeps_content_and_restores_original_modification_time(self):
        (ROOT / 'build').mkdir(exist_ok=True)
        with tempfile.TemporaryDirectory(dir=ROOT / 'build') as work:
            source = Path(work) / 'Leaf.swift'
            source.write_text('struct Leaf {}\n')
            os.utime(source, ns=(1_000_000_000, 2_000_000_000))
            timer = timing.Timer(argparse.Namespace(work_dir=Path(work) / 'timing'))
            relative = source.relative_to(ROOT)
            timer.touch(relative)
            timer.touch(relative)
            self.assertGreater(source.stat().st_mtime_ns, 2_000_000_000)
            timer.restore()
            self.assertEqual(source.stat().st_mtime_ns, 2_000_000_000)
            self.assertEqual(source.read_text(), 'struct Leaf {}\n')

    def test_table_reports_median_min_and_runs(self):
        steps = [{'step': 'cold build', 'seconds': [120.0], 'swift_files_compiled': 96},
                 {'step': 'no-op rebuild', 'seconds': [3.0, 2.0, 9.0], 'swift_files_compiled': 0}]
        text = timing.table(steps)
        self.assertIn('no-op rebuild', text)
        self.assertRegex(text, r'no-op rebuild\s+3\.0\s+2\.0\s+3\s+0')
        markdown = timing.table(steps, markdown=True).splitlines()
        self.assertEqual(markdown[1], '| --- | --- | --- | --- | --- |')
        self.assertEqual(markdown[2], '| cold build | 120.0 | 120.0 | 1 | 96 |')

    def test_refuses_to_run_off_macos(self):
        if timing.platform.system() == 'Darwin':
            self.skipTest('Only meaningful on non-macOS hosts')
        with mock.patch('sys.argv', ['build_timing.py']), self.assertRaises(SystemExit) as raised:
            timing.main()
        self.assertIn('needs macOS', str(raised.exception))


if __name__ == '__main__':
    unittest.main()
