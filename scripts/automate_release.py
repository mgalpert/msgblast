#!/usr/bin/env python3
"""Build and publish an ad-hoc Sparkle release to an existing public R2 host."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
from urllib.parse import urlsplit
from urllib.request import Request, urlopen
import xml.etree.ElementTree as ET

import release

ReleaseError = release.ReleaseError


def release_version(value):
    version = value.removeprefix("v")
    if not re.fullmatch(r"[0-9]+(?:\.[0-9]+){1,2}", version):
        raise ReleaseError("Release tag/version must be numeric, e.g. v0.1.0")
    return version


def object_prefix(base_url):
    parsed = release.validate_https(base_url)
    if not base_url.endswith("/") or any(part in (".", "..") for part in parsed.path.split("/")) or "%" in parsed.path:
        raise ReleaseError("Public base URL must end in / and have a plain path without traversal")
    return parsed.path.lstrip("/")


class R2Store:
    def __init__(self, account_id, bucket):
        if not re.fullmatch(r"[a-fA-F0-9]{32}", account_id) or not re.fullmatch(r"[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]", bucket):
            raise ReleaseError("A valid R2 account ID and bucket are required")
        self.base = ["aws", "--endpoint-url", f"https://{account_id}.r2.cloudflarestorage.com", "--region", "auto", "--no-cli-pager", "s3api"]
        self.bucket = bucket

    def get(self, key, path):
        command = self.base + ["get-object", "--bucket", self.bucket, "--key", key, str(path)]
        result = subprocess.run(command, capture_output=True, text=True)
        if result.returncode:
            if re.search(r"\((?:NoSuchKey|404|NotFound)\)", result.stderr):
                return None
            raise ReleaseError("R2 read failed: " + result.stderr.strip())
        return json.loads(result.stdout)

    def put(self, key, path, content_type, *, etag=None):
        condition = ["--if-match", etag] if etag is not None else ["--if-none-match", "*"]
        cache = "no-store" if key.endswith(("appcast.xml", "release-counter.json")) else "public, max-age=31536000, immutable"
        release.run(self.base + ["put-object", "--bucket", self.bucket, "--key", key,
            "--body", str(path), "--content-type", content_type, "--cache-control", cache, *condition])
        print("Uploaded " + key, flush=True)


def verify_feed(path, tools, key_file):
    release.run([str(tools / "sign_update"), "--ed-key-file", str(key_file), "--verify", str(path)])


def verify_archive(path, signature, tools, key_file):
    release.run([str(tools / "sign_update"), "--ed-key-file", str(key_file), "--verify", str(path), signature])


def current_release(store, prefix, directory, tools, key_file):
    feed = directory / "previous-appcast.xml"
    metadata = store.get(prefix + "appcast.xml", feed)
    if metadata is None:
        return {"build": 0, "etag": None}
    verify_feed(feed, tools, key_file)
    versions = ET.parse(feed).getroot().findall("./channel/item/" + release.SPARKLE + "version")
    if not versions or any(not re.fullmatch(r"[1-9][0-9]*", item.text or "") for item in versions):
        raise ReleaseError("Published feed has no valid integer build counter")
    if not metadata.get("ETag"):
        raise ReleaseError("R2 feed read did not return an ETag")
    return {"build": max(int(item.text) for item in versions), "etag": metadata["ETag"]}


def reserve_build(store, prefix, directory, published_build):
    counter = directory / "release-counter.json"
    metadata = store.get(prefix + "release-counter.json", counter)
    reserved = json.loads(counter.read_text())["build"] if metadata is not None else 0
    if not isinstance(reserved, int) or reserved < 0:
        raise ReleaseError("Stored release counter is invalid")
    if metadata is not None and not metadata.get("ETag"):
        raise ReleaseError("R2 counter read did not return an ETag")
    build = max(reserved, published_build) + 1
    counter.write_text(json.dumps({"build": build}) + "\n")
    store.put(prefix + "release-counter.json", counter, "application/json",
        etag=metadata["ETag"] if metadata is not None else None)
    return build


def verify_public(url, expected_digest):
    release.validate_https(url)
    request = Request(url, headers={"Cache-Control": "no-cache", "User-Agent": "msgblast-release-verifier"})
    digest = hashlib.sha256()
    with urlopen(request, timeout=60) as response:
        release.validate_https(response.url)
        while chunk := response.read(1024 * 1024):
            digest.update(chunk)
    if digest.hexdigest() != expected_digest:
        raise ReleaseError("Public download hash mismatch: " + url)
    print("Verified anonymous download " + url, flush=True)


def publish_release(store, base_url, publish, snapshot, tools, key_file):
    prefix = object_prefix(base_url)
    manifest = json.loads((publish / "release.json").read_text())
    version = release_version(manifest["version"])
    build = manifest["build"]
    if (not isinstance(build, int) or build <= snapshot["build"]
            or manifest["previous_build"] != snapshot["build"]):
        raise ReleaseError("Prepared build does not follow the verified published counter")
    archive = publish / f"msgblast-{version}-{build}.zip"
    feed = publish / "appcast.xml"
    expected_archive_url = base_url + "downloads/" + archive.name
    if manifest["feed_url"] != base_url + "appcast.xml" or manifest["archive_url"] != expected_archive_url:
        raise ReleaseError("Prepared release URL does not match the public destination")
    installer = None
    if "installer_url" in manifest:
        installer = publish / f"msgblast-{version}-{build}.dmg"
        if manifest["installer_url"] != base_url + "downloads/" + installer.name:
            raise ReleaseError("Prepared installer URL does not match the public destination")
    for path in (archive, feed, *([installer] if installer else [])):
        if release.file_sha256(path) != manifest["sha256"].get(path.name):
            raise ReleaseError("Prepared artifact hash mismatch: " + path.name)
    verify_archive(archive, manifest["archive_signature"], tools, key_file)
    verify_feed(feed, tools, key_file)
    if installer:
        verify_archive(installer, manifest["installer_signature"], tools, key_file)
    # An immutable archive must be downloadable before any installed app sees the feed.
    store.put(prefix + "downloads/" + archive.name, archive, "application/zip")
    verify_public(expected_archive_url, manifest["sha256"][archive.name])
    if installer:
        store.put(prefix + "downloads/" + installer.name, installer, "application/x-apple-diskimage")
        verify_public(manifest["installer_url"], manifest["sha256"][installer.name])
    store.put(prefix + f"releases/{version}-{build}.json", publish / "release.json", "application/json")
    # Compare-and-swap prevents a slower/competing publisher from replacing a newer feed.
    store.put(prefix + "appcast.xml", feed, "application/rss+xml", etag=snapshot["etag"])
    verify_public(base_url + "appcast.xml", manifest["sha256"][feed.name])
    print(f"Published msgblast {version} ({build})", flush=True)
    return manifest


def prepare_installer(options, tools, key_file):
    publish = options.output / "publish"
    installer = publish / f"msgblast-{options.version}-{options.build}.dmg"
    release.run([sys.executable, str(release.ROOT / "scripts/build_installer.py"),
        str(options.output / "export/msgblast.app"), str(installer)])
    signature = release.run([str(tools / "sign_update"), "--ed-key-file", str(key_file), "-p", str(installer)]).strip()
    verify_archive(installer, signature, tools, key_file)
    manifest_file = publish / "release.json"
    manifest = json.loads(manifest_file.read_text())
    manifest["installer_url"] = options.download_url_prefix + installer.name
    manifest["installer_signature"] = signature
    manifest["sha256"][installer.name] = release.file_sha256(installer)
    manifest_file.write_text(json.dumps(manifest, indent=2) + "\n")


def required_environment(name):
    value = os.environ.get(name, "").strip()
    if not value:
        raise ReleaseError("Missing release configuration: " + name)
    return value


def main(args=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--version", required=True, help="Numeric marketing version or v-prefixed tag")
    options = parser.parse_args(args)
    try:
        version = release_version(options.version)
        base_url = required_environment("MSGBLAST_PUBLIC_BASE_URL")
        prefix = object_prefix(base_url)
        key_file = Path(required_environment("MSGBLAST_ED_KEY_FILE")).resolve()
        # Sparkle can echo malformed input. Reject it before even prior-feed verification.
        release.validate_private_seed_file(key_file)
        tools = Path(required_environment("MSGBLAST_SPARKLE_BIN")).resolve()
        public_key = required_environment("MSGBLAST_PUBLIC_KEY")
        required_environment("AWS_ACCESS_KEY_ID")
        required_environment("AWS_SECRET_ACCESS_KEY")
        store = R2Store(required_environment("MSGBLAST_R2_ACCOUNT_ID"), required_environment("MSGBLAST_R2_BUCKET"))
        with tempfile.TemporaryDirectory(prefix="msgblast-release-state-") as temporary:
            snapshot = current_release(store, prefix, Path(temporary), tools, key_file)
            build = reserve_build(store, prefix, Path(temporary), snapshot["build"])
        # An Actions run/attempt has a fresh path; failed artifacts cannot be mistaken for success.
        run_id = os.environ.get("GITHUB_RUN_ID", "local")
        attempt = os.environ.get("GITHUB_RUN_ATTEMPT", "1")
        if not re.fullmatch(r"[A-Za-z0-9_-]+", run_id + "-" + attempt):
            raise ReleaseError("Invalid run identifier")
        output = release.ROOT / "build/releases" / f"{version}-{build}-{run_id}-{attempt}"
        preparation = release.parse_args(["--signing-mode", "ad-hoc", "--version", version,
            "--build", str(build), "--previous-build", str(snapshot["build"]),
            "--feed-url", base_url + "appcast.xml", "--download-url-prefix", base_url + "downloads/",
            "--public-key", public_key, "--sparkle-bin", str(tools), "--ed-key-file", str(key_file),
            "--output", str(output)])
        release.prepare(preparation)
        prepare_installer(preparation, tools, key_file)
        manifest_file = output / "publish/release.json"
        manifest = json.loads(manifest_file.read_text())
        revision = os.environ.get("GITHUB_SHA") or subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=release.ROOT, text=True).strip()
        if not re.fullmatch(r"[a-fA-F0-9]{40}", revision):
            raise ReleaseError("Release source revision is invalid")
        manifest["source_revision"] = revision
        manifest_file.write_text(json.dumps(manifest, indent=2) + "\n")
        result = publish_release(store, base_url, output / "publish", snapshot, tools, key_file)
        summary = os.environ.get("GITHUB_STEP_SUMMARY")
        if summary:
            with Path(summary).open("a") as file:
                file.write(f"msgblast {version} ({build}) published from `{revision}`.\n\n"
                    f"[Installer]({result['installer_url']}) · [Update ZIP]({result['archive_url']}) · [Feed]({result['feed_url']})\n\n"
                    "Ad-hoc app signing; Sparkle archive/feed signatures verified. No Apple notarization.\n")
        return 0
    except (ReleaseError, OSError, ValueError, KeyError, ET.ParseError) as error:
        print("Automated release failed: " + str(error), file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
