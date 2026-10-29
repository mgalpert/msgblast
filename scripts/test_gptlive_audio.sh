#!/bin/bash
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
TEST_DIR=$(mktemp -d "${TMPDIR:-/tmp}/gptlive-audio.XXXXXX")
trap 'rm -rf "$TEST_DIR"' EXIT
cat "$ROOT/msgblast/App/GPTLiveAudio.swift" "$ROOT/scripts/fixtures/gptlive_audio.swift" > "$TEST_DIR/AudioChecks.swift"
xcrun swiftc -swift-version 6 -target arm64-apple-macos15.0 -warnings-as-errors -parse-as-library "$TEST_DIR/AudioChecks.swift" -o "$TEST_DIR/audio-checks"
"$TEST_DIR/audio-checks"
