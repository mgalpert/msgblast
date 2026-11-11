"""Local test copies keep unique names while reusing a few grant-holding identities."""
import importlib.util
import json
from pathlib import Path
import plistlib
import sys
import tempfile
import unittest
from unittest import mock


ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))
spec = importlib.util.spec_from_file_location("build_test_app", ROOT / "scripts/build_test_app.py")
tool = importlib.util.module_from_spec(spec)
spec.loader.exec_module(tool)


def make_copy(root, name, slot):
    app = Path(root) / name / f"msgblast Dev ({name}).app"
    (app / "Contents").mkdir(parents=True)
    with (app / "Contents/Info.plist").open("wb") as file:
        plistlib.dump({"CFBundleIdentifier": tool.BUNDLE_PREFIX + slot}, file)
    return app


class VariantTests(unittest.TestCase):
    def test_name_is_visible_and_unique_but_bundle_id_is_the_slot(self):
        variant = tool.test_variant("Fixes 1111", "b")
        self.assertEqual(variant["display_name"], "msgblast Dev (Fixes 1111)")
        self.assertEqual(variant["app_name"], "msgblast Dev (Fixes 1111).app")
        self.assertEqual(variant["bundle_id"], "com.msgblast.development.test-b")
        self.assertEqual(variant["support_directory"], "msgblast-Dev-Fixes-1111")
        self.assertFalse(variant["demo"])
        self.assertEqual(tool.preview.VARIANTS["development"]["bundle_id"], "com.msgblast.development")

    def test_support_folder_passes_the_app_sanitizer_rule(self):
        import re
        for name in ("iOS Web Shots 1111", "a" * 40, "x.y_z"):
            folder = tool.test_variant(name, "a")["support_directory"]
            self.assertRegex(folder, r"^msgblast-[A-Za-z0-9][A-Za-z0-9-]{0,40}$")

    def test_rejects_unsafe_names_and_unknown_slots(self):
        for name in ("", "../x", "a/b", "a" * 41):
            with self.assertRaises(ValueError):
                tool.test_variant(name, "a")
        with self.assertRaises(ValueError):
            tool.test_variant("ok", "z")

    def test_production_identity_is_never_a_slot(self):
        self.assertTrue(all(tool.BUNDLE_PREFIX + slot != "com.msgblast.mac" for slot in tool.SLOTS))


class SlotTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)

    def tearDown(self):
        self.temporary.cleanup()

    def running(self, *apps):
        return [str(app) + "/Contents/MacOS/msgblast" for app in apps]

    def test_rebuild_keeps_its_slot(self):
        a = make_copy(self.root, "One", "a")
        b = make_copy(self.root, "Two", "c")
        self.assertEqual(tool.choose_slot(b, tool.installed(self.root), self.running(a)), "c")

    def test_new_copy_skips_slots_with_a_running_copy(self):
        a = make_copy(self.root, "One", "a")
        make_copy(self.root, "Two", "b")
        new = self.root / "Three" / "msgblast Dev (Three).app"
        self.assertEqual(tool.choose_slot(new, tool.installed(self.root), self.running(a)), "b")

    def test_refuses_to_replace_a_running_copy_or_share_a_busy_slot(self):
        a = make_copy(self.root, "One", "a")
        with self.assertRaisesRegex(RuntimeError, "quit it"):
            tool.choose_slot(a, tool.installed(self.root), self.running(a))
        new = self.root / "Two" / "msgblast Dev (Two).app"
        with self.assertRaisesRegex(RuntimeError, "in use"):
            tool.choose_slot(new, tool.installed(self.root), self.running(a), "a")

    def test_all_slots_busy(self):
        apps = [make_copy(self.root, f"N{slot}", slot) for slot in tool.SLOTS]
        new = self.root / "New" / "msgblast Dev (New).app"
        with self.assertRaisesRegex(RuntimeError, "Every slot"):
            tool.choose_slot(new, tool.installed(self.root), self.running(*apps))

    def test_ignores_older_copies_with_their_own_bundle_ids(self):
        app = self.root / "Old" / "msgblast Dev (Old).app"
        (app / "Contents").mkdir(parents=True)
        with (app / "Contents/Info.plist").open("wb") as file:
            plistlib.dump({"CFBundleIdentifier": "com.msgblast.development.old"}, file)
        self.assertEqual(tool.installed(self.root), {})


LISTING = ('  1) 1111111111111111111111111111111111111111 "Apple Development: Example (AAAA)"\n'
           '  2) 2222222222222222222222222222222222222222 "Apple Development: Other (BBBB)"\n'
           '     2 valid identities found\n')


class IdentityTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.config = Path(self.temporary.name) / "msgblast/test-builds.json"
        patcher = mock.patch.object(tool.subprocess, "run",
                                    return_value=mock.Mock(stdout=LISTING))
        patcher.start()
        self.addCleanup(patcher.stop)

    def tearDown(self):
        self.temporary.cleanup()

    def test_first_choice_is_saved_and_reused(self):
        name = "Apple Development: Example (AAAA)"
        self.assertEqual(tool.signing_identity(name, self.config), "1" * 40)
        self.assertEqual(json.loads(self.config.read_text()), {"identity_name": name})
        self.assertEqual(tool.signing_identity(None, self.config), "1" * 40)

    def test_refuses_a_different_certificate_later(self):
        tool.signing_identity("Apple Development: Example (AAAA)", self.config)
        with self.assertRaisesRegex(RuntimeError, "resets every grant"):
            tool.signing_identity("Apple Development: Other (BBBB)", self.config)

    def test_requires_an_apple_development_certificate(self):
        for name in (None, "Developer ID Application: Example (AAAA)", "Apple Development: Missing (CCCC)"):
            with self.assertRaises(RuntimeError):
                tool.signing_identity(name, self.config)
        self.assertFalse(self.config.exists())


class RequirementTests(unittest.TestCase):
    def check(self, requirement):
        output = f"Executable=/x\ndesignated => {requirement}\n"
        with mock.patch.object(tool.builder, "run", return_value=output):
            return tool.builder.local_requirement(Path("/tmp/x.app"), "com.msgblast.development.test-a")

    def test_accepts_certificate_requirement(self):
        requirement = ('identifier "com.msgblast.development.test-a" and anchor apple generic and '
                       'certificate leaf[subject.CN] = "Apple Development: Example (AAAA)"')
        self.assertEqual(self.check(requirement), requirement)

    def test_rejects_ad_hoc_or_other_bundle(self):
        for requirement in ('cdhash H"abcd"',
                            'identifier "com.msgblast.development" and anchor apple generic and certificate leaf[subject.CN] = "x"'):
            with self.assertRaises(RuntimeError):
                self.check(requirement)


if __name__ == "__main__":
    unittest.main()
