#!/usr/bin/env python3
"""Keep full command output on disk; expose at most 100 KiB plus a short notice."""
import argparse
from pathlib import Path
import subprocess
import sys


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--log', type=Path, required=True)
    parser.add_argument('command', nargs=argparse.REMAINDER)
    args = parser.parse_args()
    command = args.command[1:] if args.command[:1] == ['--'] else args.command
    if not command:
        parser.error('a command is required after --')
    shown = total = 0
    args.log.parent.mkdir(parents=True, exist_ok=True)
    with args.log.open('xb') as log, subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT) as process:
        try:
            while chunk := process.stdout.read1(8192):
                log.write(chunk)
                total += len(chunk)
                visible = chunk[:max(0, 102400 - shown)]
                sys.stdout.buffer.write(visible)
                sys.stdout.buffer.flush()
                shown += len(visible)
            code = process.wait()
        except KeyboardInterrupt:
            process.terminate()
            raise
    if total > shown:
        print(f'\n[output truncated: {total} bytes; full log {str(args.log)!r:.200}; exit {code}]')
    return code if code >= 0 else 128 - code


if __name__ == '__main__':
    raise SystemExit(main())
