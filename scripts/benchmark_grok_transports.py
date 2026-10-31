#!/usr/bin/env python3
"""Run the real Grok workflow with both drivers against an isolated Electron fixture."""
import argparse
import json
import os
from pathlib import Path
import plistlib
import select
import shutil
import statistics
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
FIXTURE = ROOT / 'scripts/fixtures/agent-desktop'


def run(args, **kwargs):
    return subprocess.run([str(a) for a in args], check=True, **kwargs)


def query(binary, *args):
    value = json.loads(subprocess.check_output([str(binary), *args], text=True, timeout=30))
    if value.get('ok') is not True:
        raise RuntimeError('Agent Desktop observation failed')
    return value['data']


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--agent-desktop', required=True, type=Path)
    parser.add_argument('--cua-driver', required=True, type=Path)
    parser.add_argument('--electron-app', required=True, type=Path)
    parser.add_argument('--products', required=True, type=Path, help='Debug products containing msgblastCore.framework')
    parser.add_argument('--output', required=True, type=Path, help='New output directory')
    parser.add_argument('--driver', choices=['both', 'agent-desktop', 'cua'], default='both')
    parser.add_argument('--record', action='store_true', help='Record only the fixture window using ScreenCaptureKit')
    args = parser.parse_args()
    for name in ['agent_desktop', 'cua_driver', 'electron_app', 'products', 'output']:
        setattr(args, name, getattr(args, name).resolve())
    if query(args.agent_desktop, 'version')['version'] != '1.0.2':
        parser.error('This benchmark pins Agent Desktop 1.0.2')
    if subprocess.check_output([str(args.cua_driver), '--version'], text=True).strip() != 'cua-driver 0.38.0':
        parser.error('This benchmark pins CuaDriver 0.38.0')
    args.output.mkdir(parents=True, exist_ok=False)
    # Do not reuse or close another benchmark's running fixture.
    apps = query(args.agent_desktop, 'list-apps')['apps']
    if any(a.get('bundle_id') == 'com.msgblast.grok-transport-fixture' for a in apps):
        raise RuntimeError('A Grok Transport Fixture is already running; close that fixture first')
    app = args.output / 'Grok Transport Fixture.app'
    run(['ditto', args.electron_app, app])
    plist_path = app / 'Contents/Info.plist'
    info = plistlib.loads(plist_path.read_bytes())
    if info.get('CFBundleShortVersionString') != '45.2.1':
        raise RuntimeError('This benchmark pins Electron 45.2.1')
    info.update(CFBundleIdentifier='com.msgblast.grok-transport-fixture', CFBundleName='Grok Transport Fixture', CFBundleDisplayName='Grok Transport Fixture')
    plist_path.write_bytes(plistlib.dumps(info))
    resources = app / 'Contents/Resources/app'
    resources.mkdir()
    for name in ['fixture.html', 'main.cjs', 'package.json']:
        shutil.copyfile(FIXTURE / name, resources / name)
    run(['codesign', '--force', '--deep', '--sign', '-', app], stdout=subprocess.DEVNULL)
    harness = args.output / 'benchmark'
    run(['xcrun', 'swiftc', '-parse-as-library', '-F', args.products, '-framework', 'msgblastCore', '-Xlinker', '-rpath', '-Xlinker', args.products, FIXTURE / 'Benchmark.swift', '-o', harness])
    recorder_binary = args.output / 'record-window'
    if args.record:
        run(['xcrun', 'swiftc', '-parse-as-library', FIXTURE / 'RecordWindow.swift', '-o', recorder_binary])
    fixture = daemon = recorder = None
    try:
        with open(args.output / 'fixture.log', 'w') as log, tempfile.TemporaryDirectory(prefix='grok-transport-runtime-') as directory:
            fixture = subprocess.Popen([str(app / 'Contents/MacOS' / info['CFBundleExecutable'])], stdout=log, stderr=log)
            deadline = time.monotonic() + 30
            while True:
                if fixture.poll() is not None or time.monotonic() >= deadline:
                    raise RuntimeError('Fixture did not become ready')
                try:
                    windows = query(args.agent_desktop, 'list-windows', '--app', 'Grok Transport Fixture')
                    candidates = [w for w in windows if w['pid'] == fixture.pid and w.get('accessible')]
                    if len(candidates) == 1:
                        window = candidates[0]
                        snapshot = query(args.agent_desktop, 'snapshot', '--app', 'Grok Transport Fixture', '--window-id', window['id'], '--max-depth', '40')
                        if snapshot.get('complete') and 'Prompt' in json.dumps(snapshot):
                            break
                except (subprocess.SubprocessError, RuntimeError):
                    pass
                time.sleep(.1)
            socket = str(Path(directory) / 'cua.sock')
            daemon = subprocess.Popen([str(args.cua_driver), 'serve', '--embedded', '--socket', socket, '--parent-liveness-stdio'], stdin=subprocess.PIPE, stdout=log, stderr=log)
            deadline = time.monotonic() + 10
            while not os.path.exists(socket):
                if daemon.poll() is not None or time.monotonic() >= deadline:
                    raise RuntimeError('Private Cua runtime failed to start')
                time.sleep(.05)
            query(args.agent_desktop, 'screenshot', str(args.output / 'before.png'), '--app', 'Grok Transport Fixture', '--window-id', window['id'])
            if args.record:
                recorder = subprocess.Popen([str(recorder_binary), window['id'][2:], str(args.output / 'workflow.mp4')], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=log)
                if not select.select([recorder.stdout], [], [], 15)[0] or recorder.stdout.readline().strip() != b'READY':
                    raise RuntimeError('Fixture-only recording did not start')
            with open(args.output / 'results.txt', 'w') as results:
                result = subprocess.run([str(harness), str(args.agent_desktop), str(args.cua_driver), str(fixture.pid), socket, args.driver], stdout=results, stderr=subprocess.STDOUT, timeout=300)
            query(args.agent_desktop, 'screenshot', str(args.output / 'after.png'), '--app', 'Grok Transport Fixture', '--window-id', window['id'])
            rows = (args.output / 'results.txt').read_text()
            summary = {'source_sha': subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip(), 'dirty_source': bool(subprocess.check_output(['git', 'status', '--porcelain'], cwd=ROOT, text=True)), 'exit_code': result.returncode, 'recorded': args.record, 'selected_driver': args.driver, 'limits': 'Electron 45.2.1 simulated provider. Only app discovery is injected; real accessibility, input, production workflow and receipts. No live requests. Poll 100 ms, stable reply 300 ms; five samples per driver, Cua first. Includes CLI startup and safety checks; excludes model latency.', 'drivers': {}}
            for driver in ['cua-0.38.0', 'agent-desktop-1.0.2']:
                if args.driver != 'both' and not driver.startswith(args.driver):
                    continue
                values = [float(line.split()[3]) for line in rows.splitlines() if line.startswith('TIMING ' + driver + ' ')]
                summary['drivers'][driver] = {'samples_seconds': values, 'median_seconds': statistics.median(values) if values else None}
            (args.output / 'summary.json').write_text(json.dumps(summary, indent=2) + '\n')
            print(rows, end='')
            print(json.dumps(summary, indent=2))
            if result.returncode:
                raise RuntimeError('Workflow benchmark failed; inspect results.txt')
    finally:
        if recorder:
            recorder.stdin.close()
            try:
                recorder.wait(timeout=15)
            except subprocess.TimeoutExpired:
                recorder.terminate()
                recorder.wait(timeout=10)
        if daemon:
            daemon.stdin.close()
            try:
                daemon.wait(timeout=10)
            except subprocess.TimeoutExpired:
                daemon.terminate()
                daemon.wait(timeout=10)
        if fixture:
            fixture.terminate()
            fixture.wait(timeout=10)


if __name__ == '__main__':
    main()
