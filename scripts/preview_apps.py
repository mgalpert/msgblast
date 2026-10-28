"""Plan non-publishing macOS preview apps. Building still requires Xcode."""
from pathlib import Path
import binascii
import hashlib
import json
import shutil
import struct
import zlib


ROOT = Path(__file__).resolve().parents[1]
POLISHED = ROOT / "output/app-icons/msgblast.icon"
BLUE_GREEN = ROOT / "output/app-icons/msgblast-dev.icon"
BLUE = ROOT / "output/app-icons/msgblast-demo.icon"
RETENTION_DAYS = 14

VARIANTS = {
    "development": {
        "id": "development",
        "label": "blue-green development",
        "fixture": False,
        "app_name": "msgblast Dev.app",
        "bundle_id": "com.msgblast.development",
        "bundle_name": "msgblast Dev",
        "display_name": "msgblast Dev",
        "icon_name": "AppIcon",
        "icon_source": BLUE_GREEN,
        "replace_app_icon": True,
        "demo": False,
        "support_directory": "msgblast-Dev",
        "artifact_prefix": "msgblast-dev",
        "development": True,
        "in_all": True,
    },
    "demo": {
        "id": "demo",
        "label": "blue demo fixture",
        "fixture": True,
        "app_name": "msgblast Demo.app",
        "bundle_id": "com.msgblast.demo",
        "bundle_name": "msgblast Demo",
        "display_name": "msgblast Demo",
        "icon_name": "AppIconDemo",
        "icon_source": BLUE,
        "replace_app_icon": False,
        "demo": True,
        "support_directory": "msgblast-Demo",
        "artifact_prefix": "msgblast-demo",
        "development": False,
        "in_all": True,
    },
    # A second live development identity for phone testing. Built only when asked for by name,
    # so the "all" set that CI uploads stays msgblast Dev plus msgblast Demo.
    "development-remote": {
        "id": "development-remote",
        "label": "blue-green development for remote phone testing",
        "fixture": False,
        "app_name": "msgblast Dev Remote.app",
        "bundle_id": "com.msgblast.development.remote",
        "bundle_name": "msgblast Dev Remote",
        "display_name": "msgblast Dev Remote",
        "icon_name": "AppIcon",
        "icon_source": BLUE_GREEN,
        "replace_app_icon": True,
        "demo": False,
        "support_directory": "msgblast-Dev-Remote",
        "artifact_prefix": "msgblast-dev-remote",
        "development": True,
        "in_all": False,
    },
}


def selected_variants(choice):
    """Return the variants one --variant choice builds. "all" keeps the CI pair."""
    if choice == "all":
        return [variant for variant in VARIANTS.values() if variant["in_all"]]
    return [VARIANTS[choice]]


def icon_fill(directory):
    return json.loads((Path(directory) / "icon.json").read_text())["fill"]


def icon_contents(directory):
    """Compare the complete saved artwork, including layers and image assets."""
    directory = Path(directory)
    return {str(path.relative_to(directory)): path.read_bytes()
            for path in directory.rglob("*") if path.is_file() and path.name != ".DS_Store"}


def assert_committed_icons_unchanged():
    if icon_contents(ROOT / "msgblast/AppIcon.icon") != icon_contents(POLISHED):
        raise RuntimeError("Committed AppIcon.icon must stay the green production artwork")
    if icon_contents(ROOT / "msgblast/AppIconDemo.icon") != icon_contents(BLUE):
        raise RuntimeError("Committed AppIconDemo.icon must stay the saved blue artwork")
    if icon_fill(BLUE_GREEN) == icon_fill(POLISHED) or icon_fill(BLUE) == icon_fill(POLISHED):
        raise RuntimeError("Preview icon fills must differ from production green")


