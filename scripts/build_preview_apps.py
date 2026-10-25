#!/usr/bin/env python3
"""Build isolated preview ZIPs. Ad-hoc by default; never publishes an app."""
import argparse
from pathlib import Path
import json
import os
import plistlib
import shutil
import subprocess
import tempfile

import preview_apps as preview
import release


def run(command, cwd):
    print("+ " + " ".join(command), flush=True)
    result = subprocess.run(command, cwd=cwd, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    if result.stdout:
        print(result.stdout, end="" if result.stdout.endswith("\n") else "\n", flush=True)
    if result.returncode:
        raise SystemExit(f"Command failed ({result.returncode}): {' '.join(command)}")
    return result.stdout


def is_mach_o(path):
    try:
        with path.open("rb") as file:
            magic = file.read(4)
    except OSError:
        return False
    return magic in {bytes.fromhex(value) for value in (
        "feedface", "cefaedfe", "feedfacf", "cffaedfe", "cafebabe", "bebafeca", "cafebabf", "bfbafeca")}


def signing_order(paths):
    """Sign dylibs before executables, and both before bundle containers.

    Deepest-first name order is not enough: Contents/MacOS/msgblast sorts before
    Contents/MacOS/msgblast.debug.dylib, and codesign rejects the executable
    while that sibling dylib is unsigned.
    """
    def key(path):
        path = Path(path)
        if path.suffix == ".dylib":
            phase = 0
        elif path.suffix in {".framework", ".xpc", ".app"}:
            phase = 2
        else:
            phase = 1
        return (phase, -len(path.parts), str(path))

    return sorted((Path(path) for path in paths), key=key)


def bundle_executable(app):
    """The outer codesign seals CFBundleExecutable after nested dylibs."""
    info_path = Path(app) / "Contents/Info.plist"
    if not info_path.is_file():
        return None
    with info_path.open("rb") as file:
        name = plistlib.load(file).get("CFBundleExecutable")
    if not name:
        return None
    return Path(app) / "Contents/MacOS" / name


def sign_bundle(app, entitlements, identity="-", keychain=None):
    """Sign nested Debug binaries and frameworks before the outer bundle.

    Debug builds leave Contents/MacOS/*.debug.dylib unsigned when Xcode signing
    is disabled. Sparkle helpers are already signed and keep their entitlements.
    The main executable is left for the final app signature.
    """
    nested = []
    for path in app.rglob("*"):
        if path.is_symlink():
            continue
        if path.is_dir() and path.suffix in {".framework", ".xpc", ".app"}:
            nested.append(path)
        elif path.is_file() and is_mach_o(path):
            nested.append(path)
    executable = bundle_executable(app)
    base_command = ["codesign", "--force", "--sign", identity, "--options", "runtime"]
    if identity != "-":
        base_command.append("--timestamp")
    if keychain:
        base_command.extend(["--keychain", str(keychain)])
    for path in signing_order(nested):
        if path == executable:
            continue
        signed = subprocess.run(["codesign", "-dv", str(path)], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode == 0
        command = base_command.copy()
        if signed:
            command.append("--preserve-metadata=entitlements")
        command.append(str(path))
        run(command, app.parent)
    run([*base_command, "--entitlements", str(entitlements), str(app)], app.parent)
    run(["codesign", "--verify", "--deep", "--strict", "--verbose=2", str(app)], app.parent)


def verify_stable_signature_text(metadata, requirement, identity, team, bundle_id):
    required = {"Identifier=" + bundle_id, "Authority=" + identity, "TeamIdentifier=" + team}
    if not required.issubset(set(metadata.splitlines())) or "(runtime)" not in metadata:
        raise RuntimeError("Preview signature does not match its identity, team, bundle, or hardened runtime")
    if "cdhash" in requirement or "anchor apple generic" not in requirement:
        raise RuntimeError("Preview designated requirement must use stable Apple certificate identity, not a code hash")


def notarize_preview(app, options, bundle_id):
    metadata = run(["codesign", "-dv", "--verbose=4", str(app)], app.parent)
    requirement = run(["codesign", "-dr", "-", str(app)], app.parent).split("designated =>", 1)[-1].strip()
    verify_stable_signature_text(metadata, requirement, options.signing_identity, options.team_id, bundle_id)
    rule = f'identifier "{bundle_id}" and anchor apple generic and certificate leaf[subject.OU] = "{options.team_id}"'
    run(["codesign", "--verify", "--strict", "-R", "=" + rule, str(app)], app.parent)
    with tempfile.TemporaryDirectory(prefix="msgblast-preview-notary-") as temporary:
        archive = Path(temporary) / "notarization.zip"
        run(["ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", str(app), str(archive)], app.parent)
        result = json.loads(run(["xcrun", "notarytool", "submit", str(archive), "--keychain-profile",
                                 options.notary_profile, "--keychain", str(options.keychain), "--wait",
                                 "--output-format", "json"], app.parent))
        if result.get("status") != "Accepted":
            raise RuntimeError("Preview notarization was not Accepted")
    run(["xcrun", "stapler", "staple", str(app)], app.parent)
    run(["xcrun", "stapler", "validate", str(app)], app.parent)
    run(["spctl", "--assess", "--type", "execute", "--verbose=2", str(app)], app.parent)
    return {"mode": "developer-id", "identity": options.signing_identity, "team_id": options.team_id,
            "designated_requirement": requirement, "notarization": result}


def verify_universal_bundle(app):
    """Inspect packaged code without executing any feature binary."""
    for relative in ("Contents/Helpers/cua-driver", "Contents/Helpers/cloudflared"):
        helper = app / relative
        if not helper.is_file() or helper.is_symlink() or not os.access(helper, os.X_OK) or not is_mach_o(helper):
            raise RuntimeError(f"Missing regular executable helper: {relative}")
    executable = bundle_executable(app)
    if executable is None or not executable.is_file() or not is_mach_o(executable):
        raise RuntimeError("Missing Mach-O app executable")
    for binary in app.rglob("*"):
        if binary.is_file() and not binary.is_symlink() and is_mach_o(binary):
            run(["xcrun", "lipo", "-verify_arch", "arm64", "x86_64", str(binary)], app.parent)
    for name in ("cua-driver.json", "CuaDriverNotices.txt", "cloudflared.json", "CloudflaredNotices.txt"):
        if not (app / "Contents/Resources" / name).is_file():
            raise RuntimeError(f"Missing embedded helper resource: {name}")


def retain_icon_diagnostic(output, variant, icns):
    destination = output / "diagnostics" / f"{variant['id']}-{icns.name}"
    destination.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(icns, destination)
    print(f"retained compiled icon diagnostic {destination}", flush=True)
    return destination


def package_variant(workspace, variant, source_revision, output, enable_dev_telemetry=False, signing=None, universal=False):
    derived = workspace / "derived" / variant["id"]
    if derived.exists():
        shutil.rmtree(derived)
    architecture_settings = ["ARCHS=arm64 x86_64", "ONLY_ACTIVE_ARCH=NO"] if universal else []
    run([
        "xcodebuild", "-project", str(workspace / "msgblast.xcodeproj"), "-scheme", "msgblast",
        "-configuration", "Debug", "-derivedDataPath", str(derived),
        "-destination", "platform=macOS,arch=arm64",
        f"ASSETCATALOG_COMPILER_APPICON_NAME={variant['icon_name']}",
        "CODE_SIGNING_ALLOWED=NO", *architecture_settings,
        f"MSGBLAST_APP_BUNDLE_IDENTIFIER={variant['bundle_id']}",
        "SPARKLE_FEED_URL=", "SPARKLE_PUBLIC_ED_KEY=",
        "-quiet", "build",
    ], workspace)
    built = derived / "Build/Products/Debug/msgblast.app"
    app = output / variant["app_name"]
    if app.exists():
        shutil.rmtree(app)
    shutil.copytree(built, app, symlinks=True)
    info_path = app / "Contents/Info.plist"
    with info_path.open("rb") as file:
        built_info = plistlib.load(file)
    try:
        icns = preview.compiled_icon_path(app, built_info, variant["icon_name"])
    except RuntimeError as error:
        raise SystemExit(f"{variant['id']} {error}") from error
    info = preview.configure_info(built_info, variant, source_revision)
    if enable_dev_telemetry and variant["id"] == "development":
        info["msgblastTelemetryEndpoint"] = "https://msgblast.app/api/telemetry"
    with info_path.open("wb") as file:
        plistlib.dump(info, file)
    with info_path.open("rb") as file:
        preview.verify_configured_info(plistlib.load(file), variant, source_revision)
    try:
        red, green, blue, representation = preview.sample_icns(icns)
    except RuntimeError as error:
        retain_icon_diagnostic(output, variant, icns)
        raise SystemExit(f"{variant['id']} compiled icon {icns.name} could not be sampled: {error}") from error
    kind = preview.classify_icon_color(red, green, blue)
    expected = preview.expected_icon_color(variant)
    print(
        f"{variant['id']} compiled icon {icns.name} representation {representation} "
        f"RGB {red:.1f} {green:.1f} {blue:.1f} classified {kind}",
        flush=True,
    )
    if kind != expected:
        retain_icon_diagnostic(output, variant, icns)
        raise SystemExit(
            f"{variant['id']} compiled icon {icns.name} representation {representation} "
            f"RGB {red:.1f} {green:.1f} {blue:.1f} looks {kind}, expected {expected}"
        )
    if universal:
        verify_universal_bundle(app)
    sign_bundle(app, workspace / "msgblast/msgblastDebug.entitlements",
                signing.signing_identity if signing else "-", signing.keychain if signing else None)
    signing_record = notarize_preview(app, signing, variant["bundle_id"]) if signing else {"mode": "ad-hoc"}
    short = source_revision[:12]
    zip_name = f"{variant['artifact_prefix']}-{short}.zip"
    zip_path = output / zip_name
    if zip_path.exists():
        zip_path.unlink()
    run(["ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", str(app), str(zip_path)], output)
    with tempfile.TemporaryDirectory() as extracted:
        run(["ditto", "-x", "-k", str(zip_path), extracted], output)
        packed = Path(extracted) / variant["app_name"]
        run(["codesign", "--verify", "--deep", "--strict", "--verbose=2", str(packed)], output)
    return {
        "id": variant["id"],
        "label": variant["label"],
        "fixture": variant["fixture"],
        "app_name": variant["app_name"],
        "bundle_id": variant["bundle_id"],
        "support_directory": f"~/Library/Application Support/{variant['support_directory']}",
        "zip": zip_name,
        "sha256": preview.sha256_file(zip_path),
        "compiled_icon": icns.name,
        "compiled_icon_representation": representation,
        "compiled_icon_sha256": preview.sha256_file(icns),
        "compiled_icon_rgb": [round(red, 1), round(green, 1), round(blue, 1)],
        "icon_fill_sha256": preview.sha256_file(variant["icon_source"] / "icon.json"),
        "updates": "disabled",
        "signing": signing_record,
        "instructions": instructions(variant, stable=bool(signing)),
    }


def instructions(variant, stable=False):
    signing_note = ("This preview has verified Developer ID signing and Apple notarization. " if stable else
                    "Ad-hoc builds may need System Settings → Privacy & Security → Open Anyway. ")
    shared = (" A quarantined download may App Translocate and show an install gate. Drag this app file to Applications "
              "and leave /Applications/msgblast.app in place. " + signing_note +
              "There is no Sparkle feed, so this app will not download or relaunch over the installed production app.")
    if variant["fixture"]:
        return ("Unzip msgblast Demo.app. Fixture mode is explicit (msgblastDemo): it uses simulated Cedar, Lumen, and Orbit "
                "data and does not read Messages. A blue icon alone is not what turns fixture mode on. "
                "Preferences follow the bundle ID com.msgblast.demo. Saved state is in ~/Library/Application Support/msgblast-Demo, "
                "which other local demo builds also use, and is separate from production and from msgblast Dev." + shared)
    permission_note = ("Keep this signing identity and installed path for subsequent builds; verify permission retention after updates. "
                       if stable else "Permissions may need to be granted again after a rebuild because the ad-hoc code hash changes. ")
    return ("Unzip msgblast Dev.app and use it to exercise this branch with live data. Do not pass --demo or --isolated-demo; "
            "use the blue msgblast Demo.app for fixtures and simulated demonstrations. It is not a fixture and can read real Messages. "
            "Grant this bundle Full Disk Access, Contacts, and Messages Automation. Those permissions belong to com.msgblast.development, "
            "and do not transfer from com.msgblast.mac. " + permission_note +
            "Preferences are the standard defaults for that bundle ID. Grok Bot remembers its connection using hardware-encrypted storage when a Secure Enclave is available. Settings labels session-only storage if no secure backend is available. "
            "Saved state is in ~/Library/Application Support/msgblast-Dev." + shared)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--sha", required=True)
    parser.add_argument("--run-url", required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--enable-dev-telemetry", action="store_true", help="Enable consent-controlled real Dev statistics through Cloudflare; Demo remains disabled")
    parser.add_argument("--universal", action="store_true", help="Build and verify arm64 and x86_64 app, frameworks, and helpers")
    parser.add_argument("--variant", choices=("all", "development", "demo"), default="all")
    parser.add_argument("--signing-identity", help="Maintainer Developer ID Application identity; never falls back to ad-hoc")
    parser.add_argument("--team-id")
    parser.add_argument("--keychain", type=Path)
    parser.add_argument("--notary-profile")
    args = parser.parse_args()
    signing = None
    if args.signing_identity:
        if not args.team_id or not release.developer_id_identity_matches(args.signing_identity, args.team_id):
            parser.error("Stable signing requires a Developer ID Application identity matching --team-id")
        if not args.keychain or not args.notary_profile:
            parser.error("Stable signing requires --keychain and --notary-profile")
        signing = args
    elif any((args.team_id, args.keychain, args.notary_profile)):
        parser.error("Signing options require --signing-identity")
    if len(args.sha) < 12 or any(character not in "0123456789abcdef" for character in args.sha):
        parser.error("SHA must be a hex commit id")
    for tool in ("xcodebuild", "codesign", "ditto"):
        if shutil.which(tool) is None:
            raise SystemExit(f"Required macOS tool is missing: {tool}")
    preview.assert_committed_icons_unchanged()
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    records = []
    with tempfile.TemporaryDirectory(prefix="msgblast-preview-") as temporary:
        workspace = preview.copy_workspace(Path(temporary) / "src")
        for variant in preview.VARIANTS.values():
            if args.variant == "all" or args.variant == variant["id"]:
                records.append(package_variant(workspace, variant, args.sha, output, args.enable_dev_telemetry, signing, args.universal))
    if len({record["compiled_icon_sha256"] for record in records}) != len(records):
        raise SystemExit("Compiled preview icons are identical, so artwork selection did not change the app")
    if len({record["compiled_icon"] for record in records}) != len(records):
        raise SystemExit("Preview variants resolved the same compiled icon filename")
    preview.assert_committed_icons_unchanged()
    document = preview.manifest(args.sha, args.run_url, records)
    manifest_path = output / "preview-manifest.json"
    manifest_path.write_text(json.dumps(document, indent=2) + "\n")
    print(manifest_path)
    summary = os.environ.get("GITHUB_STEP_SUMMARY")
    if summary:
        lines = [
            "## Branch preview apps",
            "",
            f"Source `{args.sha}`",
            "",
            f"Run: {args.run_url}",
            "",
            f"GitHub deletes these artifacts {preview.RETENTION_DAYS} days after this run.",
            "",
            "| Variant | Fixture | ZIP | SHA-256 |",
            "| --- | --- | --- | --- |",
        ]
        for record in records:
            lines.append(f"| {record['label']} | {record['fixture']} | `{record['zip']}` | `{record['sha256']}` |")
        Path(summary).write_text("\n".join(lines) + "\n")


if __name__ == "__main__":
    main()
