"""Remote orchestration fixtures: no SSH connections, Xcode, or desktop tests."""
import argparse
import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

SCRIPT = Path(__file__).resolve().parents[1] / "run_mac_checks.py"
spec = importlib.util.spec_from_file_location("remote_checks", SCRIPT)
remote = importlib.util.module_from_spec(spec)
spec.loader.exec_module(remote)


class RemoteChecksTests(unittest.TestCase):
    def test_versioned_or_relative_python_is_rejected_before_remote_work(self):
        for executable in ["python3.14", "/opt/homebrew/bin/python3.14", "../bin/python3"]:
            with self.subTest(executable=executable), tempfile.TemporaryDirectory() as temporary:
                args = self.args(Path(temporary) / "results")
                args.remote_python = executable
                with patch.object(remote, "revision", return_value="a" * 40), patch.object(remote, "prepare", side_effect=AssertionError("No remote work")):
                    with self.assertRaisesRegex(ValueError, "same interpreter"):
                        remote.run(args)

    def test_selected_python_preflights_the_remote_without_changing_profiles(self):
        probe = {"system": "Darwin", "name": "fixture-remote", "id": "remote-mac"}
        workspace = {"workspace": "/fixture/workspace", "xcode": "Xcode 27.0"}
        responses = [subprocess.CompletedProcess([], 0, json.dumps(value), "") for value in [probe, workspace]]
        with patch.object(remote.subprocess, "run", side_effect=responses), patch.object(remote, "ssh_command", side_effect=lambda host, argv: argv) as transport, patch.object(remote, "machine_id", return_value="local-mac"):
            result = remote.prepare("fixture-mac", "a" * 40, "/fixture/Xcode.app/Contents/Developer", "/opt/homebrew/bin/python3")
        self.assertEqual(result["workspace"], workspace["workspace"])
        self.assertEqual([call.args[1][0] for call in transport.call_args_list], ["/opt/homebrew/bin/python3"] * 2)

    def test_same_machine_is_rejected_before_workspace_or_test_creation(self):
        probe = subprocess.CompletedProcess([], 0, json.dumps({"system": "Darwin", "name": "fixture", "id": "same-mac"}), "")
        with patch.object(remote.subprocess, "run", return_value=probe) as transport, patch.object(remote, "machine_id", return_value="same-mac"):
            with self.assertRaisesRegex(RuntimeError, "this Mac"):
                remote.prepare("fixture-mac", "a" * 40, None)
        self.assertEqual(transport.call_count, 1, "Refusal must happen before remote workspace creation")

    def test_non_mac_target_is_rejected_without_local_fallback(self):
        probe = subprocess.CompletedProcess([], 0, json.dumps({"system": "Linux", "name": "fixture", "id": None}), "")
        with patch.object(remote.subprocess, "run", return_value=probe) as transport:
            with self.assertRaisesRegex(RuntimeError, "Mac"):
                remote.prepare("fixture-mac", "a" * 40, None)
        self.assertEqual(transport.call_count, 1)

    def test_ssh_errors_stop_without_starting_tests(self):
        with patch.object(remote.subprocess, "run", side_effect=subprocess.CalledProcessError(255, ["ssh"])) as transport:
            with self.assertRaises(subprocess.CalledProcessError):
                remote.prepare("fixture-mac", "a" * 40, None)
        self.assertEqual(transport.call_count, 1)

    def test_host_cannot_inject_options_or_shell_commands(self):
        for host in ["-oProxyCommand=evil", "mac;touch /tmp/evil", "user@mac $(id)"]:
            with self.subTest(host=host), self.assertRaises(ValueError):
                remote.ssh_command(host, ["true"])

    def test_ui_needs_explicit_remote_desktop_authorization(self):
        args = argparse.Namespace(host="fixture-mac", revision="HEAD", suite="ui", allow_remote_ui=False, timeout_seconds=5400, remote_python="python3")
        with patch.object(remote, "revision", return_value="a" * 40), patch.object(remote, "prepare", side_effect=AssertionError("No remote activity")):
            with self.assertRaisesRegex(ValueError, "allow-remote-ui"):
                remote.run(args)

    def test_dry_run_creates_no_workspace_or_connection(self):
        with tempfile.TemporaryDirectory() as temporary:
            output = Path(temporary) / "results"
            args = self.args(output, dry_run=True)
            with patch.object(remote, "revision", return_value="a" * 40), patch.object(remote, "prepare", side_effect=AssertionError("No SSH")), contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(remote.run(args), 0)
            self.assertFalse(output.exists())

    def test_committed_snapshot_runs_and_results_survive_success_or_failure(self):
        # Real git archive + tar + worker process, with SSH replaced by local subprocesses.
        # The tiny worker is fixture input; native tests are never launched here.
        cases = [
            (0, 0, "passed", 0),
            (7, 0, "failed", 7),
            (124, 0, "timed-out", 124),
            (0, 23, "retrieval-failed", 23),
            (7, 23, "failed", 7),
            (124, 23, "timed-out", 124),
            (0, "timeout", "interrupted-or-incomplete", 1),
            (7, "timeout", "failed", 7),
            (124, "timeout", "timed-out", 124),
        ]
        for exit_code, retrieval, expected_status, expected_exit in cases:
            with self.subTest(exit_code=exit_code, retrieval=retrieval), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary) / "source"
                root.mkdir()
                subprocess.run(["git", "init", "-q", str(root)], check=True)
                scripts = root / "scripts"
                scripts.mkdir()
                worker = scripts / "mac_checks.sh"
                ending = 'sleep 30' if exit_code == 124 else f'exit {exit_code}'
                worker.write_text(f'mkdir -p build/test-results\necho fixture-result > build/test-results/assertions.txt\necho "fixture worker result"\n{ending}\n')
                subprocess.run(["git", "add", "scripts/mac_checks.sh"], cwd=root, check=True)
                subprocess.run(["git", "-c", "user.name=Fixture", "-c", "user.email=fixture@example.test", "commit", "-qm", "Fixture source"], cwd=root, check=True)
                # Dirty source/private files must not be transported.
                worker.write_text('echo "UNCOMMITTED SHOULD NEVER RUN"\nexit 99\n')
                (root / "private-account.txt").write_text("Fixture private data")
                workspace = Path(temporary) / "remote"
                workspace.mkdir()
                target = {"workspace": str(workspace), "name": "fixture-mac", "xcode": "Fixture Xcode"}
                output = Path(temporary) / "results"
                def transport(host, arguments):
                    if arguments[0] == "env":
                        return ["bash", "-c", 'cd "$1"; shift; exec "$@"', "fixture", str(workspace), *arguments]
                    if arguments[:2] == ["tar", "-czf"] and retrieval == 23:
                        return [sys.executable, "-c", "raise SystemExit(23)"]
                    return arguments
                real_run = subprocess.run
                def run_command(arguments, **kwargs):
                    if arguments[:2] == ["tar", "-czf"] and retrieval == "timeout":
                        raise subprocess.TimeoutExpired(arguments, 120)
                    return real_run(arguments, **kwargs)
                with patch.object(remote, "ROOT", root), patch.object(remote, "prepare", return_value=target), patch.object(remote, "ssh_command", side_effect=transport), patch.object(remote.subprocess, "run", side_effect=run_command), contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
                    args = self.args(output)
                    if exit_code == 124:
                        args.timeout_seconds = 0.2
                    if retrieval == "timeout":
                        with patch.object(sys, "argv", [str(SCRIPT), "--host", "fixture-mac", "--suite", "core", "--output", str(output), "--timeout-seconds", "1"]):
                            self.assertEqual(remote.main(), expected_exit)
                    else:
                        self.assertEqual(remote.run(args), expected_exit)
                manifest = json.loads((output / "manifest.json").read_text())
                self.assertEqual(manifest["status"], expected_status)
                self.assertEqual(manifest["exit_code"], expected_exit)
                self.assertEqual(manifest["worker_exit_code"], exit_code)
                self.assertEqual(manifest["results_retrieved"], retrieval == 0)
                if retrieval != "timeout":
                    self.assertEqual(manifest["retrieval_exit_code"], retrieval)
                else:
                    self.assertIsNone(manifest["retrieval_exit_code"])
                    self.assertEqual(manifest["retrieval_error_type"], "TimeoutExpired")
                if retrieval == 0:
                    self.assertTrue((output / "results.tar.gz").stat().st_size)
                self.assertNotIn("UNCOMMITTED", (output / "run.log").read_text())
                self.assertFalse((workspace / "private-account.txt").exists())
                self.assertEqual((workspace / "build/test-results/assertions.txt").read_text(), "fixture-result\n")

    @staticmethod
    def args(output, dry_run=False):
        return argparse.Namespace(host="fixture-mac", revision="HEAD", suite="core", output=str(output), developer_dir=None, remote_python="python3", allow_remote_ui=False, dry_run=dry_run, timeout_seconds=5400)


