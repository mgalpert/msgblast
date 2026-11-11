#!/usr/bin/env python3
"""Measure msgblast Debug build times: cold, no-op, leaf-touch and core-touch rebuilds.

Uses the documented xcodebuild Debug compile path with app signing disabled, in its
own derived data under build/. Touched sources keep their content; their original
modification times are restored on exit. Nothing is launched, installed or published.
"""
import argparse
import json
import os
from pathlib import Path
import platform
import re
import shutil
import signal
import statistics
import subprocess
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
LEAF = 'msgblast/Windows/InstallationView.swift'
CORE = 'msgblast/Core/Models.swift'
HELPERS = {'cloudflared': 'bundle_cloudflared.py', 'cua-driver': 'bundle_cua_driver.py'}
TYPE_CHECK = re.compile(r'^(?P<loc>/[^\n]+?\.swift:\d+:\d+): warning: (?P<what>.+?) took (?P<ms>\d+(?:\.\d+)?)ms to type-check', re.M)
SWIFT_PATH = re.compile(r'(/(?:\\ |\S)+?\.swift)(?=[\s,]|$)')


def compiled_files(log):
    """Distinct Swift sources named on xcodebuild SwiftCompile lines."""
    return len({path for line in log.splitlines() if line.startswith('SwiftCompile ')
                for path in SWIFT_PATH.findall(line)})


def slowest_type_checks(log, source_root, top):
    found = {}
    for match in TYPE_CHECK.finditer(log):
        loc = match['loc']
        if not loc.startswith(str(source_root) + '/'):
            continue
        entry = {'location': os.path.relpath(loc, ROOT), 'what': match['what'], 'ms': float(match['ms'])}
        if entry['ms'] > found.get(loc, {'ms': -1})['ms']:
            found[loc] = entry
    return sorted(found.values(), key=lambda item: -item['ms'])[:top]


def owned_build_dir(path):
    path = path.resolve()
    if path == ROOT / 'build' or ROOT / 'build' not in path.parents:
        raise SystemExit(f'Refusing to use {path}: the work folder must be inside {ROOT / "build"}.')
    return path


def table(steps, markdown=False):
    rows = [('Step', 'Median s', 'Min s', 'Runs', 'Swift files compiled')]
    for step in steps:
        samples = step['seconds']
        rows.append((step['step'], f'{statistics.median(samples):.1f}', f'{min(samples):.1f}',
                     str(len(samples)), str(step['swift_files_compiled'])))
    if markdown:
        lines = ['| ' + ' | '.join(row) + ' |' for row in rows]
        return '\n'.join([lines[0], '| --- ' * len(rows[0]) + '|', *lines[1:]])
    widths = [max(len(row[i]) for row in rows) for i in range(len(rows[0]))]
    return '\n'.join('  '.join(cell.ljust(width) for cell, width in zip(row, widths)) for row in rows)


def output(*command):
    try:
        return subprocess.run(command, capture_output=True, text=True, cwd=ROOT).stdout.strip()
    except OSError:
        return ''


def machine():
    return {
        'xcode': ' '.join(output('xcodebuild', '-version').split()),
        'developer_dir': output('xcode-select', '-p'),
        'macos': output('sw_vers', '-productVersion'),
        'model': output('sysctl', '-n', 'hw.model'),
        'cpu': output('sysctl', '-n', 'machdep.cpu.brand_string'),
        'cores': os.cpu_count(),
        'memory_gb': round(int(output('sysctl', '-n', 'hw.memsize') or 0) / 2**30),
        'runner_image': ' '.join(filter(None, [os.environ.get('ImageOS'), os.environ.get('ImageVersion')])),
        'git_sha': output('git', 'rev-parse', 'HEAD'),
        'git_dirty': bool(output('git', 'status', '--porcelain', '--untracked-files=no')),
    }


