"""Automated publication contracts; storage and network are synthetic."""
import importlib.util
import base64
import contextlib
import io
import hashlib
import json
import shutil
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

SCRIPT = Path(__file__).resolve().parents[1] / "automate_release.py"
sys.path.insert(0, str(SCRIPT.parent))
spec = importlib.util.spec_from_file_location("automate_release", SCRIPT)
auto = importlib.util.module_from_spec(spec)
spec.loader.exec_module(auto)


class Store:
    def __init__(self):
        self.objects = {}
        self.writes = []
        self.on_put = None

    def get(self, key, path):
        if key not in self.objects:
            return None
        data = self.objects[key]
        path.write_bytes(data)
        return {"ETag": hashlib.md5(data).hexdigest()}

    def put(self, key, path, content_type, *, etag=None):
        existing = self.objects.get(key)
        if etag is None and existing is not None:
            raise auto.ReleaseError("Object already exists")
        if etag is not None and (existing is None or hashlib.md5(existing).hexdigest() != etag):
            raise auto.ReleaseError("Conditional feed write failed")
        self.objects[key] = path.read_bytes()
        self.writes.append(key)
        if self.on_put:
            self.on_put(key)


class R2BoundaryTests(unittest.TestCase):
    def setUp(self):
        self.store = auto.R2Store("a" * 32, "msgblast-releases")

    def test_access_denied_does_not_become_an_empty_release_history(self):
        result = auto.subprocess.CompletedProcess([], 1, "", "An error occurred (AccessDenied) when calling GetObject")
        with patch.object(auto.subprocess, "run", return_value=result):
            with self.assertRaisesRegex(auto.ReleaseError, "AccessDenied"):
                self.store.get("appcast.xml", Path("previous.xml"))

    def test_missing_object_is_the_only_first_release_response(self):
        result = auto.subprocess.CompletedProcess([], 1, "", "An error occurred (NoSuchKey) when calling GetObject")
        with patch.object(auto.subprocess, "run", return_value=result):
            self.assertIsNone(self.store.get("appcast.xml", Path("previous.xml")))

    def test_storage_writes_protect_mutable_feed_and_immutable_archive(self):
        with patch.object(auto.release, "run") as run:
            self.store.put("appcast.xml", Path("feed.xml"), "application/rss+xml", etag='"old-feed"')
            feed = run.call_args.args[0]
            self.assertEqual(feed[feed.index("--if-match") + 1], '"old-feed"')
            self.assertEqual(feed[feed.index("--cache-control") + 1], "no-store")
            self.assertNotIn("--if-none-match", feed)
            self.store.put("downloads/msgblast-1-2.zip", Path("archive.zip"), "application/zip")
            archive = run.call_args.args[0]
            self.assertEqual(archive[archive.index("--if-none-match") + 1], "*")
            self.assertIn("immutable", archive[archive.index("--cache-control") + 1])
            self.assertNotIn("--if-match", archive)


class AutomatedReleaseTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.store = Store()
        self.base = "https://updates.example.com/msgblast/"
        self.prefix = "msgblast/"
        self.key_file = self.root / "key"
        self.key_file.write_text("synthetic private key")
        self.tools = self.root / "tools"
        self.publish = self.root / "publish"
        self.publish.mkdir()
        self.archive = self.publish / "msgblast-0.1.1-2.zip"
        self.archive.write_bytes(b"synthetic archive")
        self.feed = self.publish / "appcast.xml"
        self.feed.write_bytes(self.feed_bytes(2))
        self.manifest = {"version":"0.1.1", "build":2, "previous_build":1,
            "feed_url":self.base + "appcast.xml", "archive_url":self.base + "downloads/" + self.archive.name,
            "archive_signature":"synthetic", "signing_mode":"ad-hoc",
            "sha256":{f.name:hashlib.sha256(f.read_bytes()).hexdigest() for f in [self.archive,self.feed]}}
        (self.publish / "release.json").write_text(json.dumps(self.manifest))

    def feed_bytes(self, build):
        return ("<rss xmlns:sparkle=\"http://www.andymatuschak.org/xml-namespaces/sparkle\"><channel><item>"
                "<sparkle:version>" + str(build) + "</sparkle:version>"
                "<sparkle:shortVersionString>0.1.1</sparkle:shortVersionString></item></channel></rss>").encode()

    def published_manifest(self, build, mode="ad-hoc"):
        self.store.objects[self.prefix + f"releases/0.1.1-{build}.json"] = json.dumps(
            {"version": "0.1.1", "build": build, "signing_mode": mode}).encode()

    def snapshot(self):
        self.store.objects[self.prefix + "appcast.xml"] = self.feed_bytes(1)
        self.published_manifest(1)
        with patch.object(auto, "verify_feed"):
            return auto.current_release(self.store, self.prefix, self.root, self.tools, self.key_file)

    def publish_release(self, snapshot):
        with patch.object(auto, "verify_feed"), patch.object(auto, "verify_archive"), patch.object(auto, "verify_public", side_effect=self.verify_public):
            return auto.publish_release(self.store, self.base, self.publish, snapshot, self.tools, self.key_file)

    def verify_public(self, url, digest):
        data = self.store.objects[url.removeprefix("https://updates.example.com/")]
        if hashlib.sha256(data).hexdigest() != digest:
            raise auto.ReleaseError("Public download hash mismatch")

    def test_allocates_from_existing_verified_feed_and_only_missing_is_first_release(self):
        with patch.object(auto, "verify_feed") as verify:
            empty = auto.current_release(self.store, self.prefix, self.root, self.tools, self.key_file)
            self.assertEqual(empty["build"], 0)
            self.store.objects[self.prefix + "appcast.xml"] = self.feed_bytes(7)
            self.published_manifest(7)
            snapshot = auto.current_release(self.store, self.prefix, self.root, self.tools, self.key_file)
        self.assertEqual(snapshot["build"], 7)
        verify.assert_called_once()
        with patch.object(self.store, "get", side_effect=auto.ReleaseError("Access denied")):
            with self.assertRaisesRegex(auto.ReleaseError, "Access denied"):
                auto.current_release(self.store, self.prefix, self.root, self.tools, self.key_file)

    def test_unknown_published_signing_history_stops_before_a_release(self):
        self.store.objects[self.prefix + "appcast.xml"] = self.feed_bytes(1)
        with patch.object(auto, "verify_feed"):
            with self.assertRaisesRegex(auto.ReleaseError, "manifest"):
                auto.current_release(self.store, self.prefix, self.root, self.tools, self.key_file)

    def test_published_developer_id_cannot_downgrade_if_mode_configuration_disappears(self):
        self.key_file.write_text(base64.b64encode(b"0" * 32).decode())
        self.store.objects[self.prefix + "appcast.xml"] = self.feed_bytes(1)
        self.published_manifest(1, "developer-id")
        environment = {"MSGBLAST_PUBLIC_BASE_URL": self.base, "MSGBLAST_ED_KEY_FILE": str(self.key_file),
            "MSGBLAST_SPARKLE_BIN": str(self.tools), "MSGBLAST_PUBLIC_KEY": "fixture-public-key",
            "MSGBLAST_R2_ACCOUNT_ID": "a" * 32, "MSGBLAST_R2_BUCKET": "msgblast-releases",
            "AWS_ACCESS_KEY_ID": "fixture-access", "AWS_SECRET_ACCESS_KEY": "fixture-secret"}
        # Missing and empty repository variables both resolve to ad-hoc in the workflow.
        for mode in (None, "ad-hoc"):
            with self.subTest(mode=mode):
                if mode is not None:
                    environment["MSGBLAST_SIGNING_MODE"] = mode
                with patch.dict(auto.os.environ, environment, clear=True), \
                     patch.object(auto, "R2Store", return_value=self.store), \
                     patch.object(auto, "verify_feed"), patch.object(auto, "reserve_build", return_value=2) as reserve, \
                     patch.object(auto.release, "ROOT", self.root), patch.object(auto, "prepare_installer"), \
                     patch.object(auto.release, "prepare") as prepare, \
                     contextlib.redirect_stderr(io.StringIO()):
                    self.assertEqual(auto.main(["--version", "0.6.1"]), 1)
                reserve.assert_not_called()
                prepare.assert_not_called()
        self.assertEqual(self.store.writes, [])

    def test_publisher_rejects_a_prepared_signing_downgrade_before_upload(self):
        snapshot = self.snapshot()
        snapshot["signing_mode"] = "developer-id"
        with self.assertRaisesRegex(auto.ReleaseError, "downgrade"):
            self.publish_release(snapshot)
        self.assertEqual(self.store.writes, [])

    def test_counter_reservations_survive_failed_builds_without_reusing_archive_names(self):
        self.assertEqual(auto.reserve_build(self.store, self.prefix, self.root, 7), 8)
        self.assertEqual(auto.reserve_build(self.store, self.prefix, self.root, 7), 9)
        self.assertEqual(json.loads(self.store.objects[self.prefix + "release-counter.json"])["build"], 9)

    def test_counter_reservation_uses_conditional_writes(self):
        self.store.objects[self.prefix + "release-counter.json"] = b'{"build": 8}'
        original = self.store.get

        def concurrent_get(key, path):
            result = original(key, path)
            self.store.objects[key] = b'{"build": 9}'
            return result

        with patch.object(self.store, "get", side_effect=concurrent_get):
            with self.assertRaisesRegex(auto.ReleaseError, "Conditional"):
                auto.reserve_build(self.store, self.prefix, self.root, 7)
        self.assertEqual(json.loads(self.store.objects[self.prefix + "release-counter.json"])["build"], 9)

    def test_invalid_feed_signature_stops_counter_allocation(self):
        self.store.objects[self.prefix + "appcast.xml"] = self.feed_bytes(7)
        with patch.object(auto, "verify_feed", side_effect=auto.ReleaseError("Bad signature")):
            with self.assertRaisesRegex(auto.ReleaseError, "Bad signature"):
                auto.current_release(self.store, self.prefix, self.root, self.tools, self.key_file)

    def test_installer_is_verified_and_uploaded_before_feed(self):
        snapshot = self.snapshot()
        installer = self.publish / "msgblast-0.1.1-2.dmg"
        installer.write_bytes(b"synthetic installer")
        self.manifest.update(installer_url=self.base + "downloads/" + installer.name,
                             installer_signature="synthetic")
        self.manifest["sha256"][installer.name] = hashlib.sha256(installer.read_bytes()).hexdigest()
        (self.publish / "release.json").write_text(json.dumps(self.manifest))
        self.publish_release(snapshot)
        self.assertEqual(self.store.writes[-3:], [self.prefix + "downloads/" + installer.name,
            self.prefix + "releases/0.1.1-2.json", self.prefix + "appcast.xml"])
        self.assertEqual(self.store.objects[self.prefix + "downloads/" + installer.name], installer.read_bytes())

    def test_tampered_installer_leaves_feed_and_storage_unchanged(self):
        snapshot = self.snapshot()
        installer = self.publish / "msgblast-0.1.1-2.dmg"
        installer.write_bytes(b"tampered installer")
        self.manifest.update(installer_url=self.base + "downloads/" + installer.name,
                             installer_signature="synthetic")
        self.manifest["sha256"][installer.name] = "0" * 64
        (self.publish / "release.json").write_text(json.dumps(self.manifest))
        with self.assertRaisesRegex(auto.ReleaseError, "hash"):
            self.publish_release(snapshot)
        self.assertEqual(self.store.writes, [])

    def test_archive_and_immutable_manifest_precede_feed(self):
        snapshot = self.snapshot()
        self.publish_release(snapshot)
        self.assertEqual(self.store.writes, [self.prefix + "downloads/" + self.archive.name,
            self.prefix + "releases/0.1.1-2.json", self.prefix + "appcast.xml"])

    def test_failed_public_archive_verification_leaves_previous_feed(self):
        snapshot = self.snapshot()
        with patch.object(auto, "verify_archive"), patch.object(auto, "verify_feed"), patch.object(auto, "verify_public", side_effect=auto.ReleaseError("Public download hash mismatch")):
            with self.assertRaisesRegex(auto.ReleaseError, "hash mismatch"):
                auto.publish_release(self.store, self.base, self.publish, snapshot, self.tools, self.key_file)
        self.assertEqual(self.store.objects[self.prefix + "appcast.xml"], self.feed_bytes(1))

    def test_concurrent_feed_publication_cannot_overwrite_newer_release(self):
        snapshot = self.snapshot()
        self.store.on_put = lambda key: self.store.objects.update({self.prefix + "appcast.xml":self.feed_bytes(3)}) if key.endswith(".zip") else None
        with self.assertRaisesRegex(auto.ReleaseError, "Conditional feed write"):
            self.publish_release(snapshot)
        self.assertEqual(self.store.objects[self.prefix + "appcast.xml"], self.feed_bytes(3))

    def test_existing_archive_is_never_overwritten(self):
        snapshot = self.snapshot()
        self.store.objects[self.prefix + "downloads/" + self.archive.name] = b"old bytes"
        with self.assertRaisesRegex(auto.ReleaseError, "already exists"):
            self.publish_release(snapshot)
        self.assertEqual(self.store.objects[self.prefix + "downloads/" + self.archive.name], b"old bytes")

    def test_changed_prepared_artifact_cannot_publish(self):
        snapshot = self.snapshot()
        self.archive.write_bytes(b"tampered after preparation")
        with self.assertRaisesRegex(auto.ReleaseError, "hash"):
            self.publish_release(snapshot)
        self.assertEqual(self.store.writes, [])

    def test_release_urls_must_match_destination(self):
        snapshot = self.snapshot()
        self.manifest["archive_url"] = "https://wrong.example/download.zip"
        (self.publish / "release.json").write_text(json.dumps(self.manifest))
        with self.assertRaisesRegex(auto.ReleaseError, "URL"):
            self.publish_release(snapshot)
        self.assertEqual(self.store.writes, [])

    def test_main_carries_reserved_build_feed_snapshot_revision_and_summary(self):
        self.exercise_main("ad-hoc")

    def test_developer_id_keeps_counter_feed_and_publication_contract(self):
        self.exercise_main("developer-id")

    def exercise_main(self, signing_mode):
        # A deterministic fixture seed never authenticates production artifacts.
        self.key_file.write_text(base64.b64encode(b"0" * 32).decode())
        self.store.objects[self.prefix + "appcast.xml"] = self.feed_bytes(1)
        self.published_manifest(1)
        revision = "f" * 40
        summary = self.root / "summary.md"
        environment = {
            "MSGBLAST_PUBLIC_BASE_URL": self.base,
            "MSGBLAST_ED_KEY_FILE": str(self.key_file),
            "MSGBLAST_SPARKLE_BIN": str(self.tools),
            "MSGBLAST_PUBLIC_KEY": base64.b64encode(b"1" * 32).decode(),
            "MSGBLAST_R2_ACCOUNT_ID": "a" * 32,
            "MSGBLAST_R2_BUCKET": "msgblast-releases",
            "AWS_ACCESS_KEY_ID": "synthetic-access",
            "AWS_SECRET_ACCESS_KEY": "synthetic-secret",
            "GITHUB_SHA": revision,
            "GITHUB_RUN_ID": "123",
            "GITHUB_RUN_ATTEMPT": "2",
            "GITHUB_STEP_SUMMARY": str(summary),
        }

        if signing_mode == "developer-id":
            environment.update(MSGBLAST_SIGNING_MODE=signing_mode,
                MSGBLAST_APPLE_TEAM_ID="ABCDEFGHIJ",
                MSGBLAST_DEVELOPER_ID_IDENTITY="Developer ID Application: Example (ABCDEFGHIJ)",
                MSGBLAST_NOTARY_PROFILE="fixture-notary",
                MSGBLAST_NOTARY_KEYCHAIN=str(self.root / "signing.keychain-db"))

        def prepare(options):
            publish = options.output / "publish"
            publish.mkdir(parents=True)
            (publish / "release.json").write_text(json.dumps({
                "version": options.version, "build": options.build, "signing_mode": options.signing_mode,
                "previous_build": options.previous_build, "feed_url": options.feed_url,
                "archive_url": options.download_url_prefix + auto.release.archive_name(options)}))

        def publish(store, base, directory, snapshot, tools, key_file):
            self.assertIs(store, self.store)
            self.assertEqual(base, self.base)
            self.assertEqual(snapshot["build"], 1)
            self.assertEqual(snapshot["etag"], hashlib.md5(self.feed_bytes(1)).hexdigest())
            self.assertEqual(tools, self.tools.resolve())
            self.assertEqual(key_file, self.key_file.resolve())
            result = json.loads((directory / "release.json").read_text())
            self.assertEqual(result["source_revision"], revision)
            result["installer_url"] = self.base + "downloads/fixture.dmg"
            return result

        with patch.dict(auto.os.environ, environment, clear=True), \
             patch.object(auto.release, "ROOT", self.root), \
             patch.object(auto, "R2Store", return_value=self.store), \
             patch.object(auto, "verify_feed"), \
             patch.object(auto.release, "prepare", side_effect=prepare) as preparation, \
             patch.object(auto, "prepare_installer"), \
             patch.object(auto, "publish_release", side_effect=publish) as publication:
            self.assertEqual(auto.main(["--version", "v0.1.0"]), 0)
        options = preparation.call_args.args[0]
        self.assertEqual((options.build, options.previous_build), (2, 1))
        self.assertEqual(options.signing_mode, signing_mode)
        if signing_mode == "developer-id":
            self.assertEqual(options.identity, environment["MSGBLAST_DEVELOPER_ID_IDENTITY"])
            self.assertEqual(options.team_id, "ABCDEFGHIJ")
            self.assertEqual(options.notary_profile, "fixture-notary")
            self.assertEqual(options.notary_keychain, (self.root / "signing.keychain-db").resolve())
            self.assertIn("Developer ID", summary.read_text())
        else:
            self.assertIsNone(options.identity)
            self.assertIsNone(options.notary_profile)
        self.assertEqual(options.output, (self.root / "build/releases/0.1.0-2-123-2").resolve())
        publication.assert_called_once()
        self.assertEqual(json.loads(self.store.objects[self.prefix + "release-counter.json"])["build"], 2)
        self.assertIn(revision, summary.read_text())
        self.assertIn("msgblast 0.1.0 (2) published", summary.read_text())
        self.assertIn(self.base + "downloads/msgblast-0.1.0-2.zip", summary.read_text())

    @contextlib.contextmanager
    def split_release(self):
        self.key_file.write_text(base64.b64encode(b"0" * 32).decode())
        self.snapshot()
        self.environment = {
            "MSGBLAST_PUBLIC_BASE_URL": self.base, "MSGBLAST_ED_KEY_FILE": str(self.key_file),
            "MSGBLAST_SPARKLE_BIN": str(self.tools),
            "MSGBLAST_PUBLIC_KEY": base64.b64encode(b"1" * 32).decode(),
            "MSGBLAST_R2_ACCOUNT_ID": "a" * 32, "MSGBLAST_R2_BUCKET": "msgblast-releases",
            "AWS_ACCESS_KEY_ID": "synthetic-access", "AWS_SECRET_ACCESS_KEY": "synthetic-secret",
            "GITHUB_SHA": "f" * 40, "GITHUB_RUN_ID": "456", "GITHUB_RUN_ATTEMPT": "1",
            "GITHUB_OUTPUT": str(self.root / "step-output"),
            "GITHUB_STEP_SUMMARY": str(self.root / "summary.md"),
        }

        def build(options):
            publish = options.output / "publish"
            publish.mkdir(parents=True)
            archive = publish / auto.release.archive_name(options)
            archive.write_bytes(b"synthetic built archive")
            feed = publish / "appcast.xml"
            feed.write_bytes(self.feed_bytes(options.build))
            manifest = {"version": options.version, "build": options.build,
                "previous_build": options.previous_build, "signing_mode": options.signing_mode,
                "feed_url": options.feed_url, "archive_url": options.download_url_prefix + archive.name,
                "archive_signature": "synthetic", "sha256": {
                    path.name: auto.release.file_sha256(path) for path in (archive, feed)}}
            (publish / "release.json").write_text(json.dumps(manifest))

        def external(command, **kwargs):
            if "build_installer.py" in str(command[1]):
                Path(command[-1]).write_bytes(b"synthetic installer")
            return "synthetic"

        with patch.dict(auto.os.environ, self.environment, clear=True), \
             patch.object(auto.release, "ROOT", self.root), \
             patch.object(auto, "R2Store", return_value=self.store), \
             patch.object(auto.release, "prepare", side_effect=build) as build_call, \
             patch.object(auto.release, "run", side_effect=external), \
             patch.object(auto, "verify_feed"), patch.object(auto, "verify_archive"), \
             patch.object(auto, "verify_public", side_effect=self.verify_public), \
             contextlib.redirect_stderr(io.StringIO()):
            self.build_call = build_call
            yield

    def prepare_split(self):
        self.assertEqual(auto.main(["--version", "0.1.1", "--prepare-only"]), 0)
        key, output = (self.root / "step-output").read_text().strip().split("=", 1)
        self.assertEqual(key, "prepared-output")
        return Path(output)

    def test_prepare_only_reserves_and_builds_without_publication(self):
        with self.split_release():
            output = self.prepare_split()
            self.assertTrue((output / "publish/release.json").is_file())
            self.assertEqual(self.store.writes, [self.prefix + "release-counter.json"])
            self.assertEqual(self.store.objects[self.prefix + "appcast.xml"], self.feed_bytes(1))
            self.build_call.assert_called_once()
            self.assertFalse((self.root / "summary.md").exists())

    def test_publish_prepared_reuses_build_counter_and_records_manifest_summary(self):
        with self.split_release():
            output = self.prepare_split()
            self.assertEqual(auto.main(["--version", "0.1.1", "--publish-prepared", str(output)]), 0)
            self.build_call.assert_called_once()
            self.assertEqual(self.store.writes.count(self.prefix + "release-counter.json"), 1)
            stored = json.loads(self.store.objects[self.prefix + "releases/0.1.1-2.json"])
            self.assertEqual((stored["source_revision"], stored["version"], stored["build"]), ("f" * 40, "0.1.1", 2))
            self.assertEqual(self.store.writes[-1], self.prefix + "appcast.xml")
            self.assertIn("msgblast 0.1.1 (2) published", (self.root / "summary.md").read_text())
            self.assertIn("Ad-hoc app signing", (self.root / "summary.md").read_text())

    def test_publish_prepared_rejects_changed_source_version_feed_and_artifact(self):
        for change in ("source", "version", "feed", "artifact", "signing-history"):
            with self.subTest(change=change), self.split_release():
                # Each case owns fresh storage and files, as a separate release run would.
                output = self.prepare_split()
                args = ["--version", "0.1.1", "--publish-prepared", str(output)]
                if change == "source":
                    auto.os.environ["GITHUB_SHA"] = "e" * 40
                elif change == "version":
                    args[1] = "0.1.2"
                elif change == "feed":
                    self.store.objects[self.prefix + "appcast.xml"] = self.feed_bytes(1) + b" "
                elif change == "signing-history":
                    self.published_manifest(1, "developer-id")
                else:
                    (output / "publish/msgblast-0.1.1-2.zip").write_bytes(b"tampered")
                writes = list(self.store.writes)
                self.assertEqual(auto.main(args), 1)
                self.assertEqual(self.store.writes, writes)
                self.build_call.assert_called_once()
            # Reset the synthetic run, never live state.
            self.store = Store()
            shutil.rmtree(self.root / "build")
            (self.root / "step-output").unlink()

    def test_split_modes_are_mutually_exclusive_and_still_require_version(self):
        for args in (["--prepare-only"], ["--publish-prepared", "output"],
                     ["--version", "0.1.1", "--prepare-only", "--publish-prepared", "output"]):
            with self.subTest(args=args), contextlib.redirect_stderr(io.StringIO()), \
                 patch.object(auto, "R2Store") as storage:
                with self.assertRaises(SystemExit) as error:
                    auto.main(args)
                self.assertEqual(error.exception.code, 2)
                storage.assert_not_called()

    def test_publish_prepared_reauthenticates_feed_and_artifact_signatures(self):
        with self.split_release():
            output = self.prepare_split()
            writes = list(self.store.writes)
            args = ["--version", "0.1.1", "--publish-prepared", str(output)]
            for verifier in ("verify_feed", "verify_archive"):
                with self.subTest(verifier=verifier), patch.object(auto, verifier,
                        side_effect=auto.ReleaseError("Bad signature")) as verification:
                    self.assertEqual(auto.main(args), 1)
                    verification.assert_called()
                    self.assertEqual(self.store.writes, writes)
            self.build_call.assert_called_once()

    def test_missing_developer_id_configuration_cannot_fall_back_or_reserve_a_build(self):
        self.key_file.write_text(base64.b64encode(b"0" * 32).decode())
        environment = {"MSGBLAST_SIGNING_MODE": "developer-id",
            "MSGBLAST_PUBLIC_BASE_URL": self.base, "MSGBLAST_ED_KEY_FILE": str(self.key_file),
            "MSGBLAST_SPARKLE_BIN": str(self.tools), "MSGBLAST_PUBLIC_KEY": "fixture-public-key",
            "MSGBLAST_R2_ACCOUNT_ID": "a" * 32, "MSGBLAST_R2_BUCKET": "msgblast-releases",
            "AWS_ACCESS_KEY_ID": "fixture-access", "AWS_SECRET_ACCESS_KEY": "fixture-secret"}
        with patch.dict(auto.os.environ, environment, clear=True), \
             patch.object(auto, "R2Store") as storage, \
             contextlib.redirect_stderr(io.StringIO()):
            self.assertEqual(auto.main(["--version", "0.6.1"]), 1)
        storage.assert_not_called()

    def test_main_rejects_malformed_key_before_storage_or_signing_without_echo(self):
        environment = {
            "MSGBLAST_PUBLIC_BASE_URL": self.base,
            "MSGBLAST_ED_KEY_FILE": str(self.key_file),
            "MSGBLAST_SPARKLE_BIN": str(self.tools),
            "MSGBLAST_PUBLIC_KEY": "unused public key",
            "MSGBLAST_R2_ACCOUNT_ID": "a" * 32,
            "MSGBLAST_R2_BUCKET": "msgblast-releases",
            "AWS_ACCESS_KEY_ID": "synthetic-access",
            "AWS_SECRET_ACCESS_KEY": "synthetic-secret",
        }
        self.store.objects[self.prefix + "appcast.xml"] = self.feed_bytes(1)
        for seed in ("SYNTHETIC-NONKEY-LOGGING-MARKER", "YWJjZA=="):
            with self.subTest(seed_format="non-base64" if "MARKER" in seed else "wrong-length"):
                self.key_file.write_text(seed)
                error = io.StringIO()
                output = io.StringIO()
                with patch.dict(auto.os.environ, environment, clear=True), \
                     patch.object(auto, "R2Store", return_value=self.store), \
                     patch.object(self.store, "get", wraps=self.store.get) as read, \
                     patch.object(auto, "verify_feed") as signing, \
                     patch.object(auto.release, "run") as command, \
                     contextlib.redirect_stdout(output), contextlib.redirect_stderr(error):
                    result = auto.main(["--version", "0.1.1"])
                self.assertEqual(result, 1)
                read.assert_not_called()
                signing.assert_not_called()
                command.assert_not_called()
                self.assertIn("base64 32-byte private seed", error.getvalue())
                self.assertNotIn(seed, error.getvalue())
                self.assertNotIn(seed, output.getvalue())

    def test_version_tag_and_public_base_are_validated(self):
        self.assertEqual(auto.release_version("v0.1.1"), "0.1.1")
        self.assertEqual(auto.object_prefix(self.base), self.prefix)
        for value in ["v../../main", "v0.1.0;evil", "latest"]:
            with self.assertRaises(auto.ReleaseError):
                auto.release_version(value)
        for value in ["http://updates.example/", "https://user:password@updates.example/", "https://updates.example/?token=x", "https://updates.example/../"]:
            with self.assertRaises(auto.ReleaseError):
                auto.object_prefix(value)


if __name__ == "__main__":
    unittest.main()
