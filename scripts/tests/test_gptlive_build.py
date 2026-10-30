"""Guard isolated packaging and preserve existing apps through replacement failures."""
from datetime import datetime, timedelta, timezone
from pathlib import Path
import plistlib
import sys
import tempfile
import unittest
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import build_gptlive as build


class GPTLiveBuildTests(unittest.TestCase):
    def test_build_names_include_timestamp_without_changing_saved_data_identity(self):
        first_time = datetime(2026, 10, 29, 10, 30, 1, tzinfo=timezone(timedelta(hours=-7), "PDT"))
        for name, base in build.VARIANTS.items():
            first = build.timestamped_variant(name, first_time)
            second = build.timestamped_variant(name, first_time + timedelta(seconds=1))
            self.assertIn("2026-10-29 10-30-01 PDT", first["app_name"])
            self.assertNotEqual(first["app_name"], second["app_name"])
            self.assertNotEqual(first["artifact_prefix"], second["artifact_prefix"])
            self.assertEqual(first["bundle_id"], base["bundle_id"])
            self.assertEqual(first["support_directory"], base["support_directory"])
            info = build.preview.configure_info({}, first, "a" * 40)
            self.assertEqual(info["CFBundleName"] + ".app", first["app_name"])
            self.assertEqual(info["CFBundleDisplayName"] + ".app", first["app_name"])
            self.assertNotEqual(first["app_name"], base["app_name"])

    def test_modes_have_distinct_identity_and_profile_with_updates_disabled(self):
        infos = [build.preview.configure_info({}, variant, "a" * 40)
                 for variant in build.VARIANTS.values()]
        self.assertEqual({item["CFBundleIdentifier"] for item in infos},
                         {"com.msgblast.gptlive", "com.msgblast.gptlive-demo"})
        self.assertEqual({item["msgblastSupportDirectory"] for item in infos},
                         {"msgblast-GPTLive", "msgblast-GPTLive-Demo"})
        self.assertFalse(infos[0]["msgblastDemo"])
        self.assertTrue(infos[1]["msgblastDemo"])
        for info in infos:
            self.assertTrue(info["msgblastDisableUpdates"])
            self.assertFalse(info["SUAutomaticallyUpdate"])
            self.assertEqual(info["SUFeedURL"], "")

    def test_staged_telemetry_is_disabled_without_removing_microphone_description(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            path = root / "msgblast/Info.plist"
            path.parent.mkdir()
            path.write_bytes(plistlib.dumps({"msgblastTelemetryEndpoint": "https://msgblast.app/api/telemetry",
                                             "NSMicrophoneUsageDescription": "Voice conversation"}))
            build.disable_telemetry(root)
            info = plistlib.loads(path.read_bytes())
            self.assertEqual(info["msgblastTelemetryEndpoint"], "")
            self.assertEqual(info["NSMicrophoneUsageDescription"], "Voice conversation")

    def test_existing_app_requires_explicit_replace_and_running_app_is_preserved(self):
        variant = build.VARIANTS["development"]
        with tempfile.TemporaryDirectory() as temporary:
            output = Path(temporary)
            app = output / variant["app_name"]
            app.mkdir()
            with self.assertRaisesRegex(RuntimeError, "--replace"):
                build.check_destination(output, variant, False)
            with mock.patch.object(build, "running_app", return_value=True):
                with self.assertRaisesRegex(RuntimeError, "running app has been preserved"):
                    build.check_destination(output, variant, True)
            self.assertTrue(app.is_dir())

    def test_failed_install_restores_previous_app_and_manifest(self):
        variant = build.VARIANTS["demo"]
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            output, staged = root / "output", root / "staged"
            output.mkdir()
            staged.mkdir()
            name = variant["app_name"]
            for directory, value in ((output, "old"), (staged, "new")):
                (directory / name).mkdir()
                (directory / name / "marker").write_text(value)
                (directory / "manifest.json").write_text(value)
            replace = build.os.replace

            def fail_manifest(source, destination):
                if source == staged / "manifest.json":
                    raise OSError("simulated install failure")
                replace(source, destination)

            with mock.patch.object(build, "running_app", return_value=False), \
                    mock.patch.object(build.os, "replace", side_effect=fail_manifest):
                with self.assertRaisesRegex(OSError, "simulated install failure"):
                    build.install_outputs(staged, output, variant, [name, "manifest.json"], True)
            self.assertEqual((output / name / "marker").read_text(), "old")
            self.assertEqual((output / "manifest.json").read_text(), "old")
            self.assertEqual((staged / name / "marker").read_text(), "new")

    def test_running_detection_matches_exact_bundle_path(self):
        app = Path("/tmp/GPTLive/dev - gptlive.app").resolve()
        with mock.patch.object(build.subprocess, "run") as run:
            run.return_value.stdout = "/tmp/other/dev - gptlive.app/Contents/MacOS/msgblast\n"
            self.assertFalse(build.running_app(app))
            run.return_value.stdout += str(app) + "/Contents/MacOS/msgblast --test\n"
            self.assertTrue(build.running_app(app))


if __name__ == "__main__":
    unittest.main()
