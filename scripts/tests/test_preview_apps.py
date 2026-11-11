"""Preview planning stays free of production publishing and preserves committed icons."""
import argparse
import contextlib
import importlib.util
import io
from datetime import datetime
from pathlib import Path
import binascii
import shutil
import struct
import sys
import tempfile
import unittest
from unittest import mock
import zlib


ROOT = Path(__file__).resolve().parents[2]


def load(name):
    path = ROOT / "scripts" / f"{name}.py"
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


preview = load("preview_apps")
evidence = load("check_pr_evidence")


def load_builder():
    sys.path.insert(0, str(ROOT / "scripts"))
    return load("build_preview_apps")


class PreviewPlanTests(unittest.TestCase):
    def test_committed_icons_stay_green_and_blue(self):
        preview.assert_committed_icons_unchanged()

    def test_committed_icon_rejects_changed_artwork_with_the_same_background(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            original_root = preview.ROOT
            for source in (preview.POLISHED, preview.BLUE_GREEN, preview.BLUE,
                           preview.ROOT / "msgblast/AppIcon.icon",
                           preview.ROOT / "msgblast/AppIconDemo.icon"):
                shutil.copytree(source, root / source.relative_to(original_root))
            artwork = next((root / "msgblast/AppIcon.icon/Assets").iterdir())
            artwork.write_bytes(artwork.read_bytes() + b"changed artwork")
            with mock.patch.object(preview, "ROOT", root), \
                 mock.patch.object(preview, "POLISHED", root / preview.POLISHED.relative_to(original_root)), \
                 mock.patch.object(preview, "BLUE_GREEN", root / preview.BLUE_GREEN.relative_to(original_root)), \
                 mock.patch.object(preview, "BLUE", root / preview.BLUE.relative_to(original_root)):
                with self.assertRaisesRegex(RuntimeError, "production artwork"):
                    preview.assert_committed_icons_unchanged()

    def test_development_artwork_is_applied_only_in_an_isolated_workspace(self):
        before = preview.icon_fill(preview.ROOT / "msgblast/AppIcon.icon")
        with tempfile.TemporaryDirectory() as temporary:
            workspace = Path(temporary)
            shutil.copytree(preview.ROOT / "msgblast/AppIcon.icon", workspace / "msgblast/AppIcon.icon")
            shutil.copytree(preview.ROOT / "msgblast/AppIconDemo.icon", workspace / "msgblast/AppIconDemo.icon")
            preview.stage_icons(workspace)
            self.assertEqual(preview.icon_fill(workspace / "msgblast/AppIcon.icon"), preview.icon_fill(preview.BLUE_GREEN))
            self.assertEqual(preview.icon_fill(workspace / "msgblast/AppIconDemo.icon"), preview.icon_fill(preview.BLUE))
        self.assertEqual(preview.icon_fill(preview.ROOT / "msgblast/AppIcon.icon"), before)
        with self.assertRaises(RuntimeError):
            preview.stage_icons(preview.ROOT)

    def test_fixture_mode_is_explicit_and_production_identity_is_rejected(self):
        info = {"CFBundleIdentifier": "com.msgblast.mac", "CFBundleName": "msgblast"}
        demo = preview.configure_info(info, preview.VARIANTS["demo"], "a" * 40)
        self.assertTrue(demo["msgblastDemo"])
        self.assertEqual(demo["CFBundleIdentifier"], "com.msgblast.demo")
        self.assertEqual(demo["msgblastSupportDirectory"], "msgblast-Demo")
        self.assertEqual(demo["SUFeedURL"], "")
        self.assertEqual(demo["CFBundleIconFile"], "AppIconDemo")
        self.assertFalse(demo["SUEnableAutomaticChecks"])
        development = preview.configure_info(info, preview.VARIANTS["development"], "b" * 40)
        self.assertEqual(development["CFBundleIconFile"], "AppIcon")
        self.assertFalse(development["msgblastDemo"])
        self.assertEqual(development["CFBundleIdentifier"], "com.msgblast.development")
        self.assertEqual(development["msgblastSupportDirectory"], "msgblast-Dev")
        self.assertNotEqual(development["CFBundleIdentifier"], demo["CFBundleIdentifier"])
        preview.verify_configured_info(development, preview.VARIANTS["development"], "b" * 40)
        self.assertFalse(development["SUAllowsAutomaticUpdates"])
        bad = dict(preview.VARIANTS["development"])
        bad["bundle_id"] = "com.msgblast.mac"
        with self.assertRaises(RuntimeError):
            preview.configure_info(info, bad, "a" * 40)

    def test_development_remote_is_a_separate_live_development_identity(self):
        info = {"CFBundleIdentifier": "com.msgblast.mac", "CFBundleName": "msgblast"}
        variant = preview.VARIANTS["development-remote"]
        remote = preview.configure_info(info, variant, "c" * 40)
        self.assertEqual(remote["CFBundleIdentifier"], "com.msgblast.development.remote")
        self.assertEqual(remote["CFBundleName"], "msgblast Dev Remote")
        self.assertEqual(remote["CFBundleDisplayName"], "msgblast Dev Remote")
        self.assertEqual(remote["msgblastSupportDirectory"], "msgblast-Dev-Remote")
        self.assertEqual(remote["msgblastPreviewVariant"], "development-remote")
        self.assertEqual(remote["CFBundleIconFile"], "AppIcon")
        self.assertFalse(remote["msgblastDemo"])
        self.assertTrue(remote["msgblastDisableUpdates"])
        self.assertEqual(remote["SUFeedURL"], "")
        self.assertFalse(remote["SUAllowsAutomaticUpdates"])
        preview.verify_configured_info(remote, variant, "c" * 40)
        self.assertEqual(preview.expected_icon_color(variant), "blue-green")
        self.assertEqual(variant["icon_source"], preview.BLUE_GREEN)
        self.assertEqual(variant["app_name"], "msgblast Dev Remote.app")
        self.assertEqual(variant["artifact_prefix"], "msgblast-dev-remote")
        development = preview.VARIANTS["development"]
        for key in ("bundle_id", "app_name", "support_directory", "artifact_prefix"):
            self.assertNotEqual(variant[key], development[key])
        with self.assertRaises(RuntimeError):
            preview.verify_configured_info(preview.configure_info(info, development, "c" * 40), variant, "c" * 40)

    def test_all_keeps_building_only_dev_and_demo(self):
        self.assertEqual([variant["id"] for variant in preview.selected_variants("all")], ["development", "demo"])
        self.assertEqual([variant["id"] for variant in preview.selected_variants("development-remote")], ["development-remote"])

    def test_default_build_stamp_uses_the_local_minute(self):
        build = load_builder()
        fixed = datetime(2026, 10, 29, 10, 18, 59)
        self.assertEqual(build.resolve_build_stamp(None, now=fixed), "20261029-1018")
        self.assertRegex(build.resolve_build_stamp(None), r"^\d{8}-\d{4}$")
        self.assertRegex(build.require_build_stamp(argparse.ArgumentParser(), None), r"^\d{8}-\d{4}$")

    def test_build_stamp_none_keeps_today_names(self):
        build = load_builder()
        self.assertIsNone(build.resolve_build_stamp("none"))
        self.assertIsNone(build.require_build_stamp(argparse.ArgumentParser(), "none"))
        original = preview.VARIANTS["development"]
        variant = preview.stamped(original, None)
        self.assertIs(variant, original)
        self.assertEqual(variant["app_name"], "msgblast Dev.app")
        self.assertEqual(variant["bundle_name"], "msgblast Dev")
        self.assertEqual(variant["display_name"], "msgblast Dev")
        info = preview.configure_info({"CFBundleName": "msgblast"}, variant, "a" * 40)
        self.assertNotIn("msgblastBuildStamp", info)
        self.assertEqual(build.archive_name(variant, "abcdef1234567890ffff"), "msgblast-dev-abcdef123456.zip")

    def test_invalid_build_stamp_is_rejected(self):
        build = load_builder()
        parser = argparse.ArgumentParser(prog="build_preview_apps.py")
        for stamp in ("", "bad stamp", "-leading", "a" * 33, "stamp/slash", "."):
            captured = io.StringIO()
            with contextlib.redirect_stderr(captured), self.assertRaises(SystemExit):
                build.require_build_stamp(parser, stamp)
            self.assertIn("must match ^[A-Za-z0-9][A-Za-z0-9._-]{0,31}$, or be none", captured.getvalue())
        self.assertEqual(build.require_build_stamp(parser, "20261029-1018"), "20261029-1018")
        self.assertEqual(build.require_build_stamp(parser, "a" * 32), "a" * 32)
        self.assertEqual(build.require_build_stamp(parser, "a.b_c-1"), "a.b_c-1")

    def test_stamp_changes_visible_names_and_leaves_identity(self):
        build = load_builder()
        stamp = "20261029-1018"
        sha = "abcdef1234567890" + ("f" * 24)
        info = {"CFBundleIdentifier": "com.msgblast.mac", "CFBundleName": "msgblast"}
        expectations = {
            "development": ("msgblast Dev", "msgblast-dev", "com.msgblast.development", "msgblast-Dev"),
            "demo": ("msgblast Demo", "msgblast-demo", "com.msgblast.demo", "msgblast-Demo"),
            "development-remote": ("msgblast Dev Remote", "msgblast-dev-remote", "com.msgblast.development.remote", "msgblast-Dev-Remote"),
        }
        for key, (base_name, prefix, bundle_id, support) in expectations.items():
            original = preview.VARIANTS[key]
            variant = preview.stamped(original, stamp)
            self.assertIsNot(variant, original)
            self.assertEqual(original["app_name"], base_name + ".app")
            self.assertEqual(original["bundle_id"], bundle_id)
            self.assertEqual(original["support_directory"], support)
            self.assertEqual(variant["app_name"], f"{base_name} {stamp}.app")
            self.assertEqual(variant["bundle_name"], f"{base_name} {stamp}")
            self.assertEqual(variant["display_name"], f"{base_name} {stamp}")
            self.assertEqual(variant["bundle_id"], bundle_id)
            self.assertEqual(variant["support_directory"], support)
            self.assertEqual(variant["build_stamp"], stamp)
            configured = preview.configure_info(info, variant, sha)
            self.assertEqual(configured["CFBundleName"], f"{base_name} {stamp}")
            self.assertEqual(configured["CFBundleDisplayName"], f"{base_name} {stamp}")
            self.assertEqual(configured["msgblastBuildStamp"], stamp)
            self.assertEqual(configured["CFBundleIdentifier"], bundle_id)
            self.assertEqual(configured["msgblastSupportDirectory"], support)
            preview.verify_configured_info(configured, variant, sha)
            self.assertEqual(build.archive_name(variant, sha), f"{prefix}-{sha[:12]}-{stamp}.zip")
            self.assertIn(variant["app_name"], build.instructions(variant))
        remote = preview.stamped(preview.VARIANTS["development-remote"], stamp)
        self.assertIn("msgblast Dev Remote 20261029-1018.app", build.instructions(remote))

    def test_workspace_copy_refuses_the_source_tree(self):
        with self.assertRaises(RuntimeError):
            preview.copy_workspace(preview.ROOT / "build-preview-inside")

    def test_compiled_icon_colors_distinguish_the_three_artworks(self):
        self.assertEqual(preview.classify_icon_color(22, 196, 51), "green")
        self.assertEqual(preview.classify_icon_color(64, 140, 143), "blue-green")
        self.assertEqual(preview.classify_icon_color(44, 23, 193), "blue")
        self.assertEqual(preview.expected_icon_color(preview.VARIANTS["development"]), "blue-green")
        self.assertEqual(preview.expected_icon_color(preview.VARIANTS["demo"]), "blue")

    def test_icns_sampling_uses_the_preferred_png_and_stable_points(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "AppIcon.icns"
            path.write_bytes(icns_file([
                ("ic08", solid_png(32, (22, 196, 51, 255))),
                ("ic10", solid_png(64, (64, 140, 143, 255))),
            ]))
            red, green, blue, representation = preview.sample_icns(path)
            self.assertEqual(representation, "ic10")
            self.assertEqual((round(red), round(green), round(blue)), (64, 140, 143))
            self.assertEqual(preview.classify_icon_color(red, green, blue), "blue-green")
            smaller = Path(temporary) / "AppIconDemo.icns"
            smaller.write_bytes(icns_file([("ic08", solid_png(40, (44, 23, 193, 255)))]))
            _, _, _, fallback = preview.sample_icns(smaller)
            self.assertEqual(fallback, "ic08")
            self.assertEqual(preview.classify_icon_color(*preview.sample_icns(smaller)[:3]), "blue")

    def test_icns_sampling_walks_inward_from_a_transparent_coordinate(self):
        width = height = 50
        rows = []
        for y in range(height):
            row = bytearray()
            for x in range(width):
                opaque = x >= 8
                row.extend((44, 23, 193, 255 if opaque else 0))
            rows.append(row)
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "edge.icns"
            path.write_bytes(icns_file([("ic07", png_rows(rows))]))
            red, green, blue, representation = preview.sample_icns(path)
            self.assertEqual(representation, "ic07")
            self.assertEqual((round(red), round(green), round(blue)), (44, 23, 193))

    def test_icns_sampling_reads_only_the_stable_coordinates(self):
        side = 100
        points = {
            (12, 50): (64, 140, 143, 255),
            (88, 50): (64, 140, 143, 255),
            (50, 12): (64, 140, 143, 255),
            (50, 88): (64, 140, 143, 255),
        }
        rows = []
        for y in range(side):
            row = bytearray()
            for x in range(side):
                row.extend(points.get((x, y), (240, 240, 240, 255)))
            rows.append(row)
        filtered = bytearray()
        channels = 4
        for row in rows:
            filtered.append(1)
            for index, value in enumerate(row):
                left = row[index - channels] if index >= channels else 0
                filtered.append((value - left) & 255)
        raw = zlib.compress(bytes(filtered))
        header = struct.pack(">IIBBBBB", side, side, 8, 6, 0, 0, 0)
        png = b"\x89PNG\r\n\x1a\n" + png_chunk(b"IHDR", header) + png_chunk(b"IDAT", raw) + png_chunk(b"IEND", b"")
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "points.icns"
            path.write_bytes(icns_file([("ic09", png)]))
            red, green, blue, representation = preview.sample_icns(path)
            self.assertEqual(representation, "ic09")
            self.assertEqual((round(red), round(green), round(blue)), (64, 140, 143))

    def test_icns_sampling_rejects_a_file_without_a_png_representation(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "raw.icns"
            path.write_bytes(icns_file([("ic04", b"not-a-png")]))
            with self.assertRaises(RuntimeError):
                preview.sample_icns(path)

    def test_compiled_icon_follows_the_selected_resource_name(self):
        with tempfile.TemporaryDirectory() as temporary:
            app = Path(temporary) / "msgblast Demo.app"
            resources = app / "Contents/Resources"
            resources.mkdir(parents=True)
            demo_icon = resources / "AppIconDemo.icns"
            dev_icon = resources / "AppIcon.icns"
            demo_icon.write_bytes(b"demo-icon")
            dev_icon.write_bytes(b"dev-icon")
            outside = Path(temporary) / "AppIconDemo.icns"
            outside.write_bytes(b"outside")
            (resources / "escape.icns").symlink_to(outside)
            demo = preview.compiled_icon_path(app, {"CFBundleIconFile": "AppIconDemo"}, "AppIconDemo")
            self.assertEqual(demo, demo_icon.resolve())
            suffixed = preview.compiled_icon_path(app, {"CFBundleIconFile": "AppIconDemo.icns"}, "AppIconDemo")
            self.assertEqual(suffixed, demo_icon.resolve())
            fallback = preview.compiled_icon_path(app, {}, "AppIcon")
            self.assertEqual(fallback, dev_icon.resolve())
            self.assertNotEqual(demo.name, fallback.name)
            with self.assertRaises(RuntimeError):
                preview.compiled_icon_path(app, {"CFBundleIconFile": "../AppIconDemo"}, "AppIconDemo")
            with self.assertRaises(RuntimeError):
                preview.compiled_icon_path(app, {"CFBundleIconFile": "AppIcon"}, "AppIconDemo")
            with self.assertRaises(RuntimeError):
                preview.compiled_icon_path(app, {"CFBundleIconFile": "escape"}, "escape")
            with self.assertRaises(RuntimeError):
                preview.compiled_icon_path(app, {}, "MissingIcon")

    def test_manifest_records_sha_run_and_expiry_without_a_feed(self):
        document = preview.manifest("c" * 40, "https://github.com/mgalpert/msgblast/actions/runs/1", [])
        self.assertEqual(document["retention_days"], 14)
        self.assertIn("14 days", document["expiry"])
        self.assertFalse(document["production_feed_used"])
        self.assertNotIn("latest.zip", json_text(document))


def json_text(document):
    import json
    return json.dumps(document)


def png_chunk(tag, data):
    return struct.pack(">I", len(data)) + tag + data + struct.pack(">I", binascii.crc32(tag + data) & 0xFFFFFFFF)


def png_rows(rows):
    raw = b"".join(b"\x00" + bytes(row) for row in rows)
    height = len(rows)
    width = len(rows[0]) // 4
    header = struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0)
    signature = b"\x89PNG\r\n\x1a\n"
    return signature + png_chunk(b"IHDR", header) + png_chunk(b"IDAT", zlib.compress(raw)) + png_chunk(b"IEND", b"")


def solid_png(side, rgba):
    pixel = bytes(rgba)
    return png_rows([pixel * side for _ in range(side)])


def icns_file(chunks):
    body = b""
    for name, payload in chunks:
        body += name.encode("ascii") + struct.pack(">I", 8 + len(payload)) + payload
    return b"icns" + struct.pack(">I", 8 + len(body)) + body


class EvidenceGateTests(unittest.TestCase):
    def test_stable_signing_requires_apple_identity_and_team_not_a_code_hash(self):
        import sys
        sys.path.insert(0, str(ROOT / "scripts"))
        build = load("build_preview_apps")
        identity = "Developer ID Application: Test Company (ABCDEFGHIJ)"
        metadata = "Identifier=com.msgblast.development\nAuthority=" + identity + "\nTeamIdentifier=ABCDEFGHIJ\nflags=0x10000(runtime)\n"
        requirement = 'identifier "com.msgblast.development" and anchor apple generic and certificate leaf[subject.OU] = "ABCDEFGHIJ"'
        build.verify_stable_signature_text(metadata, requirement, identity, "ABCDEFGHIJ", "com.msgblast.development")
        for bad_metadata, bad_requirement in [
            (metadata.replace("ABCDEFGHIJ", "WRONGTEAM1"), requirement),
            (metadata.replace("(runtime)", "(adhoc)"), requirement),
            (metadata.replace("com.msgblast.development", "com.msgblast.mac"), requirement),
            (metadata, 'cdhash H"12345678"'),
        ]:
            with self.assertRaises(RuntimeError):
                build.verify_stable_signature_text(bad_metadata, bad_requirement, identity, "ABCDEFGHIJ", "com.msgblast.development")

    def body(self, sha):
        return f"""## Screenshots

<img alt="Preview workflow" src="https://example.com/preview.png" />

## Video

<video src="https://example.com/preview.mp4" controls></video>

Evidence-SHA: {sha}
"""

    def test_remote_embeds_for_the_reviewed_commit_pass(self):
        sha = "d" * 40
        self.assertEqual(evidence.problems(self.body(sha), sha), [])

    def test_text_placeholders_and_stale_or_local_evidence_fail(self):
        sha = "e" * 40
        self.assertTrue(evidence.problems("## Screenshots\n\nterminal output\n\n## Video\n\nno video\n", sha))
        stale = self.body("f" * 40)
        self.assertTrue(any("does not match" in item for item in evidence.problems(stale, sha)))
        local = self.body(sha).replace("https://example.com/preview.png", "file:///opt/cursor/artifacts/preview.png")
        self.assertTrue(any("local-only" in item for item in evidence.problems(local, sha)))
        placeholder = self.body(sha).replace("Preview workflow", "placeholder")
        self.assertTrue(any("placeholder" in item for item in evidence.problems(placeholder, sha)))

    def test_cursor_branch_previews_need_checksums_and_reject_the_production_zip(self):
        sha = "a" * 40
        ready = self.body(sha) + """
msgblast Dev and msgblast Demo fixture
https://github.com/mgalpert/msgblast/actions/runs/123
msgblast Dev SHA-256: """ + ("b" * 64) + """
msgblast Demo SHA-256: """ + ("c" * 64) + "\n"
        self.assertEqual(evidence.problems(ready, sha, require_preview=True), [])
        missing = self.body(sha)
        self.assertTrue(evidence.problems(missing, sha, require_preview=True))
        published = ready + "https://updates.msgblast.app/latest.zip\n"
        self.assertTrue(any("production update host" in item for item in evidence.problems(published, sha, require_preview=True)))

    def test_empty_local_and_unlabeled_evidence_does_not_pass(self):
        sha = "a" * 40
        empty = self.body(sha).replace('<video src="https://example.com/preview.mp4" controls></video>', "<video></video>")
        self.assertTrue(any("empty or local" in item for item in evidence.problems(empty, sha)))
        local_src = self.body(sha).replace("https://example.com/preview.mp4", "file:///tmp/preview.mp4")
        self.assertTrue(evidence.problems(local_src, sha))
        relative = self.body(sha).replace("https://example.com/preview.mp4", "/tmp/preview.mp4")
        self.assertTrue(any("empty or local" in item for item in evidence.problems(relative, sha)))
        attachment = self.body(sha).replace(
            '<video src="https://example.com/preview.mp4" controls></video>',
            "https://github.com/user-attachments/assets/1234",
        )
        self.assertEqual(evidence.problems(attachment, sha), [])
        one_hash = self.body(sha) + "msgblast Dev and msgblast Demo fixture\nhttps://github.com/mgalpert/msgblast/actions/runs/9\n" + ("d" * 64) + "\n"
        unlabeled = evidence.problems(one_hash, sha, require_preview=True)
        self.assertTrue(any("msgblast Dev SHA-256" in item for item in unlabeled))
        self.assertTrue(any("msgblast Demo SHA-256" in item for item in unlabeled))
        same = self.body(sha) + "msgblast Dev fixture and msgblast Demo fixture\nhttps://github.com/mgalpert/msgblast/actions/runs/9\n"
        same += "msgblast Dev SHA-256: " + ("e" * 64) + "\nmsgblast Demo SHA-256: " + ("e" * 64) + "\n"
        self.assertTrue(any("must be different" in item for item in evidence.problems(same, sha, require_preview=True)))
        dev_only = same.replace("msgblast Demo SHA-256: " + ("e" * 64), "msgblast Demo checksum missing")
        self.assertTrue(any("msgblast Demo SHA-256" in item for item in evidence.problems(dev_only, sha, require_preview=True)))

    def test_hidden_examples_do_not_satisfy_rendered_embeds(self):
        sha = "c" * 40
        hidden = f"""## Screenshots

```markdown
![hidden](https://example.com/hidden.png)
```

~~~
<img src="https://example.com/tilde.png" />
~~~

<!-- ![comment](https://example.com/comment.png) -->

`![inline](https://example.com/inline.png)`

\\![escaped](https://example.com/escaped.png)

## Video

```
https://example.com/hidden.mp4
```

<!-- <video src="https://example.com/comment.webm"></video> -->

`https://example.com/inline.mov`

\\<video src="https://example.com/escaped.mp4"></video>

Evidence-SHA: {sha}
"""
        found = evidence.problems(hidden, sha)
        self.assertTrue(any("embedded https image" in item for item in found))
        self.assertTrue(any("empty or local" in item for item in found))
        shown = hidden.replace(
            "\\![escaped](https://example.com/escaped.png)",
            "![Shown workflow](https://example.com/shown.png)\n",
        ).replace(
            "\\<video src=\"https://example.com/escaped.mp4\"></video>",
            "<video src=\"https://example.com/shown.mp4\" controls></video>\n",
        )
        self.assertEqual(evidence.problems(shown, sha), [])
        html = self.body(sha).replace(
            '<img alt="Preview workflow" src="https://example.com/preview.png" />',
            '<img alt="Preview workflow" src="https://example.com/preview.png" />\n<!-- ![nope](https://example.com/nope.png) -->\n',
        )
        self.assertEqual(evidence.problems(html, sha), [])

    def test_indented_and_pre_code_examples_are_not_embeds(self):
        sha = "b" * 40
        video = """## Video

<video src="https://example.com/preview.mp4" controls></video>
"""
        indented = f"""## Screenshots

    ![sample](https://example.test/example.png)

{video}
Evidence-SHA: {sha}
"""
        tabbed = f"""## Screenshots

\t![sample](https://example.test/example.png)

{video}
Evidence-SHA: {sha}
"""
        pre = f"""## Screenshots

<pre><code>![sample](https://example.test/example.png)</code></pre>

{video}
Evidence-SHA: {sha}
"""
        for hidden in (indented, tabbed, pre):
            found = evidence.problems(hidden, sha)
            self.assertNotEqual(found, [])
            self.assertTrue(any("embedded https image" in item for item in found))
        hidden_video = f"""## Screenshots

![Shown workflow](https://example.com/shown.png)

## Video

    https://example.com/hidden.mp4

<pre><code>https://github.com/user-attachments/assets/hidden</code></pre>

Evidence-SHA: {sha}
"""
        video_found = evidence.problems(hidden_video, sha)
        self.assertTrue(any("empty or local" in item for item in video_found))
        kept = f"""## Screenshots

    ![sample](https://example.test/example.png)

<pre><code>![sample](https://example.test/example.png)</code></pre>

![Shown workflow](https://example.com/shown.png)

{video}
Evidence-SHA: {sha}
"""
        self.assertEqual(evidence.problems(kept, sha), [])

    def test_packaging_script_stays_nonpublishing(self):
        import sys
        sys.path.insert(0, str(ROOT / "scripts"))
        source = (ROOT / "scripts/build_preview_apps.py").read_text()
        self.assertIn("--sequesterRsrc", source)
        self.assertIn("sample_icns", source)
        self.assertNotIn("sample_icon_color.swift", source)
        self.assertIn("app.rglob", source)
        self.assertIn("debug.dylib", source)
        self.assertIn("signing_order", source)
        self.assertNotIn("automate_release", source)
        self.assertNotIn("MSGBLAST_SPARKLE_PRIVATE_KEY", source)
        self.assertNotIn("latest.zip", source)
        build = load("build_preview_apps")
        demo = build.instructions(preview.VARIANTS["demo"])
        development = build.instructions(preview.VARIANTS["development"])
        self.assertIn("Fixture mode", demo)
        self.assertIn("msgblastDemo", demo)
        self.assertIn("Full Disk Access", development)
        self.assertIn("not a fixture", development)
        self.assertIn("msgblast-Dev", development)
        self.assertIn("/Applications/msgblast.app", development)
        remote = build.instructions(preview.VARIANTS["development-remote"])
        self.assertIn("msgblast Dev Remote.app", remote)
        self.assertIn("belong to com.msgblast.development.remote", remote)
        self.assertIn("msgblast-Dev-Remote", remote)
        self.assertNotIn("belong to com.msgblast.development,", remote)
        self.assertIn("belong to com.msgblast.development,", development)

    def test_main_executable_never_precedes_its_debug_dylib(self):
        import sys
        sys.path.insert(0, str(ROOT / "scripts"))
        build = load("build_preview_apps")
        app = Path("/tmp/msgblast Dev.app")
        mac = app / "Contents/MacOS"
        executable = mac / "msgblast"
        debug_dylib = mac / "msgblast.debug.dylib"
        preview_dylib = mac / "__preview.dylib"
        framework = app / "Contents/Frameworks/Sparkle.framework"
        helper = framework / "Versions/B/Autoupdate"
        # Alphabetical order is the bug: the shorter executable name comes first.
        paths = [executable, debug_dylib, preview_dylib, framework, helper]
        self.assertLess(str(executable), str(debug_dylib))
        ordered = build.signing_order(paths)
        self.assertLess(ordered.index(debug_dylib), ordered.index(executable))
        self.assertLess(ordered.index(preview_dylib), ordered.index(executable))
        self.assertLess(ordered.index(helper), ordered.index(framework))
        with tempfile.TemporaryDirectory() as temporary:
            bundle = Path(temporary) / "msgblast Dev.app"
            info = bundle / "Contents/Info.plist"
            info.parent.mkdir(parents=True)
            info.write_bytes(__import__("plistlib").dumps({"CFBundleExecutable": "msgblast"}))
            self.assertEqual(build.bundle_executable(bundle), bundle / "Contents/MacOS/msgblast")
