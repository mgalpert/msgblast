#!/usr/bin/env python3
"""Check real Dev permissions through Cua in an already provisioned Studio Space.

Never grants/resets permissions, sends Messages, writes Contacts, or uses a local
desktop fallback. A missing grant is a failed integration check, not a fixture.
"""
import argparse
import json
import os
from pathlib import Path
import re
import select
import shlex
import subprocess
import time
import uuid

RPC_TIMEOUT = 60
EMPTY_CONTACT_RESULT = "No matching contact. Try a name, email, or full phone number."


class SpaceClient:
    def __init__(self, space):
        self.space = space
        self.sequence = 0
        self.pending = b""
        self.process = subprocess.Popen(["cua", "mcp"], stdin=subprocess.PIPE,
                                        stdout=subprocess.PIPE)
        try:
            self.rpc("initialize", {"protocolVersion": "2024-11-05", "capabilities": {},
                                   "clientInfo": {"name": "msgblast-permission-check", "version": "1"}})
        except Exception:
            self.close()
            raise

    def rpc(self, method, parameters):
        self.sequence += 1
        self.process.stdin.write((json.dumps({"jsonrpc": "2.0", "id": self.sequence,
                                             "method": method, "params": parameters}) + "\n").encode())
        self.process.stdin.flush()
        deadline = time.monotonic() + RPC_TIMEOUT
        while True:
            if b"\n" not in self.pending:
                remaining = deadline - time.monotonic()
                if remaining <= 0 or not select.select([self.process.stdout], [], [], remaining)[0]:
                    raise RuntimeError("Cua request timed out: " + method)
                chunk = os.read(self.process.stdout.fileno(), 65536)
                if not chunk:
                    raise RuntimeError("Cua connection closed")
                self.pending += chunk
                continue
            line, self.pending = self.pending.split(b"\n", 1)
            response = json.loads(line)
            if response.get("id") == self.sequence:
                if "error" in response:
                    raise RuntimeError(response["error"])
                return response["result"]

    def tool(self, name, arguments):
        result = self.rpc("tools/call", {"name": name, "arguments": arguments})
        if result.get("isError"):
            raise RuntimeError(result.get("structuredContent") or "Cua rejected " + name)
        if "structuredContent" in result:
            return result["structuredContent"]
        text = "\n".join(block.get("text", "") for block in result.get("content", []) if block["type"] == "text")
        try:
            return json.loads(text)
        except ValueError:
            return text

    def bash_json(self, program):
        result = self.tool("space_bash", {"space": self.space, "command": "python3 -c " + shlex.quote(program), "timeout": 30})
        if not isinstance(result, str) or not result.rstrip().endswith("[exit 0]"):
            raise RuntimeError("Studio preflight failed: " + str(result))
        return json.JSONDecoder().raw_decode(result)[0]

    def driver(self, name, **arguments):
        if name != "list_windows":
            arguments["session"] = "msgblast-permission-check"
        return self.tool("call_tool", {"space": self.space, "tool": name, "arguments": arguments})

    def window(self, pid, title=None):
        for _ in range(20):
            candidates = [w for w in self.driver("list_windows")["windows"]
                          if w["pid"] == pid and (w["title"] in ("", "msgblast Dev") if title is None else w["title"] == title)]
            if len(candidates) == 1:
                return candidates[0]["window_id"]
            time.sleep(0.25)
        raise RuntimeError("Studio window is missing or ambiguous")

    def snapshot(self, pid, window, **options):
        return self.driver("get_window_state", pid=pid, window_id=window,
                           include_screenshot=False, **options)

    def close(self):
        self.process.terminate()
        try:
            self.process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            self.process.kill()
            self.process.wait()
        finally:
            self.process.stdin.close()
            self.process.stdout.close()


def permission_states(markdown):
    states = {}
    for label in ("Messages access", "Contacts", "Sending Messages"):
        match = re.search(r'AXStaticText = "' + re.escape(label) + r',[^"\n]*"\s*- AXStaticText = "([^"\n]+)"', markdown)
        if not match:
            raise RuntimeError("Permission row is missing: " + label)
        states[label] = match[1]
    return states


def verify_rebuild(previous, metadata):
    if previous["designated_requirement"] != metadata["designated_requirement"]:
        raise RuntimeError("Rebuild changed the trusted application identity")
    if previous["code_hash"] == metadata["code_hash"]:
        raise RuntimeError("Rebuild retention requires two apps with different code hashes")


def discover_field(state):
    fields = [e for e in state["elements"] if e.get("role") == "AXTextField" and e.get("label") == "Search Discover"]
    if len(fields) != 1:
        raise RuntimeError("Complete onboarding before running the Contacts integration check")
    return fields[0]


def set_discover_query(client, pid, window, query):
    field = discover_field(client.snapshot(pid, window))
    client.driver("press_key", pid=pid, window_id=window, element_token=field["element_token"], key="a", modifiers=["cmd"])
    client.driver("type_text", pid=pid, window_id=window, element_token=field["element_token"], text=query)


def wait_for_contact_result(client, pid, window, query, empty_result):
    for _ in range(20):
        state = client.snapshot(pid, window)
        field = discover_field(state)
        if field.get("value", "") == query and (EMPTY_CONTACT_RESULT in state["tree_markdown"]) == empty_result:
            return
        time.sleep(0.5)
    raise RuntimeError("Native Contacts search did not return a fresh expected result")


