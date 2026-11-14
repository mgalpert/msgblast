#!/bin/bash
# Job-started hook for a self-hosted msgblast Studio runner.
# Install a copy outside the repository and point ACTIONS_RUNNER_HOOK_JOB_STARTED
# at it (see docs/studio-runner.md). A pull request can edit a workflow's runs-on,
# but it cannot edit this installed copy, so this is the real guard.
# It allows only pushes to main, manual runs, and pull requests whose branch is
# in this repository. Everything else fails before any step runs.
set -euo pipefail
exec /usr/bin/python3 -I - "${MSGBLAST_STUDIO_REPOSITORY:-mgalpert/msgblast}" <<'PY'
import json
import os
import sys

expected = sys.argv[1]
repository = os.environ.get("GITHUB_REPOSITORY", "")
event_name = os.environ.get("GITHUB_EVENT_NAME", "")
ref = os.environ.get("GITHUB_REF", "")


def refuse(reason):
    print("Studio runner refused this job: " + reason, file=sys.stderr)
    raise SystemExit(1)


if repository != expected:
    refuse("repository " + repr(repository) + " is not " + expected)
if event_name == "push":
    if ref != "refs/heads/main":
        refuse("pushes run here only for main, not " + repr(ref))
elif event_name == "workflow_dispatch":
    pass
elif event_name == "pull_request":
    try:
        with open(os.environ["GITHUB_EVENT_PATH"]) as handle:
            event = json.load(handle)
        head_repository = event["pull_request"]["head"]["repo"]["full_name"]
    except (KeyError, TypeError, OSError, ValueError):
        refuse("could not read the pull request's head repository")
    if head_repository != expected:
        refuse("pull requests from forks run on GitHub-hosted runners")
else:
    refuse("event " + repr(event_name) + " is not allowed")
print("Studio runner accepted " + event_name + " for " + repository)
PY
