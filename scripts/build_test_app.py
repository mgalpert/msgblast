#!/usr/bin/env python3
"""Build a uniquely named local Dev test copy that keeps its macOS permission grants.

macOS records Full Disk Access, Accessibility and Screen Recording against a
bundle ID plus a designated requirement. Ad-hoc copies have a code-hash
requirement, so every rebuild is a new app. This signs with the maintainer's
Apple Development certificate and installs into one of a few fixed slot bundle
IDs, so each slot is approved once and every later build in it keeps the grant.
Each copy still gets its own visible name and its own support folder.
"""
import argparse
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import tempfile

import build_preview_apps as builder
import preview_apps as preview


SLOTS = ("a", "b", "c", "d")
BUNDLE_PREFIX = "com.msgblast.development.test-"
INSTALL_ROOT = Path.home() / "Applications/msgblast PR Testing"
CONFIG = Path(os.environ.get("XDG_CONFIG_HOME", Path.home() / ".config")) / "msgblast/test-builds.json"
NAME = re.compile(r"[A-Za-z0-9][A-Za-z0-9 ._-]{0,39}")


def test_variant(name, slot):
    if not NAME.fullmatch(name):
        raise ValueError("Name must be 1-40 letters, digits, spaces, dots, dashes or underscores")
    if slot not in SLOTS:
        raise ValueError(f"Slot must be one of {', '.join(SLOTS)}")
    folder = "msgblast-Dev-" + re.sub(r"[^A-Za-z0-9]+", "-", name).strip("-")[:28]
    variant = dict(preview.VARIANTS["development"])
    variant.update({"app_name": f"msgblast Dev ({name}).app", "bundle_id": BUNDLE_PREFIX + slot,
                    "bundle_name": f"msgblast Dev ({name})", "display_name": f"msgblast Dev ({name})",
                    "support_directory": folder, "artifact_prefix": "msgblast-dev-test"})
    return variant


def installed(root):
    """Map each installed test copy to its slot."""
    copies = {}
    for info_path in Path(root).glob("*/*.app/Contents/Info.plist"):
        with info_path.open("rb") as file:
            bundle_id = plistlib.load(file).get("CFBundleIdentifier", "")
        if bundle_id.startswith(BUNDLE_PREFIX):
            copies[info_path.parents[1]] = bundle_id[len(BUNDLE_PREFIX):]
    return copies


def running_paths():
    lines = subprocess.run(["ps", "-axo", "command="], capture_output=True, text=True, check=True).stdout
    return lines.splitlines()


def is_running(app, commands):
    executable = str(app) + "/Contents/"
    return any(command.startswith(executable) for command in commands)


def choose_slot(app, copies, commands, requested=None):
    """Reuse this copy's slot; otherwise take the first slot with nothing running."""
    if is_running(app, commands):
        raise RuntimeError(f"{app.name} is running; quit it before replacing it")
    if requested:
        busy = [path for path, slot in copies.items() if slot == requested and is_running(path, commands)]
        if busy:
            raise RuntimeError(f"Slot {requested} is in use by running {busy[0].name}")
        return requested
    if app in copies:
        return copies[app]
    busy = {slot for path, slot in copies.items() if is_running(path, commands)}
    free = [slot for slot in SLOTS if slot not in busy]
    if not free:
        raise RuntimeError("Every slot has a running test copy; quit one first")
    return free[0]


def signing_identity(requested_name, config=CONFIG):
    """Keep one Apple Development certificate name for every build; a renewal keeps that name."""
    saved = json.loads(config.read_text()).get("identity_name") if config.is_file() else None
    if saved and requested_name and requested_name != saved:
        raise RuntimeError(f"{config} already uses another certificate; changing it resets every grant")
    name = saved or requested_name
    if not name or not name.startswith("Apple Development: "):
        raise RuntimeError("Pass --identity-name 'Apple Development: …' once; it is saved for later builds")
    listing = subprocess.run(["security", "find-identity", "-v", "-p", "codesigning"],
                             capture_output=True, text=True, check=True).stdout
    hashes = re.findall(r'\)\s+([0-9A-F]{40})\s+"' + re.escape(name) + '"', listing)
    if len(hashes) != 1:
        raise RuntimeError(f"Expected one valid certificate named {name!r}, found {len(hashes)}")
    if not saved:
        config.parent.mkdir(parents=True, exist_ok=True)
        config.write_text(json.dumps({"identity_name": name}) + "\n")
    return hashes[0]


def install(built, destination):
    destination.parent.mkdir(parents=True, exist_ok=True)
    staged = destination.with_name(destination.name + ".new")
    shutil.rmtree(staged, ignore_errors=True)
    builder.run(["ditto", str(built), str(staged)], destination.parent)
    if destination.exists():
        shutil.rmtree(destination)
    staged.rename(destination)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--name", required=True, help="Unique visible name, e.g. 'Fixes 1111'")
    parser.add_argument("--sha", help="Source revision label (defaults to HEAD)")
    parser.add_argument("--slot", choices=SLOTS, help="Force a slot instead of choosing a free one")
    parser.add_argument("--identity-name", help="First run only: the Apple Development certificate name")
    parser.add_argument("--root", type=Path, default=INSTALL_ROOT)
    args = parser.parse_args()
    sha = args.sha or subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=preview.ROOT, text=True).strip()
    identity = signing_identity(args.identity_name)
    destination = args.root / args.name / f"msgblast Dev ({args.name}).app"
    slot = choose_slot(destination, installed(args.root), running_paths(), args.slot)
    variant = test_variant(args.name, slot)
    with tempfile.TemporaryDirectory(prefix="msgblast-test-app-") as temporary:
        workspace = preview.copy_workspace(Path(temporary) / "src")
        output = Path(temporary) / "out"
        output.mkdir()
        record = builder.package_variant(workspace, variant, sha, output, local_identity=identity)
        if is_running(destination, running_paths()):
            raise RuntimeError(f"{destination.name} started during the build; quit it and rerun")
        install(output / variant["app_name"], destination)
    print(f"Installed {destination}\nSlot {slot}: {variant['bundle_id']} "
          f"(grants carry over from earlier builds in this slot)\n"
          f"Support folder: ~/Library/Application Support/{variant['support_directory']}\n"
          f"Requirement: {record['signing']['designated_requirement']}\n"
          f"Launch with: open -n {json.dumps(str(destination))}")


if __name__ == "__main__":
    main()
