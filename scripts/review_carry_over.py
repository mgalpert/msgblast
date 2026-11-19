#!/usr/bin/env python3
"""Decide whether a review of one commit still covers a later pull request head.

A review or evidence of commit R carries over to head H only when H adds
nothing but clean merges of the base branch:

1. R is H, or every commit on H's first-parent chain down to R is a merge
   commit whose second parent is already on the base branch.
2. Merging R with the newest of those base commits, with no conflicts, gives
   exactly H's tree. So nobody edited files while resolving a merge.

Anything else, including a rebase, a conflict fix or a new commit of any kind,
returns False and needs a new review. The check only reads Git objects; it
never runs code from the pull request.
"""
import argparse
import subprocess
import sys


def git(repo, *args, check=True):
    result = subprocess.run(["git", *args], cwd=repo, text=True, capture_output=True)
    if check and result.returncode != 0:
        raise RuntimeError(f"git {' '.join(args)} failed: {result.stderr.strip()}")
    return result


def resolve(repo, ref):
    return git(repo, "rev-parse", "--verify", f"{ref}^{{commit}}").stdout.strip()


def is_ancestor(repo, older, newer):
    return git(repo, "merge-base", "--is-ancestor", older, newer, check=False).returncode == 0


def parents(repo, commit):
    return git(repo, "rev-list", "--parents", "-n", "1", commit).stdout.split()[1:]


def carried_over(repo, reviewed, head, base_ref):
    """Return (covered, reason) for a review of `reviewed` at `head`."""
    try:
        reviewed = resolve(repo, reviewed)
        head = resolve(repo, head)
        base = resolve(repo, base_ref)
    except RuntimeError as error:
        return False, str(error)
    if reviewed == head:
        return True, "reviewed commit is the head"
    if not is_ancestor(repo, reviewed, head):
        return False, f"{reviewed[:7]} is not an ancestor of {head[:7]}"
    merged_base = None
    commit = head
    while commit != reviewed:
        commit_parents = parents(repo, commit)
        if len(commit_parents) != 2:
            return False, f"{commit[:7]} is not a merge of the base branch"
        first, second = commit_parents
        if not is_ancestor(repo, second, base):
            return False, f"{commit[:7]} merges {second[:7]}, which is not on {base_ref}"
        if merged_base is None:
            merged_base = second
        if not is_ancestor(repo, reviewed, first):
            return False, f"{commit[:7]} does not keep the reviewed commit as its first parent"
        commit = first
    merge = git(repo, "merge-tree", "--write-tree", reviewed, merged_base, check=False)
    if merge.returncode != 0:
        return False, f"merging {reviewed[:7]} with {merged_base[:7]} conflicts"
    expected_tree = merge.stdout.splitlines()[0].strip()
    head_tree = git(repo, "rev-parse", f"{head}^{{tree}}").stdout.strip()
    if expected_tree != head_tree:
        return False, f"{head[:7]} changes files beyond a clean merge of {merged_base[:7]}"
    return True, f"only clean merges of {base_ref} since {reviewed[:7]}"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", default=".")
    parser.add_argument("--reviewed", required=True)
    parser.add_argument("--head", required=True)
    parser.add_argument("--base-ref", required=True)
    args = parser.parse_args()
    covered, reason = carried_over(args.repo, args.reviewed, args.head, args.base_ref)
    print(reason)
    return 0 if covered else 1


if __name__ == "__main__":
    sys.exit(main())
