#!/usr/bin/env python3
"""Prepare signed Sparkle releases locally (Developer ID or explicit ad-hoc). Never publishes."""
import argparse
import base64
import binascii
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shlex
import shutil
import subprocess
import sys
import tempfile
from urllib.parse import urlsplit
import xml.etree.ElementTree as ET


ROOT = Path(__file__).resolve().parents[1]
SPARKLE = "{http://www.andymatuschak.org/xml-namespaces/sparkle}"


class ReleaseError(Exception):
    pass


def parse_args(args=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--version", required=True, help="Marketing version, e.g. 0.1.0")
    parser.add_argument("--build", required=True, type=int, help="Explicit increasing release counter")
    parser.add_argument("--previous-build", required=True, type=int, help="Highest previously published counter; 0 for first release")
    parser.add_argument("--signing-mode", choices=("developer-id", "ad-hoc"), default="developer-id")
    parser.add_argument("--identity", help="Full Developer ID Application identity; developer-id mode only")
    parser.add_argument("--team-id")
    parser.add_argument("--notary-profile", help="Existing notarytool Keychain profile, never a password")
    parser.add_argument("--notary-keychain", type=Path, help="Keychain containing the notarization profile; optional for local profiles")
    parser.add_argument("--feed-url", required=True, help="Chosen static HTTPS appcast URL")
    parser.add_argument("--download-url-prefix", required=True, help="Chosen static HTTPS archive directory, ending in /")
    parser.add_argument("--public-key", required=True, help="Base64 Sparkle Ed25519 public key (32 bytes)")
    parser.add_argument("--sparkle-bin", required=True, type=Path, help="bin directory from Sparkle 2.10.0 distribution")
    parser.add_argument("--keychain-account", default="msgblast", help="Existing Sparkle Keychain account")
    parser.add_argument("--ed-key-file", type=Path, help="Persistent base64 32-byte Sparkle private seed file; replaces Keychain signing")
    parser.add_argument("--release-notes", type=Path, help="Markdown notes; defaults to release-notes/VERSION.md")
    parser.add_argument("--output", type=Path, help="Fresh output directory; defaults to build/releases/VERSION-BUILD")
    parser.add_argument("--dry-run", action="store_true", help="Validate inputs and print commands without executing or writing")
    options = parser.parse_args(args)
    options.output = (options.output or ROOT / "build/releases" / f"{options.version}-{options.build}").resolve()
    options.release_notes = (options.release_notes or ROOT / "release-notes" / f"{options.version}.md").resolve()
    options.sparkle_bin = options.sparkle_bin.resolve()
    if options.ed_key_file:
        options.ed_key_file = options.ed_key_file.resolve()
    if options.notary_keychain:
        options.notary_keychain = options.notary_keychain.resolve()
    return options


def validate_https(url):
    parsed = urlsplit(url)
    try:
        parsed.port  # Access validates malformed ports too.
    except ValueError as error:
        raise ReleaseError(f"Invalid HTTPS URL: {url}") from error
    if (parsed.scheme != "https" or not parsed.hostname or parsed.username or parsed.password
            or parsed.fragment or parsed.query or any(char.isspace() for char in url)):
        raise ReleaseError("Feed and archive URLs must be static HTTPS URLs without credentials, query strings or fragments")
    return parsed


def validate_production_icon(root=ROOT):
    """Stop release preparation if the app resource differs from the saved live icon."""
    saved = root / "output/app-icons/msgblast.icon"
    resource = root / "msgblast/AppIcon.icon"

    def contents(directory):
        if not directory.is_dir():
            raise ReleaseError("Saved production icon and AppIcon resource must exist")
        return {str(path.relative_to(directory)): path.read_bytes()
                for path in directory.rglob("*") if path.is_file() and path.name != ".DS_Store"}

    expected = contents(saved)
    if not expected or expected != contents(resource):
        raise ReleaseError("Release AppIcon must match the saved green production icon; see AGENTS.md")


def developer_id_identity_matches(identity, team):
    return bool(team and re.fullmatch(r"[A-Z0-9]{10}", team) and identity
                and identity.startswith("Developer ID Application: ") and identity.endswith(f"({team})"))


def validate_options(options):
    validate_production_icon()
    if not re.fullmatch(r"[0-9]+(?:\.[0-9]+){1,2}", options.version):
        raise ReleaseError("Marketing version must be numeric, e.g. 0.1.0")
    if options.previous_build < 0 or options.build <= options.previous_build:
        raise ReleaseError("Build must be a positive release counter greater than previous-build")
    if options.signing_mode == "developer-id":
        if not options.team_id or not re.fullmatch(r"[A-Z0-9]{10}", options.team_id):
            raise ReleaseError("team-id must be the 10-character Apple Developer Team ID")
        if not developer_id_identity_matches(options.identity, options.team_id):
            raise ReleaseError("A Developer ID Application identity for team-id is required")
        if not options.notary_profile or not options.notary_profile.strip():
            raise ReleaseError("Notarization Keychain profile is required for developer-id signing")
    elif any((options.identity, options.team_id, options.notary_profile, options.notary_keychain)):
        raise ReleaseError("Apple identity/team/notary inputs cannot be used with ad-hoc signing")
    if not options.ed_key_file and not options.keychain_account.strip():
        raise ReleaseError("Sparkle Keychain account or ed-key-file is required")
    feed = validate_https(options.feed_url)
    validate_https(options.download_url_prefix)
    if not feed.path.endswith(".xml"):
        raise ReleaseError("feed-url must name an XML appcast file")
    if not options.download_url_prefix.endswith("/"):
        raise ReleaseError("download-url-prefix must end in /")
    try:
        public_key = base64.b64decode(options.public_key, validate=True)
    except (ValueError, binascii.Error) as error:
        raise ReleaseError("Sparkle public key must be base64-encoded Ed25519 data") from error
    if len(public_key) != 32:
        raise ReleaseError("Sparkle public key must decode to 32 bytes")
    if not options.release_notes.is_file() or not options.release_notes.read_text().strip():
        raise ReleaseError("A nonempty release notes file is required")


def archive_name(options):
    return f"msgblast-{options.version}-{options.build}.zip"


def feed_path(options):
    return options.output / "publish" / Path(urlsplit(options.feed_url).path).name


def export_options(options):
    return {"method": "developer-id", "signingStyle": "manual", "teamID": options.team_id,
            "signingCertificate": options.identity}


def commands_by_step(options):
    """Single command contract shared by dry-run output and real preparation."""
    output = options.output
    ad_hoc = options.signing_mode == "ad-hoc"
    app = output / "export/msgblast.app"
    archive = output / "publish" / archive_name(options)
    account = (["--ed-key-file", str(options.ed_key_file)] if options.ed_key_file
               else ["--account", options.keychain_account])
    commands = {}
    if not ad_hoc:
        commands["identity"] = ["security", "find-identity", "-v", "-p", "codesigning"]
    commands["public_key"] = [str(options.sparkle_bin / "generate_keys"), *account, "-p"]
    if options.ed_key_file:
        # CryptoKit reads the seed from the private file. Only its path and public key
        # appear in commands/logs; the seed never reaches argv or generated artifacts.
        code = """import Foundation
import CryptoKit
let encoded = try String(contentsOfFile: CommandLine.arguments[1], encoding: .utf8)
let seed = Data(base64Encoded: encoded.trimmingCharacters(in: .whitespacesAndNewlines))!
let key = try Curve25519.Signing.PrivateKey(rawRepresentation: seed)
print(key.publicKey.rawRepresentation.base64EncodedString())
"""
        commands["public_key"] = ["swift", "-e", code, str(options.ed_key_file)]
    notary_keychain = ["--keychain", str(options.notary_keychain)] if options.notary_keychain else []
    if not ad_hoc:
        commands["notary_credentials"] = ["xcrun", "notarytool", "history", "--keychain-profile",
                                          options.notary_profile or "", *notary_keychain, "--output-format", "json"]

    signing_settings = (["ENABLE_HARDENED_RUNTIME=YES"] if ad_hoc else [
        "DEVELOPMENT_TEAM=" + (options.team_id or ""), "CODE_SIGN_IDENTITY=" + (options.identity or ""),
        "CODE_SIGN_STYLE=Manual", "ENABLE_HARDENED_RUNTIME=YES", "OTHER_CODE_SIGN_FLAGS=--timestamp"])
    archive_tail = ["ONLY_ACTIVE_ARCH=NO", "ASSETCATALOG_COMPILER_APPICON_NAME=AppIcon"]
    if ad_hoc:
        archive_tail.append("CODE_SIGNING_ALLOWED=NO")
    commands["archive"] = [
        "xcodebuild", "-project", str(ROOT / "msgblast.xcodeproj"), "-scheme", "msgblast",
        "-configuration", "Release", "-destination", "generic/platform=macOS",
        "-derivedDataPath", str(output / "DerivedData"), "-archivePath", str(output / "msgblast.xcarchive"),
        "MARKETING_VERSION=" + options.version, "CURRENT_PROJECT_VERSION=" + str(options.build),
        "SPARKLE_FEED_URL=" + options.feed_url, "SPARKLE_PUBLIC_ED_KEY=" + options.public_key,
        "MSGBLAST_TELEMETRY_ENDPOINT=https://msgblast.app/api/telemetry",
        *signing_settings, *archive_tail, "archive"]
    if ad_hoc:
        commands["export"] = ["ditto", str(output / "msgblast.xcarchive/Products/Applications/msgblast.app"), str(app)]
        # The nested code paths exist only after archiving. prepare() signs them
        # inside-out before this outer app command.
        commands["ad_hoc_sign"] = ["codesign", "--force", "--sign", "-", "--options", "runtime", "--entitlements",
                                   str(ROOT / "msgblast/msgblastAdHoc.entitlements"), str(app)]
    else:
        commands["export"] = ["xcodebuild", "-exportArchive", "-archivePath", str(output / "msgblast.xcarchive"),
                              "-exportPath", str(output / "export"), "-exportOptionsPlist", str(output / "ExportOptions.plist")]
    commands["code_verify"] = ["codesign", "--verify", "--deep", "--strict", "--verbose=2", str(app)]
    commands["code_identity"] = ["codesign", "-dv", "--verbose=4", str(app)]
    commands["entitlements"] = ["codesign", "-d", "--entitlements", ":-", str(app)]
    if not ad_hoc:
        commands["notary_package"] = ["ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", str(app), str(output / "notarization.zip")]
        commands["notarize"] = ["xcrun", "notarytool", "submit", str(output / "notarization.zip"), "--keychain-profile",
                                options.notary_profile or "", *notary_keychain, "--wait", "--output-format", "json"]
        commands["staple"] = ["xcrun", "stapler", "staple", str(app)]
        commands["staple_verify"] = ["xcrun", "stapler", "validate", str(app)]
        commands["gatekeeper"] = ["spctl", "--assess", "--type", "execute", "--verbose=2", str(app)]
    commands["final_code_verify"] = ["codesign", "--verify", "--deep", "--strict", "--verbose=2", str(app)]
    commands["package"] = ["ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", str(app), str(archive)]
    commands["sign_archive"] = [str(options.sparkle_bin / "sign_update"), *account, "-p", str(archive)]
    commands["verify_archive"] = [str(options.sparkle_bin / "sign_update"), *account, "--verify", str(archive), "<archive-signature>"]
    commands["appcast"] = [str(options.sparkle_bin / "generate_appcast"), *account, "--download-url-prefix",
                           options.download_url_prefix, "--embed-release-notes", "--maximum-deltas", "0", "-o",
                           str(feed_path(options)), str(output / "publish")]
    commands["sign_feed"] = [str(options.sparkle_bin / "sign_update"), *account, str(feed_path(options))]
    commands["verify_feed"] = [str(options.sparkle_bin / "sign_update"), *account, "--verify", str(feed_path(options))]
    return commands


def validate_private_seed_file(key_file):
    """Reject invalid seed formats without passing their content to external tools."""
    try:
        seed = base64.b64decode(key_file.read_text().strip(), validate=True)
    except (ValueError, binascii.Error, UnicodeError) as error:
        raise ReleaseError("ed-key-file must contain a base64 32-byte private seed") from error
    if len(seed) != 32:
        raise ReleaseError("ed-key-file must contain a base64 32-byte private seed")


def validate_private_seed(options):
    if not options.ed_key_file:
        return
    # Read only during actual preparation, never during a credential-free dry run.
    validate_private_seed_file(options.ed_key_file)
    if options.ed_key_file.is_relative_to(options.output):
        raise ReleaseError("Private seed file must be outside the release output directory")


def sign_nested_code(options):
    app = options.output / "export/msgblast.app"
    code = []
    for path in list((app / "Contents/Frameworks").rglob("*")) + list((app / "Contents/Helpers").rglob("*")):
        if path.is_symlink():
            continue
        if path.is_dir() and path.suffix in (".framework", ".xpc", ".app"):
            code.append(path)
        elif path.is_file():
            with path.open("rb") as file:
                magic = file.read(4)
            if magic in (bytes.fromhex(value) for value in
                         ("feedface", "cefaedfe", "feedfacf", "cffaedfe", "cafebabe", "bebafeca", "cafebabf", "bfbafeca")):
                code.append(path)
    for path in sorted(code, key=lambda path: (-len(path.parts), str(path))):
        # Sparkle's sandboxed helpers retain their original signed entitlements.
        run(["codesign", "--force", "--sign", "-", "--options", "runtime",
             "--preserve-metadata=entitlements", str(path)])


def command_plan(options):
    return list(commands_by_step(options).values())


def run(command):
    print("+ " + shlex.join(command), flush=True)
    if Path(command[0]).name == "xcodebuild":
        # Successful build logs are verbose; keep only a bounded failure tail in memory.
        with tempfile.TemporaryFile() as log:
            result = subprocess.run(command, cwd=ROOT, stdout=log, stderr=subprocess.STDOUT)
            if result.returncode:
                size = log.seek(0, os.SEEK_END)
                log.seek(max(0, size - 20000))
                tail = log.read().decode("utf-8", errors="replace")
                raise ReleaseError(f"Command failed ({result.returncode}): {shlex.join(command)}\n{tail}")
        return ""
    result = subprocess.run(command, cwd=ROOT, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    if result.returncode:
        raise ReleaseError(f"Command failed ({result.returncode}): {shlex.join(command)}\n{result.stdout}")
    return result.stdout


def check_tools(options):
    names = ["xcodebuild", "codesign", "ditto"]
    if options.signing_mode == "developer-id":
        names += ["xcrun", "spctl", "security"]
    if options.ed_key_file:
        names.append("swift")
    for name in names:
        if shutil.which(name) is None:
            raise ReleaseError(f"Required macOS tool is missing: {name}")
    sparkle_tools = ["sign_update", "generate_appcast"]
    if not options.ed_key_file:
        sparkle_tools.append("generate_keys")
    for name in sparkle_tools:
        if not os.access(options.sparkle_bin / name, os.X_OK):
            raise ReleaseError(f"Sparkle 2.10.0 tool is missing or not executable: {name}")


def verify_bundle(options):
    app = options.output / "export/msgblast.app"
    with (app / "Contents/Info.plist").open("rb") as file:
        info = plistlib.load(file)
    expected = {"CFBundleIdentifier": "com.msgblast.mac", "CFBundleName": "msgblast",
                "CFBundleDisplayName": "msgblast", "CFBundleExecutable": "msgblast",
                "CFBundleVersion": str(options.build),
                "CFBundleShortVersionString": options.version, "SUFeedURL": options.feed_url,
                "SUPublicEDKey": options.public_key, "SUVerifyUpdateBeforeExtraction": True,
                "SURequireSignedFeed": True}
    for key, value in expected.items():
        if info.get(key) != value:
            raise ReleaseError(f"Exported bundle {key} does not match release configuration")
    if info.get("msgblastDemo") or info.get("msgblastPermissionGuidePreview"):
        raise ReleaseError("A demo/permission-preview bundle cannot be released")
    for name in ("msgblastCore", "Sparkle"):
        if not (app / f"Contents/Frameworks/{name}.framework").is_dir():
            raise ReleaseError(f"Exported app is missing {name}.framework")
    if not (app / "Contents/Helpers/cloudflared").is_file():
        raise ReleaseError("Exported app is missing its bundled cloudflared helper")
    if not (app / "Contents/Helpers/cua-driver").is_file():
        raise ReleaseError("Exported app is missing its embedded CuaDriver helper")
    for name in ("cloudflared.json", "CloudflaredNotices.txt", "cua-driver.json", "CuaDriverNotices.txt"):
        if not (app / "Contents/Resources" / name).is_file():
            raise ReleaseError(f"Exported app is missing {name}")


def verify_appcast(options, signature):
    root = ET.parse(feed_path(options)).getroot()
    items = root.findall("./channel/item")
    item = next((item for item in items if item.findtext(SPARKLE + "version") == str(options.build)), None)
    if item is None or item.findtext(SPARKLE + "shortVersionString") != options.version:
        raise ReleaseError("Generated appcast does not contain the requested version/build")
    enclosure = item.find("enclosure")
    archive = options.output / "publish" / archive_name(options)
    expected = {"url": options.download_url_prefix + archive.name,
                SPARKLE + "edSignature": signature, "length": str(archive.stat().st_size)}
    if enclosure is None or any(enclosure.get(key) != value for key, value in expected.items()):
        raise ReleaseError("Generated appcast archive URL, signature or size does not match the prepared archive")
    if not item.findtext("description"):
        raise ReleaseError("Generated appcast must include embedded release notes")


def prepare(options):
    validate_options(options)
    if options.output.exists():
        raise ReleaseError(f"Output already exists; choose a fresh directory: {options.output}")
    validate_private_seed(options)
    check_tools(options)
    signature = None
    notary_result = None
    for step, command in commands_by_step(options).items():
        if step == "archive":
            options.output.mkdir(parents=True)
            (options.output / "publish").mkdir()
            if options.signing_mode == "developer-id":
                with (options.output / "ExportOptions.plist").open("wb") as file:
                    plistlib.dump(export_options(options), file)
            shutil.copyfile(options.release_notes, options.output / "publish" / archive_name(options).replace(".zip", ".md"))
        if step == "ad_hoc_sign":
            sign_nested_code(options)
        if step == "verify_archive":
            command[-1] = signature
        result = run(command)
        if step == "identity" and f'"{options.identity}"' not in result:
            raise ReleaseError("Configured Developer ID Application signing identity is not available in the Keychain")
        if step == "public_key" and result.strip() != options.public_key:
            raise ReleaseError("Configured Sparkle public key does not match the selected signing key")
        if step == "export":
            verify_bundle(options)
        if step == "code_identity" and options.signing_mode == "ad-hoc":
            if "Signature=adhoc" not in result or not re.search(r"\([^)]*\bruntime\b[^)]*\)", result):
                raise ReleaseError("Exported app must be ad-hoc signed with hardened runtime")
        if step == "code_identity" and options.signing_mode == "developer-id":
            if (f"Authority={options.identity}" not in result or f"TeamIdentifier={options.team_id}" not in result
                    or not re.search(r"\([^)]*\bruntime\b[^)]*\)", result)):
                raise ReleaseError("Exported app must use the requested Developer ID identity and hardened runtime")
        if step == "entitlements":
            start = result.find("<?xml")
            end = result.find("</plist>", start)
            if start < 0 or end < 0:
                raise ReleaseError("Cannot read exported app entitlements")
            entitlements = plistlib.loads(result[start:end + len("</plist>")].encode())
            if entitlements.get("com.apple.security.personal-information.addressbook") is not True:
                raise ReleaseError("Exported app lost its Contacts Address Book entitlement")
            if entitlements.get("com.apple.security.automation.apple-events") is not True:
                raise ReleaseError("Exported app lost its Messages Automation entitlement")
            if (options.signing_mode == "ad-hoc"
                    and entitlements.get("com.apple.security.cs.disable-library-validation") is not True):
                raise ReleaseError("Ad-hoc app must disable library validation for nested ad-hoc frameworks")
        if step == "notarize":
            notary_result = json.loads(result)
            if notary_result.get("status") != "Accepted":
                raise ReleaseError(f"Apple notarization was not accepted: {notary_result}")
        if step == "sign_archive":
            signature = result.strip()
            try:
                valid_signature = len(base64.b64decode(signature, validate=True)) == 64
            except (ValueError, binascii.Error):
                valid_signature = False
            if not valid_signature:
                raise ReleaseError("Sparkle did not produce a valid Ed25519 archive signature")
        if step == "appcast":
            verify_appcast(options, signature)
    publish = options.output / "publish"
    manifest = {"version": options.version, "build": options.build, "previous_build": options.previous_build,
                "feed_url": options.feed_url, "archive_url": options.download_url_prefix + archive_name(options),
                "signing_mode": options.signing_mode,
                "signing_identity": options.identity if options.signing_mode == "developer-id" else "-",
                "public_key": options.public_key,
                "notarization": notary_result, "archive_signature": signature,
                "sha256": {file.name: file_sha256(file)
                           for file in publish.iterdir() if file.is_file()}}
    (publish / "release.json").write_text(json.dumps(manifest, indent=2) + "\n")
    print(f"Prepared locally: {publish}\nNothing uploaded. Publish archives first and the appcast last; see docs/updates.md.")


def file_sha256(path):
    with path.open("rb") as file:
        return hashlib.file_digest(file, "sha256").hexdigest()


def main(args=None):
    try:
        options = parse_args(args)
        if options.dry_run:
            validate_options(options)
            print("DRY RUN: no credentials checked, commands executed, files written, or assets uploaded.")
            if options.signing_mode == "developer-id":
                print("ExportOptions.plist: " + json.dumps(export_options(options), sort_keys=True))
            else:
                print("Nested frameworks/helpers are ad-hoc signed inside-out, preserving helper entitlements, before the outer app.")
            for command in command_plan(options):
                print(shlex.join(command))
        else:
            prepare(options)
        return 0
    except (ReleaseError, OSError, ValueError, ET.ParseError) as error:
        print(f"Release preparation failed: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
