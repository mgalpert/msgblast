#!/usr/bin/env python3
"""Sign isolated Dev artifacts and publish verified GitHub testing prereleases."""
import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import plistlib
import posixpath
import re
import shutil
import stat
import subprocess
import tempfile
from types import SimpleNamespace
import urllib.request
import zipfile

import build_preview_apps as builder
import preview_apps as preview


VARIANT = preview.VARIANTS["development"]


def require(condition, message):
    if not condition:
        raise ValueError(message)


def sha(value):
    require(bool(re.fullmatch(r"[0-9a-f]{40}", value)), "Use a full lowercase source SHA")
    return value


def gh(*arguments):
    return subprocess.check_output(["gh", *arguments], text=True).strip()


def validate_environment(document):
    require(any(rule.get("type") == "required_reviewers" and rule.get("reviewers")
                for rule in document.get("protection_rules", [])),
            "test-build-signing needs a required maintainer reviewer before dispatch")
    policy = document.get("deployment_branch_policy") or {}
    require(policy.get("custom_branch_policies") is True,
            "Restrict test-build-signing to the default branch")
    require(document.get("can_admins_bypass") is False,
            "Disable administrator bypass for test-build-signing")


def resolve(args):
    sha(args.source)
    require(os.environ["GITHUB_REF_NAME"] == args.default_branch,
            "Dispatch the trusted workflow from the default branch")
    environment = json.loads(gh("api", f"repos/{args.repo}/environments/test-build-signing"))
    validate_environment(environment)
    policies = json.loads(gh("api", f"repos/{args.repo}/environments/test-build-signing/deployment-branch-policies"))
    require(policies.get("total_count") == 1 and
            policies["branch_policies"][0].get("name") == args.default_branch and
            policies["branch_policies"][0].get("type") == "branch",
            "Signing environment must allow only the default branch, with no tags")
    resolved = subprocess.check_output(["git", "rev-parse", args.source + "^{commit}"], text=True).strip()
    require(resolved == args.source, "Source did not resolve to the requested commit")
    branches = subprocess.check_output(["git", "branch", "-r", "--contains", args.source,
                                        "--format=%(refname)"], text=True)
    require(any(line.startswith("refs/remotes/origin/") for line in branches.splitlines()),
            "Source must be reachable from a branch in this repository; push it first")
    require(args.title.strip() and len(args.title) <= 120 and "\n" not in args.title,
            "Supply a one-line feature title (at most 120 characters)")
    require(bool(args.notes.strip()), "Describe what testers should try")
    with Path(os.environ["GITHUB_OUTPUT"]).open("a") as output:
        output.write(f"source={args.source}\n")
    with Path(os.environ["GITHUB_STEP_SUMMARY"]).open("a") as output:
        output.write(f"## Testing build awaiting approval\n\nSource: `{args.source}`\n\n"
                     "Review this revision and its feature before approving test-build-signing.\n")


def extract_app(archive, destination):
    """Extract only the Dev bundle; never write through archive symlinks."""
    destination = Path(destination)
    with zipfile.ZipFile(archive) as zipped:
        members = []
        names = set()
        for entry in zipped.infolist():
            name = entry.filename
            # ditto includes resource-fork metadata, which we do not need to sign.
            if name.startswith("__MACOSX/"):
                continue
            parts = PurePosixPath(name).parts
            require(parts and parts[0] == VARIANT["app_name"] and
                    ".." not in parts and "\\" not in name and not name.startswith("/"),
                    "Archive contains a path outside msgblast Dev.app")
            require(name.rstrip("/") not in names, "Archive contains duplicate paths")
            names.add(name.rstrip("/"))
            mode = entry.external_attr >> 16
            require(stat.S_IFMT(mode) in (0, stat.S_IFREG, stat.S_IFDIR, stat.S_IFLNK),
                    "Archive contains a special file")
            members.append((entry, mode))
        link_names = {entry.filename for entry, mode in members if stat.S_ISLNK(mode)}
        for entry, _ in members:
            require(not any(str(parent) in link_names for parent in PurePosixPath(entry.filename).parents),
                    "Archive contains a path beneath a symlink")
        links = []
        for entry, mode in members:
            target = destination / entry.filename
            if stat.S_ISLNK(mode):
                link = zipped.read(entry).decode("utf-8")
                normalized = posixpath.normpath(posixpath.join(posixpath.dirname(entry.filename), link))
                require(not link.startswith("/") and "\\" not in link and
                        normalized.startswith(VARIANT["app_name"] + "/"),
                        "Archive symlink escapes the Dev bundle")
                links.append((target, link))
            elif entry.is_dir():
                target.mkdir(parents=True, exist_ok=True)
            else:
                target.parent.mkdir(parents=True, exist_ok=True)
                with zipped.open(entry) as source, target.open("xb") as output:
                    shutil.copyfileobj(source, output)
                target.chmod(mode & 0o777 or 0o644)
        for target, link in links:
            target.parent.mkdir(parents=True, exist_ok=True)
            target.symlink_to(link)
        app = destination / VARIANT["app_name"]
        for target, _ in links:
            require(target.resolve().is_relative_to(app.resolve()), "Archive symlink chain escapes bundle")
    return app