def stage_icons(workspace):
    """Select preview artwork only inside an isolated copy of the project."""
    workspace = Path(workspace)
    app_icon = workspace / "msgblast/AppIcon.icon"
    demo_icon = workspace / "msgblast/AppIconDemo.icon"
    if not app_icon.is_dir() or not demo_icon.is_dir():
        raise RuntimeError("Isolated workspace is missing icon resources")
    if Path(workspace).resolve() == ROOT.resolve():
        raise RuntimeError("Refusing to replace icons in the committed source tree")
    shutil.rmtree(app_icon)
    shutil.copytree(BLUE_GREEN, app_icon)
    if icon_contents(app_icon) != icon_contents(BLUE_GREEN):
        raise RuntimeError("Development workspace did not receive the blue-green icon")
    if icon_contents(demo_icon) != icon_contents(BLUE):
        raise RuntimeError("Demo workspace must keep the saved blue AppIconDemo artwork")
    assert_committed_icons_unchanged()


def configure_info(info, variant, source_revision):
    """Return the Info.plist fields that make a preview app unmistakable and isolated."""
    if variant["bundle_id"] == "com.msgblast.mac" or variant["app_name"] == "msgblast.app":
        raise RuntimeError("Preview apps cannot use the production identity")
    updated = dict(info)
    updated.update({
        "CFBundleIdentifier": variant["bundle_id"],
        "CFBundleName": variant["bundle_name"],
        "CFBundleDisplayName": variant["display_name"],
        "CFBundleIconName": variant["icon_name"],
        "CFBundleIconFile": variant["icon_name"],
        "SUFeedURL": "",
        "SUPublicEDKey": "",
        "SUEnableAutomaticChecks": False,
        "SUAutomaticallyUpdate": False,
        "SUAllowsAutomaticUpdates": False,
        "msgblastDisableUpdates": True,
        "msgblastDemo": variant["demo"],
        "msgblastSupportDirectory": variant["support_directory"],
        "msgblastPreviewVariant": variant["id"],
        "msgblastSourceRevision": source_revision,
    })
    if variant["fixture"] and updated["msgblastDemo"] is not True:
        raise RuntimeError("Fixture mode requires msgblastDemo, not only a blue icon")
    if variant["development"] and (variant["fixture"] or updated["msgblastDemo"] is not False):
        raise RuntimeError("Development previews must stay out of fixture mode")
    if not variant["fixture"] and updated["msgblastDemo"] is True:
        raise RuntimeError("The development preview must stay out of fixture mode")
    return updated


def verify_configured_info(info, variant, source_revision):
    expected = configure_info(info, variant, source_revision)
    for key, value in expected.items():
        if info.get(key) != value:
            raise RuntimeError(f"{variant['id']} Info.plist {key} is {info.get(key)!r}, expected {value!r}")
    feed = info.get("SUFeedURL") or ""
    if "updates.msgblast.app" in feed or info.get("SUPublicEDKey"):
        raise RuntimeError("Preview apps cannot carry the production update feed or key")
    if info.get("CFBundleIdentifier") == "com.msgblast.mac":
        raise RuntimeError("Preview bundle ID collided with production")


def classify_icon_color(red, green, blue):
    if green > red + 40 and green > blue + 40:
        return "green"
    if blue > red + 40 and blue > green + 20:
        return "blue"
    if blue > red + 20 and green > red + 20:
        return "blue-green"
    return "unknown"


def expected_icon_color(variant):
    return "blue-green" if variant["development"] else "blue"


def icon_filename(raw):
    """Return a single Resources file name, adding .icns when the plist omitted it."""
    if not isinstance(raw, str):
        raise RuntimeError("Compiled icon name is missing")
    name = raw.strip()
    if not name or Path(name).name != name or name in {".", ".."}:
        raise RuntimeError(f"Compiled icon name must stay inside Resources: {raw!r}")
    if not name.endswith(".icns"):
        name += ".icns"
    if Path(name).name != name:
        raise RuntimeError(f"Compiled icon name must stay inside Resources: {raw!r}")
    return name


