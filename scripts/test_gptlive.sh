#!/bin/bash
# Compile actual app code and exercise only isolated sample conversations.
set -euo pipefail
gptlive_root="$(cd -- "$(dirname -- "$0")/.." && pwd)"
gptlive_build="$(cd -- "${1:?Pass the native derived-data directory}" && pwd)"
gptlive_frameworks="$gptlive_build/Build/Products/Debug"
gptlive_sparkle="$gptlive_build/SourcePackages/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64"
gptlive_tmp="$(mktemp -d "${TMPDIR:-/tmp}/msgblast-gptlive-check.XXXXXX")"
trap 'rm -rf "$gptlive_tmp"' EXIT
gptlive_sources=()
while IFS= read -r source; do gptlive_sources+=("$source"); done < <(python3 - "$gptlive_root/msgblast" <<'PY'
from pathlib import Path
import sys
root = Path(sys.argv[1])
for source in sorted(root.rglob('*.swift')):
    if 'Core' not in source.relative_to(root).parts and source.name != 'msgblastApp.swift':
        print(source)
PY
)
python3 - "$gptlive_root/msgblast/App/msgblastApp.swift" "$gptlive_tmp/app-support.swift" <<'PY'
from pathlib import Path
import sys
source = Path(sys.argv[1]).read_text()
start = source.index('@main\nenum msgblastMain')
end = source.index('\n@MainActor\nprivate final class AppStartup', start)
Path(sys.argv[2]).write_text(source[:start] + source[end:])
PY
xcrun swiftc -swift-version 6 -D DEBUG -parse-as-library -target "$(uname -m)-apple-macos15.0" \
    -I "$gptlive_frameworks" -F "$gptlive_frameworks" -F "$gptlive_sparkle" -framework msgblastCore -framework Sparkle \
    -Xlinker -rpath -Xlinker "$gptlive_frameworks" -Xlinker -rpath -Xlinker "$gptlive_sparkle" \
    "${gptlive_sources[@]}" "$gptlive_tmp/app-support.swift" "$gptlive_root/scripts/fixtures/gptlive_controller.swift" -o "$gptlive_tmp/check"
"$gptlive_tmp/check" --demo --isolated-demo
