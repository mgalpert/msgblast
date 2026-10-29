#!/usr/bin/env python3
"""Build an isolated local GPTLive app, ZIP, and manifest; never publish or launch it."""
import argparse
from datetime import datetime
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile

import build_preview_apps as builder
import preview_apps as preview


VARIANTS = {
    "development": {
        **preview.VARIANTS["development"],
        "label": "GPTLive live development",
        "app_name": "dev - gptlive.app",
        "bundle_id": "com.msgblast.gptlive",
        "bundle_name": "dev - gptlive",
        "display_name": "dev - gptlive",
        "support_directory": "msgblast-GPTLive",
        "artifact_prefix": "dev-gptlive",
    },
    "demo": {
        **preview.VARIANTS["demo"],
        "label": "GPTLive simulated demo",
        "app_name": "gptlive Demo.app",
        "bundle_id": "com.msgblast.gptlive-demo",
        "bundle_name": "gptlive Demo",
        "display_name": "gptlive Demo",
        "support_directory": "msgblast-GPTLive-Demo",
        "artifact_prefix": "gptlive-demo",
    },
}


def timestamped_variant(name, built_at):
    """Name each build separately while preserving its account and Keychain identity."""
    variant = dict(VARIANTS[name])
    label = f"{variant['display_name']} - {built_at:%Y-%m-%d %H-%M-%S %Z}"
    variant.update(app_name=label + ".app", bundle_name=label, display_name=label,
                   artifact_prefix=f"{variant['artifact_prefix']}-{built_at:%Y%m%d-%H%M%S%z}")
    return variant


def running_app(app):
    """Check this exact bundle path without asking System Events for permission."""
    result = subprocess.run(["ps", "-ww", "-axo", "command="], check=True, text=True,
                            stdout=subprocess.PIPE)
    prefix = str(app.resolve()) + "/Contents/MacOS/"
    return any(line.lstrip().startswith(prefix) for line in result.stdout.splitlines())


def check_destination(output, variant, replace):
    app = output / variant["app_name"]
    if app.is_symlink():
        raise RuntimeError(f"Refusing a symlink destination: {app}")
    if app.exists() and not replace:
        raise RuntimeError(f"App already exists: {app}. Quit it and add --replace to rebuild this target.")
    if app.exists() and running_app(app):
        raise RuntimeError(f"Quit {app} before replacing it; the running app has been preserved.")


def disable_telemetry(workspace):
    """Change only the staged Info.plist before Xcode processes it."""
    path = workspace / "msgblast/Info.plist"
    with path.open("rb") as file:
        info = plistlib.load(file)
    info["msgblastTelemetryEndpoint"] = ""
    with path.open("wb") as file:
        plistlib.dump(info, file)


def verify_package(app, variant, revision):
    with (app / "Contents/Info.plist").open("rb") as file:
        info = plistlib.load(file)
    preview.verify_configured_info(info, variant, revision)
    if info.get("msgblastTelemetryEndpoint"):
        raise RuntimeError("GPTLive builds must have telemetry uploads disabled")
    for name in ("cloudflared", "cua-driver"):
        helper = app / "Contents/Helpers" / name
        if helper.is_symlink() or not helper.is_file() or not os.access(helper, os.X_OK) or not builder.is_mach_o(helper):
            raise RuntimeError(f"Missing regular Mach-O helper: {name}")
        builder.run(["xcrun", "lipo", "-verify_arch", "arm64", str(helper)], app.parent)
        # The existing Xcode phases verify downloads against these pinned manifests.
        manifest = name + ".json"
        embedded = app / "Contents/Resources" / manifest
        if embedded.is_symlink() or embedded.read_bytes() != (preview.ROOT / "scripts" / manifest).read_bytes():
            raise RuntimeError(f"Packaged helper manifest differs from the source pin: {manifest}")
    for name in ("CloudflaredNotices.txt", "CuaDriverNotices.txt"):
        if not (app / "Contents/Resources" / name).is_file():
            raise RuntimeError(f"Missing helper attribution: {name}")


