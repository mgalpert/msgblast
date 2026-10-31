#!/usr/bin/env python3
"""Read-only, alternating same-window benchmark. Stores counts/timings, never UI text."""
import argparse
import json
import os
from pathlib import Path
import statistics
import subprocess
import tempfile
import time


def invoke(command):
    start = time.perf_counter()
    result = subprocess.run(command, capture_output=True, text=True, timeout=35)
    elapsed = (time.perf_counter() - start) * 1000
    if result.returncode:
        raise RuntimeError(f"{command[0]} exited {result.returncode}; no private output recorded")
    return json.loads(result.stdout), elapsed


def nodes(root):
    yield root
    for child in root.get('children', []):
        yield from nodes(child)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--agent-desktop', required=True)
    parser.add_argument('--cua-driver', required=True)
    parser.add_argument('--app', default='Grok Bot')
    parser.add_argument('--samples', type=int, default=15)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    if args.samples < 2:
        parser.error('at least two samples required')
    windows, _ = invoke([args.agent_desktop, 'list-windows', '--app', args.app])
    candidates = [w for w in windows['data'] if w.get('accessible') and w.get('bounds', {}).get('width', 0) >= 400 and w.get('bounds', {}).get('height', 0) >= 400]
    if len(candidates) != 1:
        raise RuntimeError('Requires one unambiguous accessible main window')
    window = candidates[0]
    pid, wid = window['pid'], window['id']
    results = {'limits': 'Read-only CLI observations; no screenshots, input, live sends, provider latency, or model cost. CLI startup included. Different tree representations; count is not equivalent work.', 'samples': []}
    results['agent_version'] = invoke([args.agent_desktop, 'version'])[0]['data']['version']
    results['cua_version'] = subprocess.check_output([args.cua_driver, '--version'], text=True).strip()
    with tempfile.TemporaryDirectory(prefix='msgblast-observation-') as directory:
        socket = str(Path(directory) / 'driver.sock')
        with open(Path(directory) / 'daemon.log', 'w') as log:
            daemon = subprocess.Popen([args.cua_driver, 'serve', '--embedded', '--socket', socket, '--parent-liveness-stdio'], stdin=subprocess.PIPE, stdout=log, stderr=log)
            try:
                deadline = time.monotonic() + 10
                while not os.path.exists(socket):
                    if daemon.poll() is not None or time.monotonic() > deadline:
                        raise RuntimeError('Private Cua runtime failed to start')
                    time.sleep(.05)
                commands = {
                    'agent-desktop': [args.agent_desktop, 'snapshot', '--app', args.app, '--window-id', wid, '--max-depth', '40', '--include-bounds', '--timeout-ms', '10000', '--session', 'msgblast-read-benchmark'],
                    'cua-driver': [args.cua_driver, 'call', 'get_window_state', json.dumps({'pid': pid, 'window_id': int(wid.removeprefix('w-')), 'tree_format': 'elements', 'include_screenshot': False, 'max_depth': 40, 'max_elements': 5000, 'timeout_ms': 10000}), '--embedded', '--socket', socket],
                }
                for iteration in range(args.samples + 1):
                    for name in (list(commands) if iteration % 2 == 0 else list(reversed(commands))):
                        value, elapsed = invoke(commands[name])
                        if name == 'agent-desktop':
                            data = value.get('data', {})
                            tree = list(nodes(data.get('tree', {})))
                            valid = value.get('ok') is True and data.get('complete') is True and data.get('window', {}).get('id') == wid
                            composer = sum(n.get('role') == 'textfield' and n.get('name') == 'Prompt' for n in tree)
                            count = len(tree)
                        else:
                            valid = value.get('pid') == pid and value.get('window_id') == int(wid[2:]) and value.get('truncated') is not True and value.get('degraded') is not True and value.get('total_element_count') == value.get('returned_element_count')
                            tree = value.get('elements', [])
                            composer = sum(n.get('role') in ['AXTextArea', 'AXTextField'] and n.get('label') == 'Prompt' for n in tree)
                            count = len(tree)
                        results['samples'].append({'driver': name, 'warmup': iteration == 0, 'milliseconds': round(elapsed, 3), 'complete': valid, 'elements': count, 'composers': composer})
            finally:
                daemon.stdin.close()
                try:
                    daemon.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    daemon.terminate()
                    daemon.wait(timeout=10)
    results['summary'] = {}
    for name in ['agent-desktop', 'cua-driver']:
        rows = [r for r in results['samples'] if r['driver'] == name and not r['warmup']]
        times = sorted(r['milliseconds'] for r in rows)
        results['summary'][name] = {'n': len(rows), 'median_ms': statistics.median(times), 'p95_ms': times[max(0, __import__('math').ceil(.95 * len(times)) - 1)], 'accepted_with_one_composer': sum(r['complete'] and r['composers'] == 1 for r in rows)}
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(results, indent=2) + '\n')
    print(json.dumps(results['summary'], indent=2))


if __name__ == '__main__':
    main()