class MacWorkerTests(unittest.TestCase):
    def test_web_harness_discovers_app_sources_without_ripgrep(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            scripts = root / "scripts"
            scripts.mkdir()
            harness = scripts / "test_web_comparisons.sh"
            harness.write_text((SCRIPT.parent / "test_web_comparisons.sh").read_text())
            app = root / "msgblast"
            (app / "App").mkdir(parents=True)
            (app / "Core").mkdir()
            (app / "Resources/WebAgentIcons").mkdir(parents=True)
            owner = app / "App/Owner.swift"
            owner.write_text("// Fixture app owner")
            excluded = app / "Core/Ignored.swift"
            excluded.write_text("// Already linked through the core framework")
            entry = app / "App/msgblastApp.swift"
            entry.write_text("@main\nenum msgblastMain {}\n@MainActor\nprivate final class AppStartup {}\n")
            derived = root / "derived"
            derived.mkdir()
            binary = root / "bin"
            binary.mkdir()
            (binary / "python3").symlink_to(sys.executable)
            compiler = binary / "xcrun"
            compiler.write_text('#!/bin/bash\nprintf "%s\\n" "$@" >> "$COMPILER_LOG"\noutput="${@: -1}"\nprintf "#!/bin/bash\\nexit 0\\n" > "$output"\nchmod 700 "$output"\n')
            compiler.chmod(0o700)
            command_log = root / "compiler.txt"
            env = {**os.environ, "PATH": str(binary) + ":/usr/bin:/bin", "COMPILER_LOG": str(command_log)}
            result = subprocess.run(["bash", str(harness), str(derived)], env=env, capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertNotIn("rg: command not found", result.stderr)
            sources = command_log.read_text().splitlines()
            self.assertIn(str(owner), sources, "Source discovery must pass app owners to the compiler")
            self.assertNotIn(str(excluded), sources)
            self.assertNotIn(str(entry), sources, "The fixture must use its own entry point")
            self.assertTrue(any(path.endswith("/app-support.swift") for path in sources))

    def test_suite_routing_failures_and_locks_without_native_tools(self):
        worker_source = (SCRIPT.parent / "mac_checks.sh").read_text()
        for suite in ["core", "controllers", "updater", "all", "ui", "empty-ui-run", "failed-ui-desktop", "failed-ui-verification", "failed-core", "locked"]:
            with self.subTest(suite=suite), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                scripts = root / "scripts"
                scripts.mkdir()
                worker = scripts / "mac_checks.sh"
                worker.write_text(worker_source)
                commands = root / "commands.txt"
                bin_path = root / "bin"
                bin_path.mkdir()
                xcode = bin_path / "xcodebuild"
                xcode.write_text('#!/bin/bash\necho "xcodebuild $*" >> "$COMMAND_LOG"\nif [[ "$1" == -version ]]; then echo "Xcode 27.0 fixture"; exit 0; fi\nexit "${XCODE_FIXTURE_EXIT:-0}"\n')
                xcode.chmod(0o700)
                python = bin_path / "python3"
                python.write_text('#!/bin/bash\necho "updater $*" >> "$COMMAND_LOG"\nif [[ "$1" == scripts/check_ui_results.py ]]; then exec "$UI_RESULT_PYTHON" "$UI_RESULT_CHECKER" "$2"; fi\n')
                python.chmod(0o700)
                xcrun = bin_path / "xcrun"
                xcrun.write_text('''#!/bin/bash
echo "summary $*" >> "$COMMAND_LOG"
if [[ "$UI_EMPTY_FIXTURE" == 1 ]]; then
  echo '{"result":"Passed","totalTestCount":0,"passedTests":0,"failedTests":0,"skippedTests":0,"expectedFailures":0}'
else
  echo '{"result":"Passed","totalTestCount":34,"passedTests":34,"failedTests":0,"skippedTests":0,"expectedFailures":0}'
fi
''')
                xcrun.chmod(0o700)
                swift = bin_path / "swift"
                swift.write_text('#!/bin/bash\necho "ui-desktop $*" >> "$COMMAND_LOG"\necho "UI desktop fixture"\nif [[ "$2" == --check-only ]]; then exit "${UI_VERIFICATION_FIXTURE_EXIT:-0}"; fi\nexit "${UI_DESKTOP_FIXTURE_EXIT:-0}"\n')
                swift.chmod(0o700)
                for fixture in ["web_comparisons", "configured_cli_conversations", "personal_agent_shutdown", "app_permissions"]:
                    (scripts / f"test_{fixture}.sh").write_text(f'echo "{fixture}" >> "$COMMAND_LOG"\n')
                env = {**os.environ, "HOME": str(root / "account"), "PATH": str(bin_path) + ":/usr/bin:/bin", "COMMAND_LOG": str(commands), "MSGBLAST_REMOTE_TEST_WORKER": "1"}
                env.update(UI_RESULT_PYTHON=sys.executable, UI_RESULT_CHECKER=str(SCRIPT.parent / "check_ui_results.py"), UI_EMPTY_FIXTURE="1" if suite == "empty-ui-run" else "0")
                lock = Path(env["HOME"]) / "Library/Caches/msgblast-tests/native.lock"
                if suite == "locked":
                    lock.mkdir(parents=True)
                if suite == "failed-core":
                    env["XCODE_FIXTURE_EXIT"] = "8"
                if suite == "failed-ui-desktop":
                    env["UI_DESKTOP_FIXTURE_EXIT"] = "3"
                if suite == "failed-ui-verification":
                    env["UI_VERIFICATION_FIXTURE_EXIT"] = "4"
                chosen = "core" if suite in ["failed-core", "locked"] else "ui" if suite in ["empty-ui-run", "failed-ui-desktop", "failed-ui-verification"] else suite
                result = subprocess.run(["bash", str(worker), chosen, "a" * 40], env=env, capture_output=True, text=True)
                recorded = commands.read_text() if commands.exists() else ""
                if suite == "locked":
                    self.assertEqual(result.returncode, 2)
                    self.assertEqual(recorded, "")
                    self.assertTrue(lock.exists(), "An active lock must remain owned by its existing run")
                    continue
                self.assertFalse(lock.exists(), "Completed and failed runs must release their own lock")
                if suite == "empty-ui-run":
                    self.assertEqual(result.returncode, 2, "Xcode success with zero UI tests must fail verification")
                    self.assertIn("total=0", result.stderr)
                    continue
                if suite in ["failed-ui-desktop", "failed-ui-verification"]:
                    self.assertEqual(result.returncode, 3 if suite == "failed-ui-desktop" else 4)
                    self.assertNotIn("xcodebuild -project", recorded, "Desktop preparation failure must stop before native tests")
                    self.assertIn("UI desktop fixture", (root / "build/test-results/ui-desktop.log").read_text())
                    self.assertEqual("--check-only" in recorded, suite == "failed-ui-verification")
                    continue
                self.assertEqual(result.returncode, 8 if suite == "failed-core" else 0)
                self.assertEqual("ui-desktop" in recorded, suite == "ui")
                self.assertIn("-only-testing:msgblastUITests" if suite == "ui" else "-only-testing:msgblastTests", recorded)
                for fixture in ["web_comparisons", "configured_cli_conversations", "personal_agent_shutdown", "app_permissions"]:
                    self.assertEqual(fixture in recorded, suite in ["controllers", "all"])
                self.assertEqual("updater scripts/test_updates.py" in recorded, suite in ["updater", "all"])
                self.assertEqual((root / "build/test-results/source-revision.txt").read_text().strip(), "a" * 40)

    def test_direct_worker_refuses_an_unrequested_local_run(self):
        env = {key: value for key, value in os.environ.items() if key not in {"CI", "MSGBLAST_REMOTE_TEST_WORKER"}}
        result = subprocess.run(["bash", str(SCRIPT.parent / "mac_checks.sh"), "core", "a" * 40], env=env, capture_output=True, text=True)
        self.assertEqual(result.returncode, 2)
        self.assertIn("no local tests were started", result.stderr)