def load_package(directory, source, signed=True):
    directory = Path(directory)
    document = json.loads((directory / "preview-manifest.json").read_text())
    require(document.get("source_revision") == sha(source), "Manifest source differs from selected revision")
    require(document.get("production_feed_used") is False, "Production feed must stay disabled")
    records = document.get("variants", [])
    require(len(records) == 1, "Publish exactly one Dev app")
    record = records[0]
    for key, expected in (("id", "development"), ("fixture", False),
                          ("app_name", "msgblast Dev.app"), ("bundle_id", "com.msgblast.development"),
                          ("updates", "disabled")):
        require(record.get(key) == expected, f"Unexpected Dev manifest {key}")
    name = record.get("zip", "")
    require(name == f"msgblast-dev-{source[:12]}.zip", "Unexpected archive filename")
    archive = directory / name
    require(not archive.is_symlink() and archive.is_file(), "Archive must be a regular file")
    require(preview.sha256_file(archive) == record.get("sha256"), "Archive SHA-256 mismatch")
    if signed:
        signing = record.get("signing", {})
        require(signing.get("mode") == "developer-id" and
                signing.get("notarization", {}).get("status") == "Accepted",
                "Testing downloads require Developer ID signing and Accepted notarization")
    return document, record, archive


def sign(args):
    document, record, archive = load_package(args.directory, args.source, signed=False)
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    options = SimpleNamespace(signing_identity=os.environ["MSGBLAST_DEVELOPER_ID_IDENTITY"],
                              team_id=os.environ["MSGBLAST_APPLE_TEAM_ID"],
                              keychain=Path(os.environ["MSGBLAST_NOTARY_KEYCHAIN"]),
                              notary_profile=os.environ["MSGBLAST_NOTARY_PROFILE"])
    with tempfile.TemporaryDirectory(prefix="msgblast-test-sign-") as temporary:
        app = extract_app(archive, temporary)
        with (app / "Contents/Info.plist").open("rb") as file:
            info = plistlib.load(file)
        preview.verify_configured_info(info, VARIANT, args.source)
        builder.verify_universal_bundle(app)
        icon = preview.compiled_icon_path(app, info, VARIANT["icon_name"])
        red, green, blue, _ = preview.sample_icns(icon)
        require(preview.classify_icon_color(red, green, blue) == "blue-green", "Dev icon must be blue-green")
        builder.sign_bundle(app, preview.ROOT / "msgblast/msgblastDebug.entitlements",
                            options.signing_identity, options.keychain)
        record["signing"] = builder.notarize_preview(app, options, VARIANT["bundle_id"])
        record["instructions"] = builder.instructions(VARIANT, stable=True)
        result = output / archive.name
        builder.run(["ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", str(app), str(result)], output)
        record["sha256"] = preview.sha256_file(result)
        with tempfile.TemporaryDirectory(prefix="msgblast-test-verify-") as extracted:
            packed = extract_app(result, extracted)
            builder.run(["codesign", "--verify", "--deep", "--strict", str(packed)], output)
            builder.run(["xcrun", "stapler", "validate", str(packed)], output)
    document.pop("expiry", None)
    document.pop("retention_days", None)
    document["distribution"] = "github-prerelease"
    (output / "preview-manifest.json").write_text(json.dumps(document, indent=2) + "\n")


def release_notes(source, title, notes, run_url, record):
    return (f"# msgblast Dev: {title}\n\n{notes.strip()}\n\n"
            "## Install\n\nApple Silicon or Intel Mac running macOS 15 or later required. Unzip and drag **msgblast Dev.app** to Applications. "
            "Keep your regular **msgblast.app** installed. Open Dev and connect the integrations you want to test; "
            "macOS permissions are separate from the regular app. Dev uses real accounts and data.\n\n"
            "Dev has a blue-green icon and separate saved data. All Dev testing builds share that Dev profile; "
            "quit Dev before replacing it and back up its data before trying a different feature or older build. "
            "Updates are manual: download the next testing build and replace Dev in the same location.\n\n"
            "## Feedback\n\nReport what you tried, what happened, what you expected, and the source SHA below. "
            "Remove private conversation content from anything you share publicly.\n\n"
            f"Source-SHA: `{source}`\n\nBuild workflow: {run_url}\n\n"
            f"Dev ZIP SHA-256: `{record['sha256']}`\n\n"
            "Developer ID signed and Apple notarized. Production updates are disabled.\n")


