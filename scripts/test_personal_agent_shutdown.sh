#!/bin/bash
# Compile the actual controller with controlled lifecycle/storage substitutes; no UI or provider requests.
set -euo pipefail
report_root="$(cd -- "$(dirname -- "$0")/.." && pwd)"
report_build="${1:-$report_root/build/personal-agent-validation}"
report_frameworks="$report_build/Build/Products/Debug"
if [[ ! -d "$report_frameworks/msgblastCore.framework" ]]; then
    echo "Build msgblast in the selected derived-data directory before running this check." >&2
    exit 1
fi
report_frameworks="$(cd -- "$report_frameworks" && pwd)"
report_tmp="$(mktemp -d "${TMPDIR:-/tmp}/msgblast-shutdown.XXXXXX")"
trap 'rm -rf "$report_tmp"' EXIT
for report_fixture in personal_agent_shutdown personal_agent_persistence; do
    xcrun swiftc -swift-version 6 -parse-as-library \
        -module-cache-path "$report_tmp/module-cache" \
        -target "$(uname -m)-apple-macos15.0" \
        -I "$report_frameworks" -F "$report_frameworks" -framework msgblastCore \
        -Xlinker -rpath -Xlinker "$report_frameworks" \
        "$report_root/msgblast/App/PersonalAgentController.swift" \
        "$report_root/scripts/fixtures/$report_fixture.swift" \
        -o "$report_tmp/check"
    "$report_tmp/check"
done
