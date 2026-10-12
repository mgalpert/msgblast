#!/bin/bash
set -euo pipefail
benchmark_root="$(cd -- "$(dirname -- "$0")/.." && pwd)"
benchmark_build="${1:?Provide isolated Xcode derived data}"
benchmark_controller="${2:-$benchmark_root/msgblast/App/BenchmarkController.swift}"
benchmark_frameworks="$benchmark_build/Build/Products/Debug"
benchmark_tmp="$(mktemp -d "${TMPDIR:-/tmp}/msgblast-controller-review.XXXXXX")"
trap 'rm -rf "$benchmark_tmp"' EXIT
xcrun swiftc -swift-version 6 -D DEBUG -parse-as-library -module-cache-path "$benchmark_tmp/modules" \
  -target "$(uname -m)-apple-macos15.0" -I "$benchmark_frameworks" -F "$benchmark_frameworks" -framework msgblastCore \
  -Xlinker -rpath -Xlinker "$benchmark_frameworks" \
  "$benchmark_root/msgblast/App/PerformanceController.swift" "$benchmark_controller" \
  "$benchmark_root/msgblast/App/BenchmarkDemoFixture.swift" "$benchmark_root/scripts/fixtures/benchmark_controller_review.swift" -o "$benchmark_tmp/workflow"
"$benchmark_tmp/workflow"
