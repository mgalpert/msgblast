"""Automated publication contracts; storage and network are synthetic."""
import importlib.util
import base64
import contextlib
import io
import hashlib
import json
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
                "<sparkle:version>" + str(build) + "</sparkle:version></item></channel></rss>").encode()

    def snapshot(self):
        self.store.objects[self.prefix + "appcast.xml"] = self.feed_bytes(1)
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
            snapshot = auto.current_release(self.store, self.prefix, self.root, self.tools, self.key_file)
        self.assertEqual(snapshot["build"], 7)
        verify.assert_called_once()
        with patch.object(self.store, "get", side_effect=auto.ReleaseError("Access denied")):
            with self.assertRaisesRegex(auto.ReleaseError, "Access denied"):
                auto.current_release(self.store, self.prefix, self.root, self.tools, self.key_file)

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
        # A deterministic fixture seed never authenticates production artifacts.
        self.key_file.write_text(base64.b64encode(b"0" * 32).decode())
        self.store.objects[self.prefix + "appcast.xml"] = self.feed_bytes(1)
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

        def prepare(options):
            publish = options.output / "publish"
            publish.mkdir(parents=True)
            (publish / "release.json").write_text(json.dumps({
                "version": options.version, "build": options.build,
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
        self.assertEqual(options.signing_mode, "ad-hoc")
        self.assertIsNone(options.identity)
        self.assertIsNone(options.notary_profile)
        self.assertEqual(options.output, (self.root / "build/releases/0.1.0-2-123-2").resolve())
        publication.assert_called_once()
        self.assertEqual(json.loads(self.store.objects[self.prefix + "release-counter.json"])["build"], 2)
        self.assertIn(revision, summary.read_text())
        self.assertIn("msgblast 0.1.0 (2) published", summary.read_text())
        self.assertIn(self.base + "downloads/msgblast-0.1.0-2.zip", summary.read_text())

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
