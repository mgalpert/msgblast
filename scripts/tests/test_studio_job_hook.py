"""The Studio runner's job-started hook admits only trusted events."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
HOOK = ROOT / "scripts/ci/studio-job-started.sh"
REPO = "contains-studio/msgblast"


def run(event_name, ref="refs/heads/feature", head_repo=REPO, repository=REPO, expected=None,
        event_text=None, event_file=True):
    with tempfile.TemporaryDirectory() as directory:
        event_path = Path(directory) / "event.json"
        event = {"pull_request": {"head": {"repo": {"full_name": head_repo}}}} if head_repo else {}
        event_path.write_text(json.dumps(event) if event_text is None else event_text)
        env = dict(os.environ, GITHUB_REPOSITORY=repository, GITHUB_EVENT_NAME=event_name,
                   GITHUB_REF=ref, GITHUB_EVENT_PATH=str(event_path))
        if not event_file:
            env.pop("GITHUB_EVENT_PATH")
        env.pop("MSGBLAST_STUDIO_REPOSITORY", None)
        if expected:
            env["MSGBLAST_STUDIO_REPOSITORY"] = expected
        return subprocess.run(["bash", str(HOOK)], env=env, capture_output=True, text=True).returncode


@unittest.skipUnless(Path("/usr/bin/python3").exists(), "hook uses /usr/bin/python3")
class StudioJobHookTests(unittest.TestCase):
    def test_allows_trusted_events(self):
        self.assertEqual(run("push", ref="refs/heads/main"), 0)
        self.assertEqual(run("workflow_dispatch"), 0)
        self.assertEqual(run("pull_request"), 0)
        self.assertEqual(run("merge_group", ref="refs/heads/gh-readonly-queue/main/pr-7-abc"), 0)

    def test_refuses_forks_other_events_and_other_repositories(self):
        self.assertEqual(run("pull_request", head_repo="someone/msgblast"), 1)
        self.assertEqual(run("pull_request", head_repo=None), 1)
        self.assertEqual(run("pull_request_target"), 1)
        self.assertEqual(run("push", ref="refs/heads/feature"), 1)
        self.assertEqual(run("push", ref="refs/tags/v1"), 1)
        self.assertEqual(run("issue_comment"), 1)
        self.assertEqual(run("merge_group", ref="refs/heads/gh-readonly-queue/release/pr-7-abc"), 1)
        self.assertEqual(run("workflow_dispatch", repository="someone/msgblast"), 1)

    def test_refuses_pull_requests_it_cannot_read(self):
        self.assertEqual(run("pull_request", event_file=False), 1)
        self.assertEqual(run("pull_request", event_text="{not json"), 1)
        self.assertEqual(run("pull_request", event_text='{"pull_request": {"head": {"repo": null}}}'), 1)
        self.assertEqual(run("pull_request", event_text='{"pull_request": null}'), 1)

    def test_defaults_to_the_organization_repository(self):
        old = "mgalpert/msgblast"
        self.assertEqual(run("push", ref="refs/heads/main", repository=old), 1)
        self.assertEqual(run("pull_request", repository=old, head_repo=old), 1)

    def test_runner_environment_can_name_another_repository(self):
        moved = "someone-else/msgblast"
        self.assertEqual(run("push", ref="refs/heads/main", repository=moved), 1)
        self.assertEqual(run("push", ref="refs/heads/main", repository=moved, head_repo=moved,
                             expected=moved), 0)
        self.assertEqual(run("pull_request", repository=moved, head_repo=REPO, expected=moved), 1)

if __name__ == "__main__":
    unittest.main()
