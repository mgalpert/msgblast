#!/bin/bash
set -euo pipefail
crash_root="$(cd -- "$(dirname -- "$0")/.." && pwd)"
crash_derived="${1:?Pass the isolated derived-data directory containing msgblastCore.framework}"
crash_products="$(cd "$crash_derived/Build/Products/Debug" && pwd)"
crash_tmp="$(mktemp -d "${TMPDIR:-/tmp}/msgblast-crash-tests.XXXXXX")"
crash_server_pid=""
trap 'if [[ -n "$crash_server_pid" ]]; then kill "$crash_server_pid" 2>/dev/null || true; wait "$crash_server_pid" 2>/dev/null || true; fi; rm -rf "$crash_tmp"' EXIT
mkdir -p "$crash_tmp/CrashFixture.app/Contents/MacOS"
cat > "$crash_tmp/CrashFixture.app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.msgblast.crash-controller-fixture</string>
<key>CFBundleExecutable</key><string>check</string>
<key>msgblastDemo</key><true/>
<key>msgblastFeedbackEndpoint</key><string>http://127.0.0.1:8128/api/feedback</string>
</dict></plist>
PLIST
node "$crash_root/scripts/fixtures/crash_intake.mjs" 8128 > "$crash_tmp/server.log" 2>&1 &
crash_server_pid=$!
for _ in {1..30}; do
    kill -0 "$crash_server_pid" 2>/dev/null || { cat "$crash_tmp/server.log"; exit 1; }
    if curl -fsS http://127.0.0.1:8128/fixture-status >/dev/null 2>&1; then break; fi
    sleep 0.1
done
xcrun swiftc -swift-version 6 -parse-as-library -target "$(uname -m)-apple-macos15.0" \
    -module-cache-path "$crash_tmp/module-cache" -I "$crash_products" -F "$crash_products" -framework msgblastCore \
    -Xlinker -rpath -Xlinker "$crash_products" \
    "$crash_root/msgblast/Windows/CrashReportView.swift" \
    "$crash_root/scripts/fixtures/crash_review.swift" \
    -o "$crash_tmp/CrashFixture.app/Contents/MacOS/check"
"$crash_tmp/CrashFixture.app/Contents/MacOS/check"