def compiled_icon_path(app, info, icon_name):
    """Resolve the icns Xcode actually compiled, and reject anything outside Resources."""
    resources = Path(app) / "Contents/Resources"
    selected = icon_filename(icon_name)
    declared = info.get("CFBundleIconFile") or icon_name
    filename = icon_filename(declared)
    if filename != selected:
        raise RuntimeError(f"CFBundleIconFile names {filename}, but this variant selected {selected}")
    icon = resources / filename
    if icon.is_symlink() or not icon.is_file():
        raise RuntimeError(f"bundle has no compiled {filename} inside Resources")
    if icon.resolve().parent != resources.resolve():
        raise RuntimeError(f"Compiled icon {filename} escapes Resources")
    return icon.resolve()


PNG_SIGNATURE = b"\x89PNG\r\n\x1a\n"
# Largest explicit PNG-backed ICNS types first. Sampling never asks AppKit to resolve appearance.
PREFERRED_ICNS_TYPES = ("ic10", "ic14", "ic09", "ic13", "ic08", "ic07", "ic12", "ic11")
# Stable fractions of the selected bitmap: left/right midline, then top/bottom midline.
SAMPLE_FRACTIONS = ((0.12, 0.50), (0.88, 0.50), (0.50, 0.12), (0.50, 0.88))


def parse_icns(data):
    if len(data) < 8 or data[:4] != b"icns":
        raise RuntimeError("Compiled icon is not an ICNS file")
    total = struct.unpack(">I", data[4:8])[0]
    if total < 8 or total > len(data):
        raise RuntimeError("ICNS length does not match the file")
    chunks = {}
    offset = 8
    while offset + 8 <= total:
        ostype = data[offset:offset + 4].decode("ascii", "replace")
        length = struct.unpack(">I", data[offset + 4:offset + 8])[0]
        if length < 8 or offset + length > total:
            raise RuntimeError(f"ICNS chunk {ostype} is truncated")
        chunks[ostype] = data[offset + 8:offset + length]
        offset += length
    return chunks


def select_icns_representation(chunks):
    for name in PREFERRED_ICNS_TYPES:
        payload = chunks.get(name)
        if payload and payload.startswith(PNG_SIGNATURE):
            return name, payload
    raise RuntimeError("Compiled icon has no PNG representation among " + ", ".join(PREFERRED_ICNS_TYPES))


