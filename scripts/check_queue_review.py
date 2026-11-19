#!/usr/bin/env python3
"""Pass a merge queue entry only if its pull request's exact head was independently reviewed.

"Independent model review" is a commit status the owner posts by hand on a pull
request's head after a different model reviews it. The merge queue asks for
every required check again on its own temporary commit, where nobody posts it,
so this reports the same name there after reading the status on the head.
"""
import argparse
import json
import re
import subprocess
import sys

CONTEXT = 'Independent model review'


def pull_number(head_ref, base_ref='main'):
    """GitHub names queue branches gh-readonly-queue/<base>/pr-<number>-<base sha>."""
    ref = head_ref.removeprefix('refs/heads/')
    match = re.fullmatch(rf'gh-readonly-queue/{re.escape(base_ref)}/pr-(\d+)-[0-9a-f]{{40}}', ref)
    if not match:
        raise ValueError(f'not a merge queue branch for {base_ref}: {head_ref!r}')
    return int(match.group(1))


def reviewed(statuses, head):
    """The newest status with the review's name decides, as it does on the pull request."""
    mine = [s for s in statuses if s.get('context') == CONTEXT]
    if not mine:
        return False, f'no "{CONTEXT}" status on {head}'
    latest = max(mine, key=lambda s: (s.get('created_at') or '', s.get('id') or 0))
    if latest.get('state') != 'success':
        return False, f'"{CONTEXT}" is {latest.get("state")} on {head}'
    return True, f'"{CONTEXT}" passed on {head}: {latest.get("description") or ""}'.rstrip(': ')


def group_pulls(commits, base_sha, head_sha):
    """Pull requests in a queue group, read from GitHub's merge commits on the first-parent chain.

    With merge groups larger than one, the branch name names only the last pull
    request, so every pull request between base and head is read from its merge
    commit. Anything else on that chain fails closed.
    """
    by_sha = {c['sha']: c for c in commits}
    numbers = []
    sha = head_sha
    while sha != base_sha:
        commit = by_sha.get(sha)
        if commit is None:
            raise ValueError(f'{sha} is not between the queue base and head')
        match = re.match(r'Merge pull request #(\d+) ', commit['commit']['message'])
        if not match or len(commit['parents']) != 2:
            raise ValueError(f'{sha[:7]} is not a pull request merge commit')
        numbers.append(int(match.group(1)))
        sha = commit['parents'][0]['sha']
    return numbers[::-1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--repo', required=True)
    parser.add_argument('--event-file', required=True)
    args = parser.parse_args()
    with open(args.event_file) as handle:
        group = json.load(handle)['merge_group']
    base = group['base_ref'].removeprefix('refs/heads/')
    last = pull_number(group['head_ref'], base)

    def api(path):
        return json.loads(subprocess.check_output(['gh', 'api', path]))

    compare = api(f"repos/{args.repo}/compare/{group['base_sha']}...{group['head_sha']}")
    numbers = group_pulls(compare['commits'], group['base_sha'], group['head_sha'])
    if not numbers or numbers[-1] != last:
        print(f'Queue branch names PR #{last}, but its merge commits name {numbers}.')
        return 1
    failed = False
    for number in numbers:
        head = api(f'repos/{args.repo}/pulls/{number}')['head']['sha']
        statuses = []
        page = 1
        while True:
            batch = api(f'repos/{args.repo}/commits/{head}/statuses?per_page=100&page={page}')
            statuses.extend(batch)
            if len(batch) < 100:
                break
            page += 1
        ok, message = reviewed(statuses, head)
        print(f'PR #{number}: {message}')
        failed = failed or not ok
    return 1 if failed else 0


if __name__ == '__main__':
    sys.exit(main())