class Timer:
    def __init__(self, args):
        self.args = args
        self.derived = owned_build_dir(args.work_dir)
        self.packages = self.derived / 'SourcePackages'
        self.helpers = self.derived / 'helper-cache'
        self.logs = self.derived / 'logs'
        self.touched = {}

    def xcodebuild(self, derived, *settings):
        return ['xcodebuild', '-project', 'msgblast.xcodeproj', '-scheme', 'msgblast', '-configuration', 'Debug',
                '-destination', f'platform=macOS,arch={self.args.arch}', '-derivedDataPath', str(derived),
                '-clonedSourcePackagesDirPath', str(self.packages), '-skipPackageUpdates', '-hideShellScriptEnvironment',
                'ASSETCATALOG_COMPILER_APPICON_NAME=AppIconDemo',
                'MSGBLAST_APP_BUNDLE_IDENTIFIER=com.msgblast.build-timing', 'CODE_SIGNING_ALLOWED=NO', *settings, 'build']

    def run(self, name, command):
        self.logs.mkdir(parents=True, exist_ok=True)
        log = self.logs / (re.sub(r'[^a-z0-9]+', '-', name.lower()).strip('-') + '.log')
        print(f'→ {name}', flush=True)
        start = time.monotonic()
        with log.open('w') as handle:
            code = subprocess.run(command, cwd=ROOT, stdout=handle, stderr=subprocess.STDOUT).returncode
        seconds = time.monotonic() - start
        text = log.read_text(errors='replace')
        if code:
            print('\n'.join(text.splitlines()[-40:]), file=sys.stderr)
            raise SystemExit(f'{name} failed with exit code {code}; full log: {log}')
        print(f'  {seconds:.1f}s', flush=True)
        return seconds, text

    def step(self, name, repeat, before=None, derived=None, settings=()):
        samples, compiled, text = [], 0, ''
        for _ in range(repeat):
            if before:
                before()
            seconds, text = self.run(name, self.xcodebuild(derived or self.wipe_area, *settings))
            samples.append(round(seconds, 2))
            compiled = compiled_files(text)
        return {'step': name, 'seconds': samples, 'swift_files_compiled': compiled}, text

    @property
    def wipe_area(self):
        return self.derived / 'DerivedData'

    def clean(self, derived):
        shutil.rmtree(derived, ignore_errors=True)
        intermediates = derived / 'Build/Intermediates.noindex/msgblast.build'
        for name in HELPERS:
            shutil.copytree(self.helpers / name, intermediates / name, dirs_exist_ok=True)

    def touch(self, relative):
        path = ROOT / relative
        if not path.is_file():
            raise SystemExit(f'{relative} is not a file in this checkout.')
        self.touched.setdefault(path, path.stat())
        os.utime(path)

    def restore(self):
        for path, stat in self.touched.items():
            os.utime(path, ns=(stat.st_atime_ns, stat.st_mtime_ns))
        self.touched.clear()

    def prepare(self):
        start = time.monotonic()
        self.run('resolve packages', ['xcodebuild', '-resolvePackageDependencies', '-project', 'msgblast.xcodeproj',
                                      '-scheme', 'msgblast', '-clonedSourcePackagesDirPath', str(self.packages)])
        for name, script in HELPERS.items():
            with tempfile.TemporaryDirectory() as temporary:
                subprocess.run([sys.executable, str(ROOT / 'scripts' / script), '--archs', self.args.arch,
                                '--destination', str(Path(temporary) / name), '--cache', str(self.helpers / name)],
                               check=True, cwd=ROOT, stdout=subprocess.DEVNULL,
                               env={**os.environ, 'CODE_SIGNING_ALLOWED': 'NO'})
        return round(time.monotonic() - start, 2)

    def measure(self):
        args = self.args
        report = {'machine': machine(), 'settings': {'configuration': 'Debug', 'arch': args.arch, 'repeat': args.repeat,
                                                     'leaf': args.leaf, 'core': args.core}}
        report['prepare_seconds'] = self.prepare()
        steps = []
        if args.skip_cold:
            self.run('prime existing derived data', self.xcodebuild(self.wipe_area))
        else:
            self.clean(self.wipe_area)
            steps.append(self.step('cold build', 1)[0])
            seeded = self.wipe_area / 'Build/Intermediates.noindex/msgblast.build'
            if any(seeded not in path.parents for path in self.wipe_area.rglob('*.tgz')):
                print('Warning: the cold build downloaded helper archives; its time includes network.', file=sys.stderr)
        steps.append(self.step('no-op rebuild', args.repeat)[0])
        steps.append(self.step(f'leaf touch ({Path(args.leaf).name})', args.repeat, lambda: self.touch(args.leaf))[0])
        steps.append(self.step(f'core touch ({Path(args.core).name})', args.repeat, lambda: self.touch(args.core))[0])
        if args.type_check:
            flags = (f'OTHER_SWIFT_FLAGS=$(inherited) -Xfrontend -warn-long-function-bodies={args.threshold} '
                     f'-Xfrontend -warn-long-expression-type-checking={args.threshold}')
            derived = self.derived / 'DerivedData-typecheck'
            self.clean(derived)
            step, text = self.step('cold build with type-check warnings', 1, derived=derived, settings=[flags])
            steps.append(step)
            report['type_check'] = {'threshold_ms': args.threshold,
                                    'slowest': slowest_type_checks(text, ROOT / 'msgblast', args.top)}
        report['steps'] = steps
        return report


