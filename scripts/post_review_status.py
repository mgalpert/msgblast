#!/usr/bin/env python3
"""Post the "Independent model review" status from a valid review receipt.

The pull request body names the receipt with one line:

    Review-receipt: <branch>:<path>

The receipt is a JSON file on a branch of this repository, never of a fork.
It must name this pull request, the reviewed commit, a reviewer model that
wrote none of the code, an approve verdict and no BLOCKER or MAJOR finding.
See docs/review-guardrails.md for the full format.

The status is posted on the head only when the receipt covers it: the receipt
reviewed the head itself, or the head adds nothing but clean merges of the
base branch (scripts/review_carry_over.py). Otherwise nothing is posted, so a
missing review still blocks the merge. It posts only when the head has no
status of this name yet, so it never replaces one the owner set by hand,
including a failure or pending posted to block a head.
"""
import argparse
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import urllib.request

sys.path.insert(0, str(Path(__file__).resolve().parent))
from review_carry_over import carried_over  # noqa: E402

CONTEXT = "Independent model review"
RECEIPT_LINE = re.compile(r"(?m)^Review-receipt:[ \t]*([A-Za-z0-9._/-]+):([A-Za-z0-9._/-]+\.json)[ \t]*$")
SHA = re.compile(r"^[0-9a-f]{40}$")
BLOCKING = {"BLOCKER", "MAJOR"}


def receipt_reference(body):
    """Return (branch, path) from the last Review-receipt line, or None."""
    matches = RECEIPT_LINE.findall(body or "")
    if not matches:
        return None
    branch, path = matches[-1]
    if branch.startswith(("-", "/")) or ".." in branch or path.startswith("/") or ".." in path:
        return None
    return branch, path


def receipt_problems(receipt, pr_number):
    """List why a parsed receipt cannot approve pull request `pr_number`."""
    if not isinstance(receipt, dict):
        return ["Receipt is not a JSON object."]
    errors = []
    if receipt.get("pr") != pr_number:
        errors.append(f"Receipt is for PR {receipt.get('pr')!r}, not {pr_number}.")
    if not SHA.match(str(receipt.get("reviewed_head", ""))):
        errors.append("reviewed_head must be a full 40-character commit SHA.")
    if receipt.get("verdict") != "approve":
        errors.append(f"Verdict is {receipt.get('verdict')!r}, not 'approve'.")
    reviewer = receipt.get("reviewer_model")
    authors = receipt.get("author_models")
    if not isinstance(reviewer, str) or not reviewer.strip():
        errors.append("reviewer_model must name the reviewing model.")
    if not isinstance(authors, list) or not authors or not all(isinstance(a, str) and a.strip() for a in authors):
        errors.append("author_models must list every model that wrote the change.")
    elif isinstance(reviewer, str) and reviewer.strip().lower() in {a.strip().lower() for a in authors}:
        errors.append("The reviewer model also wrote the change; an author-only review cannot pass.")
    findings = receipt.get("findings", [])
    if not isinstance(findings, list):
        errors.append("findings must be a list.")
    else:
        blocking = [f for f in findings if isinstance(f, dict) and str(f.get("severity", "")).upper() in BLOCKING]
        if blocking:
            errors.append(f"Receipt still has {len(blocking)} BLOCKER or MAJOR finding(s).")
    return errors


def git(repo, *args):
    return subprocess.run(["git", *args], cwd=repo, text=True, capture_output=True, check=True).stdout


def read_receipt(repo, branch, path):
    """Fetch the receipt branch of this repository and return (commit, parsed JSON)."""
    git(repo, "fetch", "--no-tags", "--quiet", "origin", f"+refs/heads/{branch}:refs/review-receipts/tip")
    commit = git(repo, "rev-parse", "refs/review-receipts/tip").strip()
    return commit, json.loads(git(repo, "show", f"{commit}:{path}"))


def api(token, method, url, payload=None):
    data = json.dumps(payload).encode() if payload is not None else None
    request = urllib.request.Request(url, data=data, method=method, headers={
        "Authorization": f"Bearer {token}",
        "Accept": "application/vnd.github+json",
        "X-GitHub-Api-Version": "2022-11-28",
    })
    with urllib.request.urlopen(request, timeout=30) as response:
        return json.load(response)


def existing_review_status(token, repository, head):
    """Return the newest review status on this head, or None when there is none."""
    statuses = api(token, "GET", f"https://api.github.com/repos/{repository}/commits/{head}/statuses?per_page=100")
    for status in statuses:  # newest first
        if status.get("context") == CONTEXT:
            return status
    return None


def decide(repo, event, base_ref):
    """Return (status payload or None, explanation) for this pull_request_target event."""
    pull_request = event["pull_request"]
    head = pull_request["head"]["sha"]
    reference = receipt_reference(pull_request.get("body") or "")
    if not reference:
        return None, "No 'Review-receipt: <branch>:<path>' line in the description."
    branch, path = reference
    try:
        receipt_commit, receipt = read_receipt(repo, branch, path)
    except (subprocess.CalledProcessError, json.JSONDecodeError) as error:
        return None, f"Could not read {path} on {branch}: {error}"
    errors = receipt_problems(receipt, pull_request["number"])
    if errors:
        return None, " ".join(errors)
    reviewed = receipt["reviewed_head"]
    covered, reason = carried_over(repo, reviewed, head, base_ref)
    if not covered:
        return None, f"Receipt reviewed {reviewed[:7]}, which does not cover {head[:7]}: {reason}."
    if reviewed == head:
        description = "Independent review of exact head: approve"
    else:
        description = f"Review of {reviewed[:7]} carried over: only clean merges of the base since"
    repository = event["repository"]["full_name"]
    return {
        "state": "success",
        "context": CONTEXT,
        "description": description[:140],
        "target_url": f"https://raw.githubusercontent.com/{repository}/{receipt_commit}/{path}",
    }, description


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--event-file", required=True)
    parser.add_argument("--repo-dir", default=".")
    parser.add_argument("--base-ref", required=True, help="for example origin/main")
    parser.add_argument("--token-env", default="GH_TOKEN")
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()
    event = json.loads(Path(args.event_file).read_text())
    payload, explanation = decide(args.repo_dir, event, args.base_ref)
    print(explanation)
    if payload is None or args.dry_run:
        return 0
    token = os.environ[args.token_env]
    repository = event["repository"]["full_name"]
    head = event["pull_request"]["head"]["sha"]
    existing = existing_review_status(token, repository, head)
    if existing is not None:
        # Never replace a status someone already set on this head, above all a
        # failure or pending the owner posted to block it.
        print(f"A '{CONTEXT}' status ({existing.get('state')}) is already on this head; nothing posted.")
        return 0
    api(token, "POST", f"https://api.github.com/repos/{repository}/statuses/{head}", payload)
    print(f"Posted '{CONTEXT}' success on {head}.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
