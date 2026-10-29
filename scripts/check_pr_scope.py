#!/usr/bin/env python3
"""Check a PR's changed lines and declared paths; never execute head-revision code."""
import argparse
import fnmatch
import json
import re
import subprocess
from pathlib import Path


def git(*args):
    return subprocess.check_output(['git', *args]).decode('utf-8', errors='surrogateescape')


def approved_review(reviews, head, author, permissions):
    latest = {}
    for review in sorted(reviews, key=lambda item: item['id']):
        if review['state'] != 'COMMENTED':
            latest[review['user']['login']] = review
    return any(
        login != author and review['user']['type'] == 'User'
        and review['state'] == 'APPROVED' and review['commit_id'] == head
        and f'Size-exception: {head}' in (review.get('body') or '').splitlines()
        and permissions.get(login) in {'admin', 'maintain', 'write'}
        for login, review in latest.items()
    )


def github_exception(repo, number, head, author):
    def api(path):
        return json.loads(subprocess.check_output(['gh', 'api', path]))
    reviews = []
    page = 1
    while True:
        batch = api(f'repos/{repo}/pulls/{number}/reviews?per_page=100&page={page}')
        reviews.extend(batch)
        if len(batch) < 100:
            break
        page += 1
    logins = {r['user']['login'] for r in reviews if r['state'] == 'APPROVED'}
    permissions = {login: api(f'repos/{repo}/collaborators/{login}/permission')['permission']
                   for login in logins}
    return approved_review(reviews, head, author, permissions)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--base', required=True)
    parser.add_argument('--head', required=True)
    parser.add_argument('--event-file', type=Path, required=True)
    parser.add_argument('--repo', help='Check GitHub reviews for a size exception')
    parser.add_argument('--size-approved', action='store_true', help='Local fixture only; CI reads GitHub reviews')
    args = parser.parse_args()
    pr = json.loads(args.event_file.read_text())['pull_request']
    body = pr.get('body') or ''
    patterns = re.findall(r'^Scope: (\S+)\s*$', body, re.MULTILINE)
    base = git('merge-base', args.base, args.head).strip()
    records = git('diff', '--numstat', '-z', '--no-renames', base, args.head).split('\0')
    added = deleted = binary = new = changed_bytes = 0
    paths = []
    for record in filter(None, records):
        additions, deletions, path = record.split('\t', 2)
        paths.append(path)
        binary += additions == '-'
        if additions != '-':
            added += int(additions)
            deleted += int(deletions)
        exists = subprocess.run(['git', 'cat-file', '-e', f'{args.head}:{path}'], capture_output=True).returncode == 0
        if exists:
            changed_bytes += int(git('cat-file', '-s', f'{args.head}:{path}'))
            new += subprocess.run(['git', 'cat-file', '-e', f'{base}:{path}'], capture_output=True).returncode != 0
    total = added + deleted
    print(f'{total} changed lines ({added} added, {deleted} deleted); {len(paths)} files; '
          f'{new} new; {binary} binary; {changed_bytes} bytes in changed head files.')
    failures = []
    if total > 250:
        print('Advisory: exceeds 250 changed lines. Explain why this remains one reviewable change.')
    if total > 600:
        approved = args.size_approved
        if args.repo:
            approved = github_exception(args.repo, pr['number'], args.head, pr['user']['login'])
        if not approved:
            failures.append('Exceeds 600 lines: split or obtain a write-access human approval with Size-exception: <head SHA>, then rerun.')
    if not patterns:
        failures.append('Declare intended paths with one Scope: <path or glob> line per entry.')
    outside = [path for path in paths if not any(fnmatch.fnmatchcase(path, p) for p in patterns)]
    if outside:
        failures.append(f'{len(outside)} changed paths outside declared scope: ' + ', '.join(repr(p) for p in outside[:10]))
    for failure in failures:
        print('FAIL: ' + failure)
    if not failures:
        print('PASS: size and declared paths accepted; semantic scope still needs human review.')
    return bool(failures)


if __name__ == '__main__':
    raise SystemExit(main())
