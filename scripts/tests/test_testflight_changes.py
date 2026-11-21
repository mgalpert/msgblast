import os
from pathlib import Path
import subprocess
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / "testflight_changes.sh"


class TestFlightChangesTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.repo = Path(self.temp.name)
        self.git("init", "-q")
        self.git("config", "user.name", "TestFlight fixture")
        self.git("config", "user.email", "testflight@example.invalid")
        self.baseline = self.commit("README.md")
        self.mac = self.commit("msgblast/Core/MacOnly.swift")
        self.mobile = self.commit("msgblastMobile/Info.plist")
        self.later_mac = self.commit("msgblast/Core/LaterMacOnly.swift")
        self.protocol = self.commit("msgblast/RemoteProtocol/Frame.swift")
        gh = self.repo / "gh"
        gh.write_text(
            '#!/bin/bash\n'
            'case "$3" in\n'
            '  */deployments\\?*) printf "%s" "$DEPLOYMENTS" ;;\n'
            '  */2/statuses\\?*) printf "%s" "$DEPLOYMENT_2_SUCCESS" ;;\n'
            '  */1/statuses\\?*) printf "success" ;;\n'
            '  *) exit 1 ;;\n'
            'esac\n'
        )
        gh.chmod(0o755)

    def git(self, *args):
        return subprocess.check_output(["git", *args], cwd=self.repo, text=True).strip()

    def commit(self, name):
        file = self.repo / name
        file.parent.mkdir(parents=True, exist_ok=True)
        file.write_text("fixture\n")
        self.git("add", name)
        self.git("commit", "-qm", name)
        return self.git("rev-parse", "HEAD")

    def check_release(self, head, expected, deployments="", latest_success=""):
        output = self.repo / "github-output"
        output.write_text("")
        result = subprocess.run(
            ["bash", SCRIPT], cwd=self.repo, check=True, capture_output=True, text=True,
            env={**os.environ, "GITHUB_REPOSITORY": "fixture/msgblast", "GITHUB_SHA": head,
                 "TESTFLIGHT_BASE_SHA": self.baseline, "GITHUB_OUTPUT": str(output),
                 "PATH": f"{self.repo}{os.pathsep}{os.environ['PATH']}",
                 "DEPLOYMENTS": deployments, "DEPLOYMENT_2_SUCCESS": latest_success},
        )
        self.assertEqual(output.read_text(), f"changed={expected}\n", result.stdout)

    def test_mac_only_release_skips_upload(self):
        self.check_release(self.mac, "false")

    def test_mobile_change_triggers_upload(self):
        self.check_release(self.mobile, "true")

    def test_failed_upload_keeps_the_last_successful_baseline(self):
        self.check_release(self.later_mac, "true", f"2\t{self.mobile}\n1\t{self.baseline}")

    def test_successful_upload_consumes_the_mobile_change(self):
        self.check_release(self.later_mac, "false", f"2\t{self.mobile}", "success")

    def test_shared_protocol_change_triggers_upload(self):
        self.check_release(self.protocol, "true", f"2\t{self.mobile}", "success")
