#!/bin/bash
# Actual app/controller code with local web + Messages fixtures; no real sends or updates.
set -euo pipefail
web_root="$(cd -- "$(dirname -- "$0")/.." && pwd)"
web_build="${1:-$web_root/build/sidechat-validation}"
web_build="$(cd -- "$web_build" && pwd)"
web_frameworks="$web_build/Build/Products/Debug"
web_sparkle="$web_build/SourcePackages/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64"
web_tmp="$(mktemp -d "${TMPDIR:-/tmp}/msgblast-web-checks.XXXXXX")"
trap 'rm -rf "$web_tmp"' EXIT
cp -R "$web_root/msgblast/Resources/WebAgentIcons" "$web_tmp/WebAgentIcons"
web_flags=(-swift-version 6 -D DEBUG -parse-as-library -module-cache-path "$web_tmp/modules"
    -target "$(uname -m)-apple-macos15.0" -I "$web_frameworks" -F "$web_frameworks" -F "$web_sparkle"
    -framework msgblastCore -framework msgblastRemoteProtocol -framework Sparkle
    -Xlinker -rpath -Xlinker "$web_frameworks" -Xlinker -rpath -Xlinker "$web_sparkle")
web_sources=()
while IFS= read -r source; do web_sources+=("$source"); done < <(python3 - "$web_root/msgblast" <<'PY_SOURCES'
from pathlib import Path
import sys
root = Path(sys.argv[1])
for source in sorted(root.rglob("*.swift")):
    parts = source.relative_to(root).parts
    # Framework sources (Core, RemoteProtocol) are linked below, not recompiled as app code.
    if "Core" not in parts and "RemoteProtocol" not in parts and source.name != "msgblastApp.swift":
        print(source)
PY_SOURCES
)
if [ "${#web_sources[@]}" -eq 0 ]; then echo "No app sources found" >&2; exit 1; fi
# Keep the real scene actions/lifecycle definitions while giving the fixture its own entry point.
python3 - "$web_root/msgblast/App/msgblastApp.swift" "$web_tmp/app-support.swift" <<'PY_SUPPORT'
from pathlib import Path
import sys
source = Path(sys.argv[1]).read_text()
start = source.index("@main\nenum msgblastMain")
end = source.index("\n@MainActor\nprivate final class AppStartup", start)
Path(sys.argv[2]).write_text(source[:start] + source[end:])
PY_SUPPORT
web_sources+=("$web_tmp/app-support.swift")
xcrun swiftc "${web_flags[@]}" "${web_sources[@]}" "$web_root/scripts/fixtures/web_comparison_model.swift" "$web_root/scripts/fixtures/permission_review_model.swift" -o "$web_tmp/model"
"$web_tmp/model" --demo --isolated-demo
# Exercise the actual startup path twice against one app-owned fixture profile.
python3 - "$web_tmp" <<'PY_REVIEW'
from pathlib import Path
import plistlib, shutil, sys, uuid
root = Path(sys.argv[1])
app = root / "PermissionReview.app" / "Contents"
(app / "MacOS").mkdir(parents=True)
shutil.copy2(root / "model", app / "MacOS" / "model")
(app / "Info.plist").write_bytes(plistlib.dumps({
    "CFBundleExecutable": "model", "CFBundleIdentifier": "com.msgblast.permission-review-fixture",
    "msgblastDemo": True, "msgblastDisableUpdates": True,
    "msgblastSupportDirectory": "msgblast-PermissionReview-" + uuid.uuid4().hex[:12],
}))
PY_REVIEW
"$web_tmp/PermissionReview.app/Contents/MacOS/model" --demo --permission-review-relaunch-fixture --contacts-access-preview

xcrun swiftc "${web_flags[@]}" "$web_root/msgblast/App/AppUpdater.swift" "$web_root/scripts/fixtures/web_broadcast_lifecycle.swift" -o "$web_tmp/lifecycle"
"$web_tmp/lifecycle"
