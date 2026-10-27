# Shared by the remote-control scripts: compiles the actual app sources with the
# fixture entry points into "$tmp/model" (Demo profile only). Expects $root, $build, $tmp.
build_remote_fixture_model() {
    local frameworks="$build/Build/Products/Debug"
    local sparkle="$build/SourcePackages/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64"
    cp -R "$root/msgblast/Resources/WebAgentIcons" "$tmp/WebAgentIcons"
    local sources=()
    while IFS= read -r source; do sources+=("$source"); done < <(python3 - "$root/msgblast" <<'PY'
from pathlib import Path
import sys
root = Path(sys.argv[1])
for source in sorted(root.rglob("*.swift")):
    parts = source.relative_to(root).parts
    if "Core" not in parts and "RemoteProtocol" not in parts and source.name != "msgblastApp.swift":
        print(source)
PY
)
    python3 - "$root/msgblast/App/msgblastApp.swift" "$tmp/app-support.swift" <<'PY'
from pathlib import Path
import sys
source = Path(sys.argv[1]).read_text()
start = source.index("@main\nenum msgblastMain")
end = source.index("\n@MainActor\nprivate final class AppStartup", start)
Path(sys.argv[2]).write_text(source[:start] + source[end:])
PY
    xcrun swiftc -swift-version 6 -D DEBUG -parse-as-library -module-cache-path "$tmp/modules" -target "$(uname -m)-apple-macos15.0" \
        -I "$frameworks" -F "$frameworks" -F "$sparkle" -framework msgblastCore -framework msgblastRemoteProtocol -framework Sparkle \
        -Xlinker -rpath -Xlinker "$frameworks" -Xlinker -rpath -Xlinker "$sparkle" \
        "${sources[@]}" "$tmp/app-support.swift" "$root/scripts/fixtures/web_comparison_model.swift" "$root/scripts/fixtures/permission_review_model.swift" \
        "$root/scripts/fixtures/remote_control_model.swift" -o "$tmp/model" 2> "$tmp/compile.log" || { cat "$tmp/compile.log"; return 1; }
}
