#!/bin/bash
# Compile the actual Settings controller with injected native responses. No OS grants or user data.
set -euo pipefail
permissions_root="$(cd -- "$(dirname -- "$0")/.." && pwd)"
permissions_tmp="$(mktemp -d "${TMPDIR:-/tmp}/msgblast-permissions.XXXXXX")"
trap 'rm -rf "$permissions_tmp"' EXIT
xcrun swiftc -swift-version 6 -parse-as-library \
    -module-cache-path "$permissions_tmp/module-cache" \
    -target "$(uname -m)-apple-macos15.0" \
    "$permissions_root/msgblast/Permissions/AppPermissions.swift" \
    "$permissions_root/scripts/fixtures/app_permissions.swift" \
    -o "$permissions_tmp/check"
"$permissions_tmp/check"
