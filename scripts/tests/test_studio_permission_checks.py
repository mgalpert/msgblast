"""Permission results must belong to each native row, never a nearby Allowed label."""
import importlib.util
from pathlib import Path
import unittest
from unittest import mock
import subprocess
import sys

path = Path(__file__).resolve().parents[1] / "studio_permission_checks.py"
spec = importlib.util.spec_from_file_location("studio_permission_checks", path)
studio = importlib.util.module_from_spec(spec)
spec.loader.exec_module(studio)


class PermissionReceiptTests(unittest.TestCase):
    def test_stalled_cua_peer_times_out_and_is_collected(self):
        peer = subprocess.Popen([sys.executable, "-u", "-c", "import sys,time; sys.stdin.readline(); time.sleep(5)"],
                                stdin=subprocess.PIPE, stdout=subprocess.PIPE)
        with mock.patch.object(studio.subprocess, "Popen", return_value=peer), mock.patch.object(studio, "RPC_TIMEOUT", 0.05):
            with self.assertRaisesRegex(RuntimeError, "timed out"):
                studio.SpaceClient("test")
        self.assertIsNotNone(peer.poll())
        self.assertTrue(peer.stdin.closed)
        self.assertTrue(peer.stdout.closed)

    def test_old_empty_result_cannot_pass_and_failed_probe_restores_query(self):
        client = DiscoverFixture(complete_new_search=False)
        with mock.patch.object(studio.time, "sleep"):
            with self.assertRaisesRegex(RuntimeError, "fresh expected result"):
                studio.probe_contacts(client, 1, 2)
        self.assertEqual(client.query, "original unmatched query")

    def test_fresh_result_passes_and_restores_query(self):
        client = DiscoverFixture(complete_new_search=True)
        with mock.patch.object(studio.time, "sleep"):
            studio.probe_contacts(client, 1, 2)
        self.assertEqual(client.query, "original unmatched query")
    def test_rebuild_must_change_code_without_changing_identity(self):
        previous = {"designated_requirement": 'identifier "com.msgblast.development" and anchor apple generic', "code_hash": "a" * 40}
        current = dict(previous, code_hash="b" * 40)
        studio.verify_rebuild(previous, current)
        with self.assertRaisesRegex(RuntimeError, "different code hashes"):
            studio.verify_rebuild(previous, dict(previous))
        with self.assertRaisesRegex(RuntimeError, "trusted application identity"):
            studio.verify_rebuild(previous, dict(current, designated_requirement='cdhash H"1234"'))

    def test_denied_contacts_cannot_borrow_allowed_status_from_messages(self):
        tree = '''- AXStaticText = "Messages access, Find the agents you already text."
  - AXStaticText = "Allowed"
  - AXButton (Manage)
  - AXStaticText = "Contacts, Match your agents’ names and photos."
  - AXStaticText = "Off"
  - AXButton (Open Settings)
  - AXStaticText = "Sending Messages, Send messages to your agents."
  - AXStaticText = "Allowed"
'''
        self.assertEqual(studio.permission_states(tree), {"Messages access": "Allowed", "Contacts": "Off", "Sending Messages": "Allowed"})
        with self.assertRaisesRegex(RuntimeError, "Contacts"):
            studio.permission_states(tree.replace('AXStaticText = "Contacts,', 'AXStaticText = "Other,'))


class DiscoverFixture:
    """Simulated UI: clearing is delayed, and the new API response may never arrive."""
    def __init__(self, complete_new_search):
        self.query = "original unmatched query"
        self.result = studio.EMPTY_CONTACT_RESULT
        self.clear_wait = 0
        self.complete_new_search = complete_new_search

    def snapshot(self, pid, window):
        if not self.query and self.clear_wait:
            self.clear_wait -= 1
            if not self.clear_wait:
                self.result = ""
        return {"tree_markdown": self.result, "elements": [{"role": "AXTextField", "label": "Search Discover",
                                                            "value": self.query, "element_token": "s00000001:1"}]}

    def driver(self, name, **arguments):
        if name == "type_text":
            self.query = arguments["text"]
            if not self.query:
                self.clear_wait = 3
            elif self.query.startswith("msgblastpermissionprobe") and self.complete_new_search:
                self.result = studio.EMPTY_CONTACT_RESULT
