#!/bin/bash
# Worker for run_mac_checks.py and explicit CI use. No live accounts or production updates.
set -euo pipefail
if [[ "${MSGBLAST_REMOTE_TEST_WORKER:-}" != 1 && "${CI:-}" != true ]]; then
    echo 'Run scripts/run_mac_checks.py --host <dedicated-mac> instead; no local tests were started.' >&2
    exit 2
fi
test_root="$(cd -- "$(dirname -- "$0")/.." && pwd)"
cd "$test_root"
test_suite="${1:-all}"
test_revision="${2:?Pass the reviewed commit SHA}"
case "$test_suite" in core|controllers|updater|ui|all) ;; *) echo 'Unknown suite' >&2; exit 2 ;; esac
test_results="$test_root/build/test-results"
test_derived="$test_root/build/mac-tests"
mkdir -p "$test_results"
# Prevent concurrent interactive/native runs for this SSH account. Never remove another run's lock.
test_lock="$HOME/Library/Caches/msgblast-tests/native.lock"
mkdir -p "$(dirname -- "$test_lock")"
if ! mkdir "$test_lock" 2>/dev/null; then
    echo "Another native run owns $test_lock. Inspect it before retrying." >&2
    exit 2
fi
trap 'rmdir "$test_lock"' EXIT
printf '%s\n' "$test_revision" > "$test_results/source-revision.txt"
xcodebuild -version | tee "$test_results/xcode.txt"
test_selector='-only-testing:msgblastTests'
if [[ "$test_suite" == ui ]]; then
    test_selector='-only-testing:msgblastUITests'
    swift scripts/prepare_ui_desktop.swift 2>&1 | tee "$test_results/ui-desktop.log"
    swift scripts/prepare_ui_desktop.swift --check-only 2>&1 | tee -a "$test_results/ui-desktop.log"
fi
xcodebuild -project msgblast.xcodeproj -scheme msgblast \
    -configuration Debug -derivedDataPath "$test_derived" \
    -destination 'platform=macOS,arch=arm64' \
    -resultBundlePath "$test_results/native.xcresult" \
    MSGBLAST_APP_BUNDLE_IDENTIFIER=com.msgblast.remote-tests \
    ASSETCATALOG_COMPILER_APPICON_NAME=AppIconDemo \
    "$test_selector" test 2>&1 | tee "$test_results/native.log"
if [[ "$test_suite" == ui ]]; then
    xcrun xcresulttool get test-results summary --path "$test_results/native.xcresult" > "$test_results/ui-summary.json"
    python3 scripts/check_ui_results.py "$test_results/ui-summary.json"
fi
if [[ "$test_suite" == controllers || "$test_suite" == all ]]; then
    bash scripts/test_web_comparisons.sh "$test_derived" 2>&1 | tee "$test_results/web-controllers.log"
    bash scripts/test_configured_cli_conversations.sh "$test_derived" 2>&1 | tee "$test_results/configured-cli.log"
    bash scripts/test_personal_agent_shutdown.sh "$test_derived" 2>&1 | tee "$test_results/report-controllers.log"
    bash scripts/test_app_permissions.sh 2>&1 | tee "$test_results/permissions.log"
fi
if [[ "$test_suite" == updater || "$test_suite" == all ]]; then
    python3 scripts/test_updates.py --derived-data "$test_derived" 2>&1 | tee "$test_results/updater.log"
fi
echo "PASS: $test_suite on remote/CI Mac, source $test_revision"