def prepare(args):
    _, record, archive = load_package(args.directory, args.source)
    require(bool(re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", args.repo)), "Invalid repository")
    require(bool(re.fullmatch(r"[1-9][0-9]*-[1-9][0-9]*", args.run)), "Use run-id and attempt, e.g. 12345-1")
    require(args.title.strip() and len(args.title) <= 120 and "\n" not in args.title, "Invalid feature title")
    require(bool(args.notes.strip()), "Testing instructions are required")
    tag = f"test-{args.source}-{args.run}"
    run_url = f"https://github.com/{args.repo}/actions/runs/{args.run.split('-')[0]}"
    notes = args.directory / "testing-notes.md"
    notes.write_text(release_notes(args.source, args.title, args.notes, run_url, record))
    plan = {"tag": tag, "source_revision": args.source, "prerelease": True,
            "release_url": f"https://github.com/{args.repo}/releases/tag/{tag}",
            "download_url": f"https://github.com/{args.repo}/releases/download/{tag}/{archive.name}",
            "sha256": record["sha256"]}
    (args.directory / "test-release.json").write_text(json.dumps(plan, indent=2) + "\n")
    print(json.dumps(plan, indent=2))
    return plan, notes, archive


def publish(args):
    plan, notes, archive = prepare(args)
    tag = plan["tag"]
    # Draft releases may defer tag creation until publication. Reserve the exact
    # lightweight tag ourselves, without ever updating an existing reference.
    gh("api", "--method", "POST", f"repos/{args.repo}/git/refs",
       "-f", "ref=refs/tags/" + tag, "-f", "sha=" + args.source)
    # No --clobber, release edit of an existing tag, or production-version tags.
    # Creating a draft fails if this run/attempt already created a release.
    gh("release", "create", tag, "--repo", args.repo, "--target", args.source,
       "--verify-tag", "--draft", "--prerelease", "--latest=false", "--title", "msgblast Dev: " + args.title,
       "--notes-file", str(notes))
    assets = [archive, args.directory / "preview-manifest.json", args.directory / "test-release.json"]
    gh("release", "upload", tag, "--repo", args.repo, *(str(path) for path in assets))
    with tempfile.TemporaryDirectory(prefix="msgblast-test-download-") as temporary:
        gh("release", "download", tag, "--repo", args.repo, "--dir", temporary)
        for asset in assets:
            require(preview.sha256_file(Path(temporary) / asset.name) == preview.sha256_file(asset),
                    "Uploaded asset mismatch; release remains a draft")
    # Verify the tag GitHub created really points to this SHA before publication.
    ref = json.loads(gh("api", f"repos/{args.repo}/git/ref/tags/{tag}"))
    require(ref["object"]["type"] == "commit" and ref["object"]["sha"] == args.source,
            "Tag differs from selected source; release remains a draft")
    gh("release", "edit", tag, "--repo", args.repo, "--draft=false", "--prerelease", "--latest=false")
    # No Authorization header: this verifies the public tester download.
    digest = hashlib.sha256()
    with urllib.request.urlopen(plan["download_url"], timeout=120) as response:
        for chunk in iter(lambda: response.read(1024 * 1024), b""):
            digest.update(chunk)
    require(digest.hexdigest() == plan["sha256"],
            "Public download mismatch: prerelease may already be live; inspect before retrying")
    print("Verified testing download: " + plan["release_url"])
    if os.environ.get("GITHUB_STEP_SUMMARY"):
        with Path(os.environ["GITHUB_STEP_SUMMARY"]).open("a") as output:
            output.write(f"## Published testing build\n\n{plan['release_url']}\n\n"
                         f"Source: `{args.source}`\n\nZIP SHA-256: `{plan['sha256']}`\n")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    resolver = commands.add_parser("resolve")
    resolver.add_argument("--default-branch", required=True)
    for command in ("resolve", "sign", "prepare", "publish"):
        sub = resolver if command == "resolve" else commands.add_parser(command)
        sub.add_argument("--source", required=True, type=sha)
        if command != "resolve":
            sub.add_argument("--directory", type=Path, required=True)
        if command == "sign":
            sub.add_argument("--output", type=Path, required=True)
        else:
            sub.add_argument("--repo", required=True)
            sub.add_argument("--title", required=True)
            sub.add_argument("--notes", required=True)
            if command != "resolve":
                sub.add_argument("--run", required=True)
    args = parser.parse_args()
    try:
        globals()[args.command](args)
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        parser.exit(1, f"Testing build failed: {error}\n")


if __name__ == "__main__":
    main()