def probe_contacts(client, pid, window):
    original_query = discover_field(client.snapshot(pid, window)).get("value", "")
    query = "msgblastpermissionprobe" + "".join(chr(ord("a") + int(c, 16)) for c in uuid.uuid4().hex)
    try:
        # Clear and observe the old result before starting a distinct lookup.
        set_discover_query(client, pid, window, "")
        wait_for_contact_result(client, pid, window, "", False)
        set_discover_query(client, pid, window, query)
        wait_for_contact_result(client, pid, window, query, True)
    finally:
        field = discover_field(client.snapshot(pid, window))
        if field.get("value", "") != original_query:
            set_discover_query(client, pid, window, original_query)
        restored = discover_field(client.snapshot(pid, window))
        if restored.get("value", "") != original_query:
            raise RuntimeError("Contacts query restoration could not be verified")


def run(options):
    client = SpaceClient(options.space)
    try:
        spaces = client.tool("list_spaces", {})
        target = next((s for s in spaces if s["id"] == options.space), {})
        if target.get("host_name") != "studio" or not target.get("host"):
            raise RuntimeError("Choose an isolated Space hosted by studio, never the host desktop")
        metadata = client.bash_json('''import json, os, plistlib, subprocess
from pathlib import Path
app = Path.home() / 'Applications/msgblast Dev.app'
info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
assert info['CFBundleIdentifier'] == 'com.msgblast.development'
assert info.get('msgblastDemo') is False
assert info['msgblastSupportDirectory'] == 'msgblast-Dev'
assert not info.get('SUFeedURL') and not info.get('SUEnableAutomaticChecks')
assert info['msgblastSourceRevision'] == ''' + repr(options.source_sha) + '''
subprocess.run(['codesign', '--verify', '--deep', '--strict', str(app)], check=True)
signature = subprocess.run(['codesign', '-dv', '--verbose=4', str(app)], capture_output=True, text=True, check=True).stderr
assert 'TeamIdentifier=' + ''' + repr(options.team_id) + ''' in signature, 'Dev must be signed by the trusted Apple team'
assert 'Authority=Developer ID Application:' in signature and '(runtime)' in signature, 'Dev requires Developer ID signing and hardened runtime'
requirement = subprocess.run(['codesign', '-dr', '-', str(app)], capture_output=True, text=True, check=True).stderr.split('designated =>', 1)[1].strip()
assert 'anchor apple generic' in requirement and 'cdhash' not in requirement
code_hash = next(line.split('=', 1)[1] for line in signature.splitlines() if line.startswith('CDHash='))
print(json.dumps({'source_revision': info['msgblastSourceRevision'], 'bundle_id': info['CFBundleIdentifier'], 'team_id': ''' + repr(options.team_id) + ''', 'designated_requirement': requirement, 'code_hash': code_hash, 'app_path': str(app)}))
''')
        if options.previous_receipt:
            previous = json.loads(options.previous_receipt.read_text())
            verify_rebuild(previous["metadata"], metadata)
        # Launching Messages lets the app check Automation without requesting consent.
        client.driver("launch_app", bundle_id="com.apple.MobileSMS")
        launched = client.driver("launch_app", bundle_id="com.msgblast.development")
        pid = launched["pid"]
        client.bash_json('''import json, subprocess
from pathlib import Path
expected = str(Path.home() / 'Applications/msgblast Dev.app/Contents/MacOS/msgblast')
actual = subprocess.check_output(['ps', '-p', ''' + repr(str(pid)) + ''', '-o', 'comm='], text=True).strip()
assert actual == expected, 'Launch Services opened a different Dev app'
processes = subprocess.check_output(['ps', '-axo', 'comm='], text=True).splitlines()
assert sum('/msgblast Dev.app/Contents/MacOS/msgblast' in p for p in processes) == 1, 'Duplicate Dev apps are running'
print(json.dumps({'exact_running_app': True}))
''')
        main = client.window(pid)
        client.snapshot(pid, main)
        client.driver("invoke_menu", pid=pid, window_id=main, path=["File", "Refresh Messages"])
        client.snapshot(pid, main)
        client.driver("invoke_menu", pid=pid, window_id=main, path=["msgblast Dev", "Settings…"])
        settings = client.window(pid, "msgblast Dev Settings")
        states = {}
        for _ in range(10):
            state = client.snapshot(pid, settings)
            states = permission_states(state["tree_markdown"])
            if all(value == "Allowed" for value in states.values()):
                break
            time.sleep(0.5)
        if any(value != "Allowed" for value in states.values()):
            raise RuntimeError("Real permissions are not provisioned: " + json.dumps(states))
        screenshot = "~/Downloads/msgblast-permissions-" + uuid.uuid4().hex + ".png"
        client.snapshot(pid, settings, screenshot_out_file=screenshot)
        client.driver("press_key", pid=pid, window_id=settings, key="w", modifiers=["cmd"])
        client.snapshot(pid, main)
        client.driver("invoke_menu", pid=pid, window_id=main, path=["View", "Show Discover"])
        probe_contacts(client, pid, main)
        receipt = {"space": options.space, "metadata": metadata, "permissions": states,
                   "contacts_api_search": "empty success", "rebuild_retention": bool(options.previous_receipt),
                   "screenshot": screenshot, "limits": "No sends or Contacts writes; no clean-machine prompt coverage"}
        options.output.write_text(json.dumps(receipt, indent=2) + "\n")
        print(json.dumps(receipt, indent=2))
    finally:
        client.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--space", required=True)
    parser.add_argument("--source-sha", required=True)
    parser.add_argument("--team-id", required=True)
    parser.add_argument("--previous-receipt", type=Path)
    parser.add_argument("--output", type=Path, required=True)
    options = parser.parse_args()
    if not re.fullmatch(r"[0-9a-f]{40}", options.source_sha):
        parser.error("Use the full reviewed source SHA")
    if not re.fullmatch(r"[A-Z0-9]{10}", options.team_id):
        parser.error("Use the trusted ten-character Apple team ID")
    run(options)


if __name__ == "__main__":
    main()
