"""Embed pinned upstream CuaDriver for private serve --embedded use; no runtime downloads."""
import argparse
import hashlib
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import tarfile
import tempfile
import urllib.request


MANIFEST = Path(__file__).with_name("cua-driver.json")
MAX_ARCHIVE = 200 * 1024 * 1024
MAX_BINARY = 200 * 1024 * 1024


def architectures(value):
    selected = list(dict.fromkeys(value.split()))
    if not selected or any(arch not in {"arm64", "x86_64"} for arch in selected):
        raise RuntimeError(f"Unsupported cua-driver architecture: {value!r}")
    return selected


def fetch_binary(asset, cache):
    cache.mkdir(parents=True, exist_ok=True)
    archive = cache / (asset["sha256"] + ".tgz")
    downloaded = False
    try:
        with archive.open("rb") as file:
            data = file.read(MAX_ARCHIVE + 1)
    except FileNotFoundError:
        request = urllib.request.Request(asset["url"], headers={"User-Agent": "msgblast-build"})
        with urllib.request.urlopen(request, timeout=60) as response:
            data = response.read(MAX_ARCHIVE + 1)
        downloaded = True
    if len(data) > MAX_ARCHIVE or hashlib.sha256(data).hexdigest() != asset["sha256"]:
        raise RuntimeError("cua-driver download/cache checksum mismatch")
    with tarfile.open(fileobj=io.BytesIO(data), mode="r:gz") as tar:
        members = [member for member in tar.getmembers() if member.name == asset["member"]]
        if len(members) != 1 or members[0].name != asset["member"] or not members[0].isfile() or not 0 < members[0].size <= MAX_BINARY:
            raise RuntimeError("Unexpected cua-driver archive contents")
        with tar.extractfile(members[0]) as file:
            binary = file.read(MAX_BINARY + 1)
    if downloaded:
        with tempfile.NamedTemporaryFile(dir=cache, delete=False) as temporary:
            temporary.write(data)
            staged = Path(temporary.name)
        staged.replace(archive)
    return binary


def bundle(selected, destination, cache):
    manifest = json.loads(MANIFEST.read_text())
    destination.parent.mkdir(parents=True, exist_ok=True)
    cache.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="cua-driver-", dir=cache.parent) as temporary:
        workspace = Path(temporary)
        binaries = []
        for arch in selected:
            downloaded = workspace / (arch + "-download")
            downloaded.write_bytes(fetch_binary(manifest["assets"][arch], cache))
            subprocess.run(["xcrun", "lipo", "-verify_arch", arch, str(downloaded)], check=True)
            binary = workspace / arch
            subprocess.run(["xcrun", "lipo", str(downloaded), "-thin", arch, "-output", str(binary)], check=True)
            binaries.append(binary)
        staged = workspace / "cua-driver"
        if len(binaries) == 1:
            shutil.copyfile(binaries[0], staged)
        else:
            subprocess.run(["xcrun", "lipo", "-create", *map(str, binaries), "-output", str(staged)], check=True)
        staged.chmod(0o755)
        identity = os.environ.get("EXPANDED_CODE_SIGN_IDENTITY") if os.environ.get("CODE_SIGNING_ALLOWED") != "NO" else None
        identity = identity or "-"
        command = ["codesign", "--force", "--sign", identity, "--options", "runtime"]
        if identity != "-":
            command.append("--timestamp")
        subprocess.run([*command, str(staged)], check=True)
        subprocess.run(["codesign", "--verify", "--strict", str(staged)], check=True)
        shutil.copy2(staged, destination)
    print(f"Bundled cua-driver {manifest['version']} ({', '.join(selected)}) → {destination}", flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--archs", required=True)
    parser.add_argument("--destination", type=Path, required=True)
    parser.add_argument("--cache", type=Path, required=True)
    args = parser.parse_args()
    selected = architectures(args.archs)
    args.cache.parent.mkdir(parents=True, exist_ok=True)
    bundle(selected, args.destination, args.cache)


if __name__ == "__main__":
    main()
