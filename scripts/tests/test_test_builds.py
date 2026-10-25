"""Testing distribution contracts, with local synthetic bundles and a fake GitHub transport."""
import contextlib
import io
import json
from pathlib import Path
import plistlib
import stat
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch
import zipfile

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import test_builds as builds
import preview_apps as preview


SOURCE = "a" * 40


class TestBuildTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.directory = Path(self.temporary.name)
        self.archive = self.directory / f"msgblast-dev-{SOURCE[:12]}.zip"
        self.archive.write_bytes(b"synthetic local Dev archive; not a runnable or signed app")
        self.document = {
            "source_revision": SOURCE, "production_feed_used": False,
            "variants": [{"id": "development", "fixture": False, "app_name": "msgblast Dev.app",
                          "bundle_id": "com.msgblast.development", "updates": "disabled",
                          "zip": self.archive.name, "sha256": preview.sha256_file(self.archive),
                          "signing": {"mode": "developer-id", "notarization": {"status": "Accepted"}}}],
        }
        self.save()
        self.args = SimpleNamespace(directory=self.directory, source=SOURCE, repo="owner/repo", run="123-1",
                                    title="New composer", notes="Try the composer and report draft retention.")

    def save(self):
        (self.directory / "preview-manifest.json").write_text(json.dumps(self.document))

    def test_prepare_records_source_install_feedback_and_unique_nonproduction_tag(self):
        with contextlib.redirect_stdout(io.StringIO()):
            plan, notes, archive = builds.prepare(self.args)
        self.assertEqual(plan["tag"], "test-" + SOURCE + "-123-1")
        self.assertEqual(plan["sha256"], preview.sha256_file(archive))
        text = notes.read_text()
        self.assertIn(self.args.notes, text)
        self.assertIn(SOURCE, text)
        self.assertIn("Updates are manual", text)
        self.assertIn("All Dev testing builds share that Dev profile", text)

    def test_rejects_wrong_source_production_identity_unsigned_and_changed_bytes(self):
        for field, value in (("bundle_id", "com.msgblast.mac"), ("fixture", True),
                             ("updates", "enabled"), ("signing", {"mode": "ad-hoc"}),
                             ("zip", "../elsewhere.zip"), ("sha256", "0" * 64)):
            with self.subTest(field=field):
                original = self.document["variants"][0][field]
                self.document["variants"][0][field] = value
                self.save()
                with self.assertRaises(ValueError):
                    builds.load_package(self.directory, SOURCE)
                self.document["variants"][0][field] = original
        self.save()
        with self.assertRaisesRegex(ValueError, "source differs"):
            builds.load_package(self.directory, "b" * 40)

    def test_rejects_missing_or_bypassable_signing_approval(self):
        valid = {"protection_rules": [{"type": "required_reviewers", "reviewers": [{"id": 123}]}],
                 "deployment_branch_policy": {"custom_branch_policies": True}, "can_admins_bypass": False}
        builds.validate_environment(valid)
        for field, value in (("protection_rules", []), ("can_admins_bypass", True),
                             ("deployment_branch_policy", None)):
            with self.subTest(field=field), self.assertRaises(ValueError):
                builds.validate_environment({**valid, field: value})

    def test_signer_checks_actual_bundle_before_using_signing_tools(self):
        # A forged Dev manifest cannot disguise a production bundle inside it.
        info = preview.configure_info({"CFBundleExecutable": "msgblast"}, builds.VARIANT, SOURCE)
        info["CFBundleIdentifier"] = "com.msgblast.mac"
        with zipfile.ZipFile(self.archive, "w") as archive:
            archive.writestr("msgblast Dev.app/Contents/Info.plist", plistlib.dumps(info))
        self.document["variants"][0]["sha256"] = preview.sha256_file(self.archive)
        self.save()
        self.args.output = self.directory / "signed"
        environment = {"MSGBLAST_DEVELOPER_ID_IDENTITY": "fixture identity", "MSGBLAST_APPLE_TEAM_ID": "fixture",
                       "MSGBLAST_NOTARY_KEYCHAIN": "/fixture", "MSGBLAST_NOTARY_PROFILE": "fixture"}
        with patch.dict(builds.os.environ, environment), patch.object(builds.builder, "sign_bundle") as signer, \
             self.assertRaisesRegex(RuntimeError, "CFBundleIdentifier"):
            builds.sign(self.args)
        signer.assert_not_called()

    def test_universal_verification_checks_packaged_helpers_and_nested_code(self):
        # Header fixtures are deliberately not runnable code. lipo is the only
        # substituted boundary; a missing architecture must abort before signing.
        app = self.directory / "msgblast Dev.app"
        info = app / "Contents/Info.plist"
        info.parent.mkdir(parents=True)
        info.write_bytes(plistlib.dumps({"CFBundleExecutable": "msgblast"}))
        binaries = [app / name for name in ("Contents/MacOS/msgblast",
                    "Contents/MacOS/msgblast.debug.dylib", "Contents/Helpers/cua-driver",
                    "Contents/Helpers/cloudflared")]
        for binary in binaries:
            binary.parent.mkdir(parents=True, exist_ok=True)
            binary.write_bytes(bytes.fromhex("cffaedfe") + b"header fixture")
            binary.chmod(0o755)
        resources = app / "Contents/Resources"
        resources.mkdir()
        for name in ("cua-driver.json", "CuaDriverNotices.txt", "cloudflared.json", "CloudflaredNotices.txt"):
            (resources / name).write_text("fixture")
        with patch.object(builds.builder, "run") as run:
            builds.builder.verify_universal_bundle(app)
        self.assertEqual({call.args[0][-1] for call in run.call_args_list}, set(map(str, binaries)))
        self.assertTrue(all(call.args[0][:5] == ["xcrun", "lipo", "-verify_arch", "arm64", "x86_64"]
                            for call in run.call_args_list))
        with patch.object(builds.builder, "run", side_effect=SystemExit("missing x86_64")), \
             self.assertRaisesRegex(SystemExit, "missing x86_64"):
            builds.builder.verify_universal_bundle(app)
        binaries[2].unlink()
        with patch.object(builds.builder, "run") as run, self.assertRaisesRegex(RuntimeError, "cua-driver"):
            builds.builder.verify_universal_bundle(app)
        run.assert_not_called()
        binaries[2].write_text("an executable script cannot replace embedded Mach-O")
        binaries[2].chmod(0o755)
        with self.assertRaisesRegex(RuntimeError, "cua-driver"):
            builds.builder.verify_universal_bundle(app)

    def test_rejected_notarization_never_produces_a_publishable_manifest(self):
        # Exercise the signer orchestration, but label signing/icon/lipo as
        # synthetic. The rejection originates at the actual notary boundary.
        app = self.directory / "fixture.app"
        info = app / "Contents/Info.plist"
        info.parent.mkdir(parents=True)
        info.write_bytes(plistlib.dumps(preview.configure_info({}, builds.VARIANT, SOURCE)))
        self.args.output = self.directory / "rejected"
        environment = {"MSGBLAST_DEVELOPER_ID_IDENTITY": "fixture identity", "MSGBLAST_APPLE_TEAM_ID": "fixture",
                       "MSGBLAST_NOTARY_KEYCHAIN": "/fixture", "MSGBLAST_NOTARY_PROFILE": "fixture"}
        with patch.dict(builds.os.environ, environment), patch.object(builds, "extract_app", return_value=app), \
             patch.object(builds.builder, "verify_universal_bundle"), \
             patch.object(preview, "compiled_icon_path", return_value=Path("fixture.icns")), \
             patch.object(preview, "sample_icns", return_value=(0, 120, 130, "fixture")), \
             patch.object(builds.builder, "sign_bundle") as signer, \
             patch.object(builds.builder, "notarize_preview", side_effect=RuntimeError("not Accepted")), \
             self.assertRaisesRegex(RuntimeError, "not Accepted"):
            builds.sign(self.args)
        signer.assert_called_once()
        self.assertFalse((self.args.output / "preview-manifest.json").exists())
        self.assertEqual(list(self.args.output.iterdir()), [])

    def make_zip(self, entries):
        path = self.directory / "bundle.zip"
        with zipfile.ZipFile(path, "w") as zipped:
            for name, data, symlink in entries:
                entry = zipfile.ZipInfo(name)
                entry.external_attr = ((stat.S_IFLNK | 0o777) if symlink else (stat.S_IFREG | 0o755)) << 16
                zipped.writestr(entry, data)
        return path

    def test_extracts_framework_links_and_preserves_executable_permissions(self):
        archive = self.make_zip([
            ("msgblast Dev.app/Contents/Frameworks/A.framework/Versions/A/A", b"binary", False),
            ("msgblast Dev.app/Contents/Frameworks/A.framework/Versions/Current", "A", True),
            ("msgblast Dev.app/Contents/Frameworks/A.framework/A", "Versions/Current/A", True),
        ])
        app = builds.extract_app(archive, self.directory / "out")
        binary = app / "Contents/Frameworks/A.framework/A"
        self.assertEqual(binary.read_bytes(), b"binary")
        self.assertTrue(binary.stat().st_mode & stat.S_IXUSR)

    def test_rejects_zip_traversal_escape_links_and_children_of_links(self):
        for entries in ([('../escape', b'bad', False)],
                        [('msgblast Dev.app/Contents/../../escape', b'bad', False)],
                        [('msgblast Dev.app/Contents/link', '/tmp/outside', True)],
                        [('msgblast Dev.app/Contents/link', '../../../outside', True)],
                        [('msgblast Dev.app/Contents/link', 'real', True),
                         ('msgblast Dev.app/Contents/link/file', b'bad', False)]):
            with self.subTest(entries=entries), self.assertRaises(ValueError):
                builds.extract_app(self.make_zip(entries), self.directory / "out")
        self.assertFalse((self.directory / "escape").exists())

    def fake_github(self, *, corrupt=False, tag_source=SOURCE):
        calls = []
        def transport(*arguments):
            calls.append(arguments)
            if arguments[:2] == ("release", "download"):
                target = Path(arguments[arguments.index("--dir") + 1])
                for filename in (self.archive.name, "preview-manifest.json", "test-release.json"):
                    (target / filename).write_bytes((self.directory / filename).read_bytes())
                if corrupt:
                    (target / self.archive.name).write_bytes(b"corrupted upload")
            if arguments[0] == "api":
                return json.dumps({"object": {"type": "commit", "sha": tag_source}})
            return ""
        return transport, calls

    def test_publishes_only_after_download_and_tag_verification(self):
        transport, calls = self.fake_github()
        with patch.object(builds, "gh", side_effect=transport), \
             patch.object(builds.urllib.request, "urlopen", return_value=io.BytesIO(self.archive.read_bytes())) as download, \
             contextlib.redirect_stdout(io.StringIO()):
            builds.publish(self.args)
        self.assertIn("ref=refs/tags/test-" + SOURCE + "-123-1", calls[0])
        self.assertIn("sha=" + SOURCE, calls[0])
        create = next(call for call in calls if call[:2] == ("release", "create"))
        self.assertEqual(create[:2], ("release", "create"))
        self.assertIn("--draft", create)
        self.assertIn("--verify-tag", create)
        self.assertIn("--prerelease", create)
        self.assertIn("--latest=false", create)
        self.assertEqual(create[create.index("--target") + 1], SOURCE)
        self.assertEqual(calls[-1][:2], ("release", "edit"))
        self.assertIn("--draft=false", calls[-1])
        download.assert_called_once()

    def test_bad_upload_or_tag_never_publishes_draft(self):
        for options in ({"corrupt": True}, {"tag_source": "b" * 40}):
            transport, calls = self.fake_github(**options)
            with self.subTest(options=options), patch.object(builds, "gh", side_effect=transport), \
                 contextlib.redirect_stdout(io.StringIO()), self.assertRaisesRegex(ValueError, "remains a draft"):
                builds.publish(self.args)
            self.assertFalse(any(call[:2] == ("release", "edit") for call in calls))

    def test_wrong_public_download_is_reported_after_publication(self):
        transport, calls = self.fake_github()
        with patch.object(builds, "gh", side_effect=transport), \
             patch.object(builds.urllib.request, "urlopen", return_value=io.BytesIO(b"wrong download")), \
             contextlib.redirect_stdout(io.StringIO()), self.assertRaisesRegex(ValueError, "may already be live"):
            builds.publish(self.args)
        self.assertEqual(calls[-1][:2], ("release", "edit"))


if __name__ == "__main__":
    unittest.main()