def install_outputs(staged, output, variant, names, replace):
    """Keep the previous app until packaging succeeds, and roll back install errors."""
    check_destination(output, variant, replace)
    for name in names:
        destination = output / name
        if destination.is_symlink():
            raise RuntimeError(f"Refusing a symlink destination: {destination}")
        if destination.exists() and not replace:
            raise RuntimeError(f"Output already exists: {destination}; use --replace to rebuild this target.")
    backup = Path(tempfile.mkdtemp(prefix=".gptlive-backup-", dir=output))
    moved = []
    installed = []
    try:
        for name in names:
            destination = output / name
            if destination.exists():
                os.replace(destination, backup / name)
                moved.append(name)
            os.replace(staged / name, destination)
            installed.append(name)
    except BaseException:
        try:
            for name in reversed(installed):
                os.replace(output / name, staged / name)
            for name in reversed(moved):
                os.replace(backup / name, output / name)
        except BaseException as recovery_error:
            raise RuntimeError(f"Install recovery failed; previous outputs remain in {backup}") from recovery_error
        shutil.rmtree(backup)
        raise
    shutil.rmtree(backup)


def instructions(variant):
    mode = ("Simulated Demo conversations and sends." if variant["fixture"] else
            "Live app: connect accounts separately; do not pass --demo or --isolated-demo.")
    return (f"Open {variant['app_name']}. {mode} Preferences use {variant['bundle_id']}; "
            f"saved state uses ~/Library/Application Support/{variant['support_directory']}. "
            "Production updates and telemetry uploads are disabled. This local app is ad-hoc signed, "
            "not notarized. Quit this app before replacing it; rebuilds may require macOS permissions again.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=preview.ROOT / "build/gptlive",
                        help="Destination directory for the app, ZIP, and manifest")
    parser.add_argument("--variant", choices=tuple(VARIANTS), default="development")
    parser.add_argument("--replace", action="store_true", help="Replace this variant's existing, stopped app and outputs")
    parser.add_argument("--sha", help="Optional source revision metadata; defaults to the checkout's HEAD")
    args = parser.parse_args()
    revision = args.sha or subprocess.check_output(
        ["git", "rev-parse", "HEAD"], cwd=preview.ROOT, text=True).strip()
    if len(revision) != 40 or any(character not in "0123456789abcdef" for character in revision):
        parser.error("--sha must be a full 40-character lowercase commit ID")
    for tool in ("xcodebuild", "xcrun", "codesign", "ditto", "ps"):
        if shutil.which(tool) is None:
            parser.error(f"Required macOS tool is missing: {tool}")
    output = args.output.expanduser().resolve()
    if output.suffix == ".app":
        parser.error("--output is a directory, not an .app bundle path")
    if output.is_relative_to(preview.ROOT) and not output.is_relative_to(preview.ROOT / "build"):
        parser.error("Outputs inside the checkout must be under build/ so they are not copied into staged source")
    built_at = datetime.now().astimezone()
    variant = timestamped_variant(args.variant, built_at)
    output.mkdir(parents=True, exist_ok=True)
    check_destination(output, variant, args.replace)
    preview.assert_committed_icons_unchanged()
    with tempfile.TemporaryDirectory(prefix="msgblast-gptlive-") as source_directory, \
            tempfile.TemporaryDirectory(prefix=".gptlive-package-", dir=output) as package_directory:
        workspace = preview.copy_workspace(Path(source_directory) / "src")
        disable_telemetry(workspace)
        staged = Path(package_directory)
        record = builder.package_variant(workspace, variant, revision, staged)
        verify_package(staged / variant["app_name"], variant, revision)
        record["instructions"] = instructions(variant)
        record["telemetry"] = "disabled"
        manifest_name = f"{variant['artifact_prefix']}-manifest.json"
        document = {
            "built_at": built_at.isoformat(),
            "source_revision": revision,
            "source_note": "Built from a copy of the working tree, including uncommitted edits; revision is metadata.",
            "production_feed_used": False,
            "published": False,
            "variant": record,
        }
        (staged / manifest_name).write_text(json.dumps(document, indent=2) + "\n")
        preview.assert_committed_icons_unchanged()
        install_outputs(staged, output, variant,
                        [variant["app_name"], record["zip"], manifest_name], args.replace)
    print(output / variant["app_name"])
    print(output / manifest_name)


if __name__ == "__main__":
    try:
        main()
    except (RuntimeError, subprocess.CalledProcessError) as error:
        raise SystemExit(str(error)) from error
