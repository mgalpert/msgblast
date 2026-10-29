#!/usr/bin/env python3
"""Enforce 6 KiB per instruction file and 24 KiB across tracked instructions."""
import argparse
from pathlib import PurePosixPath
import subprocess


def check(head):
    entries = subprocess.check_output(['git', 'ls-tree', '-rlz', head]).split(b'\0')
    total = count = failures = 0
    for entry in filter(None, entries):
        metadata, raw_path = entry.split(b'\t', 1)
        path = raw_path.decode('utf-8', errors='replace')
        if PurePosixPath(path).name not in {'AGENTS.md', 'CLAUDE.md'} and not path.startswith('.cursor/rules/'):
            continue
        mode, kind, oid, size = metadata.split()
        count += 1
        if kind != b'blob' or mode != b'100644':
            failures += 1
            if failures <= 10:
                print(f'FAIL: instruction must be a regular non-executable file: {path!r}'[:400])
            continue
        total += int(size)
        if int(size) > 6144:
            failures += 1
            if failures <= 10:
                print(f'FAIL: {path!r} is {int(size)} bytes; limit 6144.'[:400])
    if total > 24576:
        print('FAIL: aggregate instruction budget exceeds 24576 bytes.')
        failures += 1
    print(f'{count} instruction files; {total}/24576 bytes; {failures} failures.')
    return bool(failures)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--head', default='HEAD')
    raise SystemExit(check(parser.parse_args().head))
