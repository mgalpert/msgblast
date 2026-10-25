"""Release preparation tests use synthetic artifacts and never invoke Apple tools."""
import base64
import importlib.util
import contextlib
import io
from pathlib import Path
import plistlib
import shutil
import tempfile
import unittest
from unittest.mock import patch


SCRIPT = Path(__file__).resolve().parents[1] / "release.py"
spec = importlib.util.spec_from_file_location("release", SCRIPT)
release = importlib.util.module_from_spec(spec)
spec.loader.exec_module(release)


class ReleaseTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.notes = self.root / "notes.md"
        self.notes.write_text("# Version 0.1.0\n\n- Native updates.\n")
        self.key = base64.b64encode(bytes(range(32))).decode()
        self.signature = base64.b64encode(bytes(range(64))).decode()
        self.args = [
            "--version", "0.1.0", "--build", "2", "--previous-build", "1",
            "--identity", "Developer ID Application: Example (ABCDEFGHIJ)",
            "--team-id", "ABCDEFGHIJ", "--notary-profile", "example-notary",
            "--feed-url", "https://updates.example.com/appcast.xml",
            "--download-url-prefix", "https://updates.example.com/downloads/",
            "--public-key", self.key, "--sparkle-bin", str(self.root / "sparkle/bin"),
            "--release-notes", str(self.notes), "--output", str(self.root / "output"),
        ]

    def options(self, replacement=None):
        args = list(self.args)
        for flag, value in (replacement or {}).items():
            args[args.index(flag) + 1] = value
        return release.parse_args(args)

    def adhoc_args(self):
        args = list(self.args)
        for flag in ("--identity", "--team-id", "--notary-profile"):
            index = args.index(flag)
            del args[index:index + 2]
        return args + ["--signing-mode", "ad-hoc"]

    def test_notarization_reads_only_the_selected_temporary_keychain(self):
        keychain = self.root / "signing.keychain-db"
        options = release.parse_args(self.args + ["--notary-keychain", str(keychain)])
        commands = release.commands_by_step(options)
        for step in ("notary_credentials", "notarize"):
            arguments = commands[step]
            self.assertEqual(arguments[arguments.index("--keychain") + 1], str(keychain.resolve()))
            self.assertNotIn("--password", arguments)
            self.assertNotIn("--key", arguments)

    def test_release_rejects_development_artwork_before_building(self):
        saved = self.root / "output/app-icons/msgblast.icon"
        resource = self.root / "msgblast/AppIcon.icon"
        shutil.copytree(release.ROOT / "output/app-icons/msgblast.icon", saved)
        shutil.copytree(release.ROOT / "output/app-icons/msgblast-dev.icon", resource)
        with self.assertRaisesRegex(release.ReleaseError, "green production"):
            release.validate_production_icon(self.root)
        shutil.rmtree(resource)
        shutil.copytree(saved, resource)
        release.validate_production_icon(self.root)
        next((resource / "Assets").iterdir()).write_bytes(b"wrong artwork")
        with self.assertRaisesRegex(release.ReleaseError, "green production"):
            release.validate_production_icon(self.root)

    def test_adhoc_dry_run_needs_no_apple_credentials_or_key_file_access(self):
        private = self.root / "not-provisioned-yet.key"
        with patch.object(release, "run", side_effect=AssertionError("No commands")), contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(release.main(self.adhoc_args() + ["--ed-key-file", str(private), "--dry-run"]), 0)
        self.assertFalse((self.root / "output").exists())
        self.assertFalse(private.exists())

    def test_adhoc_plan_builds_release_without_apple_signing(self):
        options = release.parse_args(self.adhoc_args() + ["--ed-key-file", str(self.root / "ci.key")])
        release.validate_options(options)
        commands = release.command_plan(options)
        archive = next(cmd for cmd in commands if "archive" in cmd)
        self.assertIn("Release", archive)
        self.assertIn("CODE_SIGNING_ALLOWED=NO", archive)
        self.assertFalse(any(cmd[0] in ("security", "spctl") or "notarytool" in cmd or "stapler" in cmd for cmd in commands))
        self.assertFalse(any("-exportArchive" in cmd for cmd in commands))
        self.assertTrue(any(cmd[:4] == ["codesign", "--force", "--sign", "-"] for cmd in commands))
        signing = [cmd for cmd in commands if Path(cmd[0]).name in ("sign_update", "generate_appcast")]
        self.assertEqual(len(signing), 5)
        for cmd in signing:
            self.assertIn("--ed-key-file", cmd)
            self.assertNotIn("--account", cmd)

    def test_adhoc_prepare_retains_signature_trust_and_records_no_notarization(self):
        private = self.root / "ci.key"
        private.write_text(base64.b64encode(bytes(reversed(range(32)))).decode())
        options = release.parse_args(self.adhoc_args() + ["--ed-key-file", str(private)])
        runner, commands = self.fake_runner(options)
        with patch.object(release, "run", side_effect=runner), patch.object(release, "check_tools"), contextlib.redirect_stdout(io.StringIO()):
            release.prepare(options)
        import json
        manifest = json.loads((options.output / "publish/release.json").read_text())
        self.assertEqual(manifest["signing_mode"], "ad-hoc")
        self.assertIsNone(manifest["notarization"])
        self.assertEqual(manifest["archive_signature"], self.signature)
        self.assertEqual(manifest["public_key"], self.key)
        self.assertIn("appcast.xml", manifest["sha256"])
        self.assertFalse(any(cmd[0] in ("security", "spctl") or "notarytool" in cmd
                             or Path(cmd[0]).name == "generate_keys" for cmd in commands))
        self.assertNotIn(private.read_text(), repr(commands))
        self.assertTrue(any(cmd[:4] == ["codesign", "--verify", "--deep", "--strict"] for cmd in commands))

    def test_file_key_mismatch_and_invalid_seed_stop_before_build_without_leaking(self):
        private = self.root / "ci.key"
        private.write_text(base64.b64encode(bytes(reversed(range(32)))).decode())
        options = release.parse_args(self.adhoc_args() + ["--ed-key-file", str(private)])
        with patch.object(release, "run", return_value=base64.b64encode(bytes(32)).decode()) as run, patch.object(release, "check_tools"):
            with self.assertRaisesRegex(release.ReleaseError, "public key"):
                release.prepare(options)
        self.assertFalse(any(call.args[0][0] == "xcodebuild" for call in run.call_args_list))
        self.assertNotIn(private.read_text(), repr(run.call_args_list))
        private.write_text(base64.b64encode(b"bad seed").decode())
        with patch.object(release, "run", side_effect=AssertionError("No commands")), patch.object(release, "check_tools"):
            with self.assertRaisesRegex(release.ReleaseError, "32-byte"):
                release.prepare(options)
        self.assertFalse(options.output.exists())

    def test_adhoc_signs_nested_code_inside_out_preserving_helper_entitlements(self):
        options = release.parse_args(self.adhoc_args())
        app = options.output / "export/msgblast.app"
        framework = app / "Contents/Frameworks/Sparkle.framework"
        helper = framework / "Versions/B/XPCServices/Installer.xpc"
        executable = helper / "Contents/MacOS/Installer"
        executable.parent.mkdir(parents=True)
        executable.write_bytes(bytes.fromhex("cffaedfe") + b"synthetic Mach-O")
        tunnel = app / "Contents/Helpers/cloudflared"
        tunnel.parent.mkdir()
        tunnel.write_bytes(bytes.fromhex("cffaedfe") + b"synthetic tunnel helper")
        driver = app / "Contents/Helpers/cua-driver"
        driver.write_bytes(bytes.fromhex("cffaedfe") + b"synthetic embedded driver")
        with patch.object(release, "run", return_value="") as run:
            release.sign_nested_code(options)
        commands = [call.args[0] for call in run.call_args_list]
        paths = [cmd[-1] for cmd in commands]
        self.assertEqual(paths, [str(executable), str(helper), str(framework), str(tunnel), str(driver)])
        for cmd in commands:
            self.assertIn("--preserve-metadata=entitlements", cmd)

    def test_rejects_unsafe_or_missing_configuration(self):
        for change in [
            {"--identity": "-"}, {"--identity": "Apple Development: Example (ABCDEFGHIJ)"},
            {"--notary-profile": ""}, {"--build": "1"}, {"--previous-build": "-1"},
            {"--feed-url": "http://updates.example.com/appcast.xml"},
            {"--download-url-prefix": "https://user:secret@example.com/downloads/"},
            {"--download-url-prefix": "https://updates.example.com/downloads"},
            {"--public-key": base64.b64encode(b"short").decode()},
            {"--version": "../unsafe"}, {"--team-id": "ZZZZZZZZZZ"},
        ]:
            with self.subTest(change=change), self.assertRaises(release.ReleaseError):
                release.validate_options(self.options(change))

    def test_dry_run_has_no_subprocess_or_file_writes(self):
        with patch.object(release, "run", side_effect=AssertionError("No commands")), contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(release.main(self.args + ["--dry-run"]), 0)
        self.assertFalse((self.root / "output").exists())

    def test_command_plan_keeps_build_settings_signing_and_export(self):
        options = self.options()
        release.validate_options(options)
        commands = release.command_plan(options)
        archive = next(cmd for cmd in commands if "archive" in cmd)
        for setting in ["MARKETING_VERSION=0.1.0", "CURRENT_PROJECT_VERSION=2",
                        "CODE_SIGN_STYLE=Manual", "ENABLE_HARDENED_RUNTIME=YES",
                        "SPARKLE_FEED_URL=https://updates.example.com/appcast.xml",
                        "SPARKLE_PUBLIC_ED_KEY=" + self.key,
                        "ASSETCATALOG_COMPILER_APPICON_NAME=AppIcon"]:
            self.assertIn(setting, archive)
        self.assertTrue(any("-exportArchive" in cmd for cmd in commands))
        self.assertTrue(any(cmd[:3] == ["xcrun", "notarytool", "submit"] for cmd in commands))
        self.assertTrue(any(cmd[:3] == ["xcrun", "stapler", "staple"] for cmd in commands))
        self.assertTrue(any("generate_appcast" in Path(cmd[0]).name for cmd in commands))
        self.assertFalse(any(cmd[0] in ("gh", "curl", "scp") for cmd in commands))
        export = release.export_options(options)
        self.assertEqual(export["method"], "developer-id")
        self.assertEqual(export["signingCertificate"], options.identity)

    def fake_runner(self, options, *, notary_status="Accepted", mismatched_key=False, contacts_entitlement=True):
        commands = []

        def fake(cmd):
            commands.append(cmd)
            if cmd[0] == "security":
                return '1) ABCD "' + options.identity + '"\n'
            if cmd[0] == "swift":
                return self.key + "\n"
            if Path(cmd[0]).name == "generate_keys":
                return (base64.b64encode(bytes(32)).decode() if mismatched_key else self.key) + "\n"
            if "-exportArchive" in cmd or (cmd[0] == "xcodebuild" and "archive" in cmd and options.signing_mode == "ad-hoc"):
                app = (options.output / "msgblast.xcarchive/Products/Applications/msgblast.app"
                       if options.signing_mode == "ad-hoc" else options.output / "export/msgblast.app")
                (app / "Contents/Frameworks/msgblastCore.framework").mkdir(parents=True)
                (app / "Contents/Frameworks/Sparkle.framework").mkdir()
                (app / "Contents/Helpers").mkdir()
                (app / "Contents/Helpers/cloudflared").write_bytes(b"synthetic helper")
                (app / "Contents/Helpers/cua-driver").write_bytes(b"synthetic embedded driver")
                (app / "Contents/Resources").mkdir()
                for name in ("cloudflared.json", "CloudflaredNotices.txt", "cua-driver.json", "CuaDriverNotices.txt"):
                    (app / "Contents/Resources" / name).write_text("synthetic notice")
                info = {"CFBundleIdentifier": "com.msgblast.mac", "CFBundleName": "msgblast",
                        "CFBundleDisplayName": "msgblast", "CFBundleExecutable": "msgblast",
                        "CFBundleVersion": str(options.build), "CFBundleShortVersionString": options.version,
                        "SUFeedURL": options.feed_url, "SUPublicEDKey": options.public_key,
                        "SUVerifyUpdateBeforeExtraction": True, "SURequireSignedFeed": True}
                with (app / "Contents/Info.plist").open("wb") as file:
                    plistlib.dump(info, file)
            if cmd[:2] == ["codesign", "-dv"] and options.signing_mode == "ad-hoc":
                return "Signature=adhoc\nflags=0x10002(adhoc,runtime)\n"
            if cmd[:2] == ["codesign", "-dv"]:
                return "Authority=" + options.identity + "\nTeamIdentifier=" + options.team_id + "\nflags=0x10000(runtime)\n"
            if cmd[:3] == ["codesign", "-d", "--entitlements"]:
                return plistlib.dumps({"com.apple.security.personal-information.addressbook": contacts_entitlement,
                                       "com.apple.security.automation.apple-events": True,
                                       "com.apple.security.cs.disable-library-validation": options.signing_mode == "ad-hoc"}).decode()
            if cmd[0] == "ditto":
                if Path(cmd[1]).is_dir():
                    shutil.copytree(cmd[1], cmd[-1])
                else:
                    Path(cmd[-1]).write_bytes(b"synthetic archive")
            if cmd[:3] == ["xcrun", "notarytool", "submit"]:
                return '{"status":"' + notary_status + '","id":"synthetic-notarization"}'
            if Path(cmd[0]).name == "sign_update" and "-p" in cmd:
                return self.signature + "\n"
            if Path(cmd[0]).name == "generate_appcast":
                payload = options.output / "publish"
                archive = payload / release.archive_name(options)
                (payload / "appcast.xml").write_text(
                    '<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel><item>'
                    '<sparkle:version>2</sparkle:version><sparkle:shortVersionString>0.1.0</sparkle:shortVersionString>'
                    '<description>Native updates.</description><enclosure url="' + options.download_url_prefix
                    + archive.name + '" sparkle:edSignature="' + self.signature + '" length="'
                    + str(archive.stat().st_size) + '" /></item></channel></rss>')
            return ""

        return fake, commands

    def test_all_app_signing_modes_declare_contacts_resource_access(self):
        for name in ("msgblast.entitlements", "msgblastDebug.entitlements", "msgblastAdHoc.entitlements"):
            with self.subTest(configuration=name):
                entitlements = plistlib.loads((release.ROOT / "msgblast" / name).read_bytes())
                self.assertIs(entitlements.get("com.apple.security.personal-information.addressbook"), True,
                              "Hardened runtime otherwise blocks Contacts despite user approval")

    def test_missing_contacts_entitlement_stops_release_before_notarization_and_packaging(self):
        for mode in ("developer-id", "ad-hoc"):
            with self.subTest(mode=mode):
                options = self.options({"--output": str(self.root / mode)}) if mode == "developer-id" else release.parse_args(self.adhoc_args() + ["--output", str(self.root / mode)])
                runner, commands = self.fake_runner(options, contacts_entitlement=False)
                with patch.object(release, "run", side_effect=runner), patch.object(release, "check_tools"), contextlib.redirect_stdout(io.StringIO()):
                    with self.assertRaisesRegex(release.ReleaseError, "Contacts.*entitlement"):
                        release.prepare(options)
                self.assertFalse(any(cmd[:3] == ["xcrun", "notarytool", "submit"] for cmd in commands))
                self.assertFalse(any(cmd[0] == "ditto" and "-k" in cmd for cmd in commands))
                self.assertFalse((options.output / "publish/release.json").exists())

    def test_prepare_verifies_and_records_actual_artifacts(self):
        options = self.options()
        runner, commands = self.fake_runner(options)
        with patch.object(release, "run", side_effect=runner), patch.object(release, "check_tools"), contextlib.redirect_stdout(io.StringIO()):
            release.prepare(options)
        publish = options.output / "publish"
        self.assertTrue((publish / "appcast.xml").is_file())
        self.assertTrue((publish / "release.json").is_file())
        self.assertTrue((publish / release.archive_name(options).replace(".zip", ".md")).is_file())
        self.assertEqual(len([cmd for cmd in commands if cmd[0] == "ditto"]), 2)
        notary = next(i for i, cmd in enumerate(commands) if "notarytool" in cmd)
        staple = next(i for i, cmd in enumerate(commands) if cmd[:3] == ["xcrun", "stapler", "staple"])
        self.assertLess(notary, staple)
        self.assertTrue(any("--verify" in cmd and cmd[-1] == self.signature for cmd in commands))
        self.assertTrue(any("--verify" in cmd and cmd[-1].endswith("appcast.xml") for cmd in commands))

    def test_invalid_notarization_stops_before_stapling_and_publication(self):
        options = self.options()
        runner, commands = self.fake_runner(options, notary_status="Invalid")
        with patch.object(release, "run", side_effect=runner), patch.object(release, "check_tools"):
            with self.assertRaisesRegex(release.ReleaseError, "notarization"):
                release.prepare(options)
        self.assertFalse(any(cmd[:3] == ["xcrun", "stapler", "staple"] for cmd in commands))
        self.assertFalse((options.output / "publish/release.json").exists())

    def test_mismatched_key_stops_before_build(self):
        options = self.options()
        runner, commands = self.fake_runner(options, mismatched_key=True)
        with patch.object(release, "run", side_effect=runner), patch.object(release, "check_tools"):
            with self.assertRaisesRegex(release.ReleaseError, "public key"):
                release.prepare(options)
        self.assertFalse(any(cmd[0] == "xcodebuild" for cmd in commands))

    def test_existing_output_is_not_overwritten(self):
        options = self.options()
        options.output.mkdir()
        with patch.object(release, "run", side_effect=AssertionError("No commands")):
            with self.assertRaisesRegex(release.ReleaseError, "already exists"):
                release.prepare(options)

    def test_exported_metadata_and_frameworks_are_checked_before_notarizing(self):
        changes = [
            {"CFBundleName": "WrongName"}, {"CFBundleDisplayName": "WrongName"},
            {"CFBundleExecutable": "WrongName"}, {"CFBundleVersion": "1"}, {"SUFeedURL": "https://wrong.example/feed.xml"},
            {"SURequireSignedFeed": False}, {"SUVerifyUpdateBeforeExtraction": False},
            {"msgblastDemo": True}, {"msgblastPermissionGuidePreview": True},
            "missing core", "missing sparkle", "missing cloudflared", "missing helper manifest", "missing helper notices",
            "missing embedded driver", "missing driver manifest", "missing driver notices",
        ]
        for index, change in enumerate(changes):
            with self.subTest(change=change):
                options = self.options({"--output": str(self.root / f"bad-export-{index}")})
                base_runner, commands = self.fake_runner(options)

                def fake(cmd):
                    result = base_runner(cmd)
                    if "-exportArchive" in cmd:
                        app = options.output / "export/msgblast.app"
                        if isinstance(change, str):
                            missing = {
                                "missing core": "Contents/Frameworks/msgblastCore.framework",
                                "missing sparkle": "Contents/Frameworks/Sparkle.framework",
                                "missing cloudflared": "Contents/Helpers/cloudflared",
                                "missing helper manifest": "Contents/Resources/cloudflared.json",
                                "missing helper notices": "Contents/Resources/CloudflaredNotices.txt",
                                "missing embedded driver": "Contents/Helpers/cua-driver",
                                "missing driver manifest": "Contents/Resources/cua-driver.json",
                                "missing driver notices": "Contents/Resources/CuaDriverNotices.txt",
                            }
                            path = app / missing[change]
                            if path.is_dir(): shutil.rmtree(path)
                            else: path.unlink()
                        else:
                            info_path = app / "Contents/Info.plist"
                            with info_path.open("rb") as file:
                                info = plistlib.load(file)
                            info.update(change)
                            with info_path.open("wb") as file:
                                plistlib.dump(info, file)
                    return result

                with patch.object(release, "run", side_effect=fake), patch.object(release, "check_tools"):
                    with self.assertRaises(release.ReleaseError):
                        release.prepare(options)
                self.assertFalse(any(cmd[:3] == ["xcrun", "notarytool", "submit"] for cmd in commands))

    def test_missing_certificate_fails_before_build(self):
        options = self.options()
        with patch.object(release, "run", return_value='"Apple Development: Example (ABCDEFGHIJ)"') as run, patch.object(release, "check_tools"):
            with self.assertRaisesRegex(release.ReleaseError, "not available"):
                release.prepare(options)
        self.assertEqual(run.call_count, 1)
        self.assertFalse(options.output.exists())

    def test_missing_notarization_credentials_and_command_failure_stop_pipeline(self):
        options = self.options()
        base_runner, commands = self.fake_runner(options)

        def fake(cmd):
            if cmd[:3] == ["xcrun", "notarytool", "history"]:
                raise release.ReleaseError("missing notarization profile")
            return base_runner(cmd)

        with patch.object(release, "run", side_effect=fake), patch.object(release, "check_tools"):
            with self.assertRaisesRegex(release.ReleaseError, "notarization profile"):
                release.prepare(options)
        self.assertFalse(options.output.exists())
        self.assertFalse(any(cmd[0] == "xcodebuild" for cmd in commands))

    def test_bad_appcast_signature_or_url_prevents_success_manifest(self):
        for index, mutation in enumerate([self.signature, "https://updates.example.com/downloads/"]):
            with self.subTest(mutation=mutation):
                options = self.options({"--output": str(self.root / f"bad-feed-{index}")})
                base_runner, commands = self.fake_runner(options)

                def fake(cmd):
                    result = base_runner(cmd)
                    if Path(cmd[0]).name == "generate_appcast":
                        feed = release.feed_path(options)
                        feed.write_text(feed.read_text().replace(mutation, "wrong"))
                    return result

                with patch.object(release, "run", side_effect=fake), patch.object(release, "check_tools"):
                    with self.assertRaisesRegex(release.ReleaseError, "appcast"):
                        release.prepare(options)
                self.assertFalse((options.output / "publish/release.json").exists())
                self.assertFalse(any(Path(cmd[0]).name == "sign_update" and cmd[-1].endswith("appcast.xml") for cmd in commands))


if __name__ == "__main__":
    unittest.main()
