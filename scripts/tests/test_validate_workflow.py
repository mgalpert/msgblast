"""The validation workflow must stay unable to publish a release."""
from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[2]
WORKFLOW = ROOT / ".github/workflows/validate.yml"
EVIDENCE = ROOT / ".github/workflows/pr-evidence.yml"
RELEASE = ROOT / ".github/workflows/release-adhoc.yml"
INSTALL = ROOT / "scripts/cloud-agent-install.sh"
CHECKOUT = "actions/checkout@fbc6f3992d24b796d5a048ff273f7fcc4a7b6c09"


class ValidateWorkflowTests(unittest.TestCase):
    def test_validation_workflow_does_not_publish(self):
        text = WORKFLOW.read_text()
        release = RELEASE.read_text()
        self.assertNotIn("automate_release", text)
        self.assertNotIn("MSGBLAST_SPARKLE_PRIVATE_KEY", text)
        self.assertNotIn("MSGBLAST_R2_ACCESS_KEY_ID", text)
        self.assertNotIn("MSGBLAST_R2_SECRET_ACCESS_KEY", text)
        self.assertNotIn("tags:", text)
        self.assertIn("runs-on: xcode-27", text)
        self.assertIn("DEVELOPER_DIR: /Applications/Xcode_27.0.app/Contents/Developer", text)
        self.assertIn("-only-testing:msgblastTests", text)
        self.assertIn("python3 scripts/test_updates.py --derived-data build/updater-validation", text)
        self.assertIn("ASSETCATALOG_COMPILER_APPICON_NAME=AppIconDemo", text)
        self.assertIn(CHECKOUT, text)
        self.assertIn(CHECKOUT, release)
        self.assertIn("automate_release.py", release)
        self.assertIn("tags: ['v*']", release)
        self.assertIn("python3 scripts/build_preview_apps.py", text)
        self.assertEqual(text.count("ref: ${{ env.REVIEW_SHA }}"), 2)
        self.assertIn("github.event.pull_request.head.sha", text)
        self.assertIn('-resultBundlePath "$PWD/build/native-tests.xcresult"', text)
        self.assertIn("build/native-tests.log", text)
        self.assertIn("if: always()", text)
        self.assertIn("msgblast-native-tests-${{ env.REVIEW_SHA }}", text)
        self.assertIn("msgblast-icon-diagnostics-${{ env.REVIEW_SHA }}", text)
        self.assertNotIn("-quiet", text)
        self.assertIn("com.msgblast.development", (ROOT / "scripts/preview_apps.py").read_text())
        self.assertIn("com.msgblast.demo", (ROOT / "scripts/preview_apps.py").read_text())
        self.assertIn("startsWith(github.head_ref, 'cursor/')", text)
        self.assertIn("head.repo.full_name == github.repository", text)
        self.assertIn("retention-days: 14", text)
        self.assertNotIn("pull_request_target", text)
        self.assertNotIn("secrets.", text)
        evidence = EVIDENCE.read_text()
        self.assertIn("python3 scripts/check_pr_evidence.py", evidence)
        self.assertIn("types: [opened, synchronize, reopened, edited]", evidence)
        self.assertIn("--require-preview", evidence)
        self.assertNotIn("pull_request_target", evidence)
        self.assertNotIn("secrets.", evidence)
        self.assertNotIn("tags:", evidence)

    def test_signing_verification_cannot_publish_and_cleans_credentials(self):
        text = (ROOT / ".github/workflows/verify-signing.yml").read_text()
        self.assertIn("workflow_dispatch:", text)
        self.assertNotIn("pull_request:", text)
        self.assertNotIn("tags:", text)
        for name in ("automate_release.py", "release.py", "MSGBLAST_R2_ACCESS_KEY_ID", "MSGBLAST_SPARKLE_PRIVATE_KEY"):
            self.assertNotIn(name, text)
        self.assertIn('test "$GITHUB_REF_NAME" = "$DEFAULT_BRANCH"', text)
        self.assertLess(text.index("Require default-branch verification"), text.index("ci_signing.py setup"))
        self.assertLess(text.index("ci_signing.py setup"), text.index("codesign --force"))
        self.assertLess(text.index("codesign --force"), text.index("ci_signing.py cleanup"))
        self.assertIn("if: always()", text)
        self.assertNotIn("upload-artifact", text)

    def test_release_credentials_surround_publication_and_always_cleanup(self):
        text = RELEASE.read_text()
        self.assertLess(text.index("ci_signing.py setup"), text.index("automate_release.py"))
        self.assertLess(text.index("automate_release.py"), text.index("ci_signing.py cleanup"))
        self.assertIn("always() && env.MSGBLAST_SIGNING_MODE == 'developer-id'", text)
        self.assertIn("env.MSGBLAST_SIGNING_MODE == 'developer-id'", text)

    def test_stable_dev_credentials_are_manual_main_only_and_never_publish(self):
        text = (ROOT / ".github/workflows/stable-dev.yml").read_text()
        self.assertIn("workflow_dispatch:", text)
        for forbidden in ("pull_request:", "pull_request_target:", "tags:", "MSGBLAST_R2_ACCESS_KEY_ID", "MSGBLAST_SPARKLE_PRIVATE_KEY", "automate_release.py"):
            self.assertNotIn(forbidden, text)
        self.assertLess(text.index('test "$GITHUB_REF_NAME" = "$DEFAULT_BRANCH"'), text.index("ci_signing.py setup"))
        self.assertLess(text.index("ci_signing.py setup"), text.index("build_preview_apps.py"))
        self.assertIn("--variant development", text)
        self.assertIn("--signing-identity", text)
        self.assertIn("--notary-profile", text)
        self.assertIn("if: always()", text)
        self.assertIn("ci_signing.py cleanup", text)
        self.assertNotIn("--enable-dev-telemetry", text)

    def test_linux_install_pins_a_virtualenv_and_does_not_build(self):
        text = INSTALL.read_text()
        self.assertIn("import ensurepip", text)
        self.assertIn("python3-venv", text)
        self.assertIn("python3 -m venv", text)
        self.assertIn("scripts/installer-requirements.txt", text)
        self.assertIn("npm ci --prefix", text)
        self.assertNotIn("xcodebuild", text)
        self.assertNotIn("automate_release", text)
        self.assertNotIn("pip install --user", text)

    def test_testing_publisher_separates_feature_code_credentials_and_write_token(self):
        text = (ROOT / ".github/workflows/test-build.yml").read_text()
        build = text.split("\n  build:\n", 1)[1].split("\n  sign:\n", 1)[0]
        signing = text.split("\n  sign:\n", 1)[1].split("\n  publish:\n", 1)[0]
        publishing = text.split("\n  publish:\n", 1)[1]
        self.assertNotIn("secrets.", build)
        self.assertNotIn("contents: write", build + signing)
        self.assertIn("environment: test-build-signing", signing)
        self.assertIn("ref: ${{ github.sha }}", signing)
        self.assertNotIn("ref: ${{ env.REVIEW_SHA }}", signing)
        self.assertIn("if: always()", signing)
        self.assertIn("ci_signing.py cleanup", signing)
        self.assertIn("contents: write", publishing)
        self.assertNotIn("secrets.", publishing)
        for forbidden in ("pull_request:", "pull_request_target:", "tags:",
                          "MSGBLAST_SPARKLE_PRIVATE_KEY", "MSGBLAST_R2_ACCESS_KEY_ID", "automate_release.py"):
            self.assertNotIn(forbidden, text)