def print_report(report, args):
    print(f"\n{report['machine']['xcode']} on macOS {report['machine']['macos']}, {report['machine']['cpu']}, "
          f"{report['machine']['cores']} cores; setup (packages + helper archives) {report['prepare_seconds']:.1f}s\n")
    print(table(report['steps']))
    markdown = table(report['steps'], markdown=True)
    slowest = report.get('type_check', {}).get('slowest')
    if slowest is not None:
        lines = [f"{item['ms']:>8.0f}ms  {item['location']}  {item['what']}" for item in slowest]
        print(f"\nSlowest type-checks over {args.threshold}ms (top {args.top}):\n" + ('\n'.join(lines) or '  none'))
        markdown += (f"\n\nSlowest type-checks over {args.threshold}ms:\n\n| ms | Location | Declaration |\n| --- | --- | --- |\n"
                     + '\n'.join(f"| {item['ms']:.0f} | {item['location']} | {item['what']} |" for item in slowest))
    if args.json:
        args.json.parent.mkdir(parents=True, exist_ok=True)
        args.json.write_text(json.dumps(report, indent=2) + '\n')
    if args.markdown:
        args.markdown.parent.mkdir(parents=True, exist_ok=True)
        args.markdown.write_text(markdown + '\n')


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--work-dir', type=Path, default=ROOT / 'build/build-timing',
                        help='Owned folder under build/ for derived data, packages and logs (default: build/build-timing)')
    parser.add_argument('--arch', default='arm64' if platform.machine() == 'arm64' else 'x86_64')
    parser.add_argument('--repeat', type=int, default=1, help='Runs per warm step; the table reports median and min')
    parser.add_argument('--leaf', default=LEAF, help=f'Leaf Swift file to touch (default: {LEAF})')
    parser.add_argument('--core', default=CORE, help=f'Widely used Swift file to touch (default: {CORE})')
    parser.add_argument('--skip-cold', action='store_true', help='Reuse the existing derived data instead of a cold build')
    parser.add_argument('--type-check', action='store_true', help='Add an instrumented cold build listing slow type-checks')
    parser.add_argument('--threshold', type=int, default=200, help='Type-check warning threshold in ms (default: 200)')
    parser.add_argument('--top', type=int, default=15)
    parser.add_argument('--json', type=Path, help='Write the full report as JSON')
    parser.add_argument('--markdown', type=Path, help='Write the summary table as Markdown')
    args = parser.parse_args()
    if platform.system() != 'Darwin' or not shutil.which('xcodebuild'):
        raise SystemExit('build_timing.py needs macOS with full Xcode selected (see docs/build-from-source.md).')
    if args.repeat < 1:
        raise SystemExit('--repeat must be at least 1.')
    timer = Timer(args)
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(143))
    try:
        report = timer.measure()
    finally:
        timer.restore()
    print_report(report, args)


if __name__ == '__main__':
    main()
