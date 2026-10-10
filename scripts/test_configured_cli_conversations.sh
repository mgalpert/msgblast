#!/bin/bash
# Exercise the actual core adapter with a deterministic local executable. No live CLI/model calls.
set -euo pipefail
cli_root="$(cd -- "$(dirname -- "$0")/.." && pwd)"
cli_build="${1:-$cli_root/build/cli-configured-validation}"
cli_frameworks="$(cd -- "$cli_build/Build/Products/Debug" && pwd)"
cli_tmp="$(mktemp -d "${TMPDIR:-/tmp}/msgblast-configured-cli.XXXXXX")"
trap 'rm -rf "$cli_tmp"' EXIT
mkdir -p "$cli_tmp/config"
printf 'fixture configuration loaded\n' > "$cli_tmp/config/tool.txt"
/usr/bin/python3 - "$cli_tmp/config" <<'PY'
import json
from pathlib import Path
import sys
config = Path(sys.argv[1])
(config / 'fixture-config.json').write_text(json.dumps({'tool_file': str(config / 'tool.txt'), 'allow_write': False}))
PY
xcrun swiftc -swift-version 6 -parse-as-library -module-cache-path "$cli_tmp/modules" \
    -target "$(uname -m)-apple-macos15.0" -I "$cli_frameworks" -F "$cli_frameworks" -framework msgblastCore \
    -Xlinker -rpath -Xlinker "$cli_frameworks" \
    "$cli_root/scripts/fixtures/configured_cli_conversations.swift" -o "$cli_tmp/check"
CODEX_HOME="$cli_tmp/config" CLAUDE_CONFIG_DIR="$cli_tmp/config" MSGBLAST_CLI_FIXTURE_LOG="$cli_tmp/requests.jsonl" \
    "$cli_tmp/check" "$cli_root/scripts/fixtures/configured_cli.py" "$cli_tmp/workspaces"
# Optional evidence export contains fixture inputs/outputs/arguments only, never user CLI configuration.
if [[ -n "${2:-}" ]]; then
    mkdir -p -- "$2"
    cp "$cli_tmp/requests.jsonl" "$2/requests.jsonl"
fi
