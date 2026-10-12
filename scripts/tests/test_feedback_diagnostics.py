"""Architectural privacy boundaries that complement native behavioral tests.

DiagnosticReportTests exercises archive contents and sanitization;
storage_feedback.swift exercises explicit send, retry, deduplication, and cancel.
These guards prevent collectors from acquiring private source data in the first place.
"""
from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[2]
CORE = ROOT / "msgblast/Core/DiagnosticReport.swift"
FACTS = ROOT / "msgblast/App/FeedbackFacts.swift"
VIEW = ROOT / "msgblast/Windows/FeedbackView.swift"
IMPLEMENTATION = [CORE, FACTS, VIEW]

KEYS = [
    "agentCount", "attachmentCount", "buildNumber", "bundleIdentifier", "comparisonCount",
    "fixtureMode", "hasDraft", "lastErrorCategory", "messagesStatus", "operatingSystem",
    "permissionStage", "personalAgent", "stateFileBytes", "stateFilePresent", "supportFolder",
    "updatesEnabled", "updatesReason", "variant", "version", "webProviderCounts", "windowStyle",
]
class FeedbackDiagnosticTests(unittest.TestCase):
    def test_collector_and_form_do_not_acquire_private_data_or_transport(self):
        for path in IMPLEMENTATION:
            text = path.read_text()
            for forbidden in ["URLSession", "Data(contentsOf", "String(contentsOf", "sqlite", "CNContact", "WKWebsiteDataStore", "HTTPCookie"]:
                self.assertNotIn(forbidden, text, f"{path.name} references {forbidden}")

    def test_diagnostic_schema_keeps_the_reviewed_allowlist_and_metadata_only_collector(self):
        core = CORE.read_text()
        facts = FACTS.read_text()
        for key in KEYS:
            self.assertIn(f'"{key}"', core)
        self.assertIn("static let diagnosticKeys = [", core)
        self.assertNotIn("local.load", facts)
        self.assertNotIn("webAgents", facts)