def decode_png(data):
    """Decode a non-interlaced 8-bit RGB or RGBA PNG. No image library and no color management."""
    if not data.startswith(PNG_SIGNATURE):
        raise RuntimeError("Icon representation is not a PNG")
    offset = 8
    width = height = color_type = None
    idat = []
    while offset + 12 <= len(data):
        length = struct.unpack(">I", data[offset:offset + 4])[0]
        if offset + 12 + length > len(data):
            raise RuntimeError("Icon PNG chunk is truncated")
        tag = data[offset + 4:offset + 8]
        chunk = data[offset + 8:offset + 8 + length]
        expected = struct.unpack(">I", data[offset + 8 + length:offset + 12 + length])[0]
        if binascii.crc32(tag + chunk) & 0xFFFFFFFF != expected:
            raise RuntimeError("Icon PNG chunk CRC mismatch")
        if tag == b"IHDR":
            width, height, bit_depth, color_type, compression, filter_method, interlace = struct.unpack(">IIBBBBB", chunk)
            if bit_depth != 8 or color_type not in (2, 6) or compression or filter_method or interlace:
                raise RuntimeError("Icon PNG must be non-interlaced 8-bit RGB or RGBA")
        elif tag == b"IDAT":
            idat.append(chunk)
        elif tag == b"IEND":
            break
        offset += 12 + length
    if not width or not height or not idat:
        raise RuntimeError("Icon PNG is missing an image")
    channels = 4 if color_type == 6 else 3
    raw = zlib.decompress(b"".join(idat))
    stride = width * channels
    rows = []
    pos = 0
    for _ in range(height):
        if pos + 1 + stride > len(raw):
            raise RuntimeError("Icon PNG is truncated")
        filter_type = raw[pos]
        pos += 1
        row = bytearray(raw[pos:pos + stride])
        pos += stride
        previous = rows[-1] if rows else bytearray(stride)
        if filter_type == 1:
            for index in range(stride):
                left = row[index - channels] if index >= channels else 0
                row[index] = (row[index] + left) & 255
        elif filter_type == 2:
            for index in range(stride):
                row[index] = (row[index] + previous[index]) & 255
        elif filter_type == 3:
            for index in range(stride):
                left = row[index - channels] if index >= channels else 0
                row[index] = (row[index] + ((left + previous[index]) // 2)) & 255
        elif filter_type == 4:
            for index in range(stride):
                left = row[index - channels] if index >= channels else 0
                up = previous[index]
                up_left = previous[index - channels] if index >= channels else 0
                estimate = left + up - up_left
                nearest = left
                if abs(estimate - up) < abs(estimate - nearest):
                    nearest = up
                if abs(estimate - up_left) < abs(estimate - nearest):
                    nearest = up_left
                row[index] = (row[index] + nearest) & 255
        elif filter_type != 0:
            raise RuntimeError(f"Unsupported PNG filter {filter_type}")
        rows.append(row)
    return width, height, channels, rows


def _pixel(rows, channels, x, y):
    row = rows[y]
    index = x * channels
    alpha = row[index + 3] if channels == 4 else 255
    return row[index], row[index + 1], row[index + 2], alpha


def _sample_point(rows, width, height, channels, x_fraction, y_fraction):
    x = min(width - 1, max(0, int(x_fraction * width)))
    y = min(height - 1, max(0, int(y_fraction * height)))
    center_x = width // 2
    center_y = height // 2
    seen = set()
    while True:
        red, green, blue, alpha = _pixel(rows, channels, x, y)
        if alpha >= 128:
            return red, green, blue
        if (x, y) in seen:
            raise RuntimeError("Icon sample stayed transparent")
        seen.add((x, y))
        if abs(x - center_x) >= abs(y - center_y) and x != center_x:
            x += 1 if x < center_x else -1
        elif y != center_y:
            y += 1 if y < center_y else -1
        else:
            raise RuntimeError("Icon sample stayed transparent")


def sample_icns(path):
    """Return mean RGB and the OSType of one explicitly chosen ICNS bitmap."""
    chunks = parse_icns(Path(path).read_bytes())
    representation, payload = select_icns_representation(chunks)
    width, height, channels, rows = decode_png(payload)
    samples = [_sample_point(rows, width, height, channels, x_fraction, y_fraction) for x_fraction, y_fraction in SAMPLE_FRACTIONS]
    count = len(samples)
    red = sum(sample[0] for sample in samples) / count
    green = sum(sample[1] for sample in samples) / count
    blue = sum(sample[2] for sample in samples) / count
    return red, green, blue, representation


def sha256_file(path):
    digest = hashlib.sha256()
    with Path(path).open("rb") as file:
        for chunk in iter(lambda: file.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def manifest(source_revision, run_url, variants):
    return {
        "source_revision": source_revision,
        "run_url": run_url,
        "retention_days": RETENTION_DAYS,
        "expiry": f"GitHub deletes these artifacts {RETENTION_DAYS} days after the workflow run.",
        "production_feed_used": False,
        "variants": variants,
    }


def copy_workspace(destination):
    destination = Path(destination).resolve()
    root = ROOT.resolve()
    if destination == root or root in destination.parents:
        raise RuntimeError("Isolated workspace must be outside the source tree")

    def ignore(directory, names):
        skipped = {".git", "build", ".venv", "node_modules", "__pycache__"}
        return [name for name in names if name in skipped]

    shutil.copytree(ROOT, destination, ignore=ignore, symlinks=True)
    stage_icons(destination)
    return destination
