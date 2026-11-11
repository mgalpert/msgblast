#!/bin/bash
# Read-only native integration check. Does not launch providers or request grants.
set -euo pipefail
cd "$(dirname "$0")/.."
products="$(cd "${1:-build/contributor-tests}/Build/Products/Debug" && pwd)"
helper="$products/msgblast.app/Contents/Helpers/cua-driver"
test -x "$helper"
workspace=$(mktemp -d "${TMPDIR:-/tmp}/msgblast-embedded-check.XXXXXX")
trap 'rm -rf "$workspace"' EXIT
probe="$workspace/Embedded Runtime Probe.app"
mkdir -p "$probe/Contents/MacOS" "$probe/Contents/Helpers"
cp "$helper" "$probe/Contents/Helpers/cua-driver"
cat > "$workspace/Probe.swift" <<'SWIFT'
import Foundation
@testable import msgblastCore
@main struct Probe {
    static func main() async {
        let runtime = EmbeddedCuaDriver.shared
        do {
            let connection = try await runtime.connection()
            struct Permissions: Decodable, Sendable {
                struct Source: Decodable, Sendable {
                    let attribution: String
                    let embedded: Bool
                    let host_bundle_id: String
                    let responsible_ppid: Int32
                }
                let source: Source
            }
            let permissions = try await DesktopAppConversation().call("check_permissions", [:], as: Permissions.self)
            guard permissions.source.attribution == "host", permissions.source.embedded,
                  permissions.source.host_bundle_id == Bundle.main.bundleIdentifier,
                  permissions.source.responsible_ppid == ProcessInfo.processInfo.processIdentifier else {
                throw CocoaError(.validationMissingMandatoryProperty)
            }
            if CommandLine.arguments.contains("--snapshot-fixture") {
                let snapshot = try await DesktopAppConversation().call("get_window_state", ["session": "fixture-only"],
                    numbers: ["pid": 4242, "window_id": 101], as: DesktopAppSnapshot.self)
                try snapshot.checkReadable()
                guard snapshot.pid == 4242, snapshot.window_id == 101,
                      snapshot.elements.count == 2,
                      snapshot.elements.last?.element_token == "fixture:1",
                      snapshot.elements.last?.value == "Preserved draft" else {
                    throw CocoaError(.validationMissingMandatoryProperty)
                }
                print("PASS: default adapter requested elements and decoded a simulated structured window snapshot through its private runtime.")
            } else {
                print("PASS: default native adapter decoded real host attribution through the bundled private runtime.")
            }
            await runtime.stop()
            guard !FileManager.default.fileExists(atPath: connection.socket.path) else { exit(1) }
            print("PASS: private runtime stopped and socket removed. No permission requests or provider actions performed.")
        } catch { print("FAIL: \(error)"); await runtime.stop(); exit(1) }
    }
}
SWIFT
cat > "$probe/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.msgblast.embedded-runtime-probe</string>
<key>CFBundleExecutable</key><string>probe</string>
<key>CFBundlePackageType</key><string>APPL</string>
</dict></plist>
PLIST
xcrun swiftc -parse-as-library -F "$products" -framework msgblastCore \
    -Xlinker -rpath -Xlinker "$products" "$workspace/Probe.swift" -o "$probe/Contents/MacOS/probe"
codesign --force --sign - "$probe"
"$probe/Contents/MacOS/probe"

# Controlled protocol fixture: no native window or OS access is involved.
cat > "$probe/Contents/Helpers/cua-driver" <<'PYTHON'
#!/usr/bin/env python3
import json, os, socket, sys, time
args = sys.argv[1:]
path = args[args.index('--socket') + 1]
assert '--embedded' in args
if args[0] == 'serve':
    assert '--parent-liveness-stdio' in args
    assert '--no-overlay' in args
    server = socket.socket(socket.AF_UNIX)
    server.bind(path)
    server.listen()
    sys.stdin.buffer.read()
else:
    assert os.path.exists(path)
    owner = os.environ['CUA_DRIVER_HOST_BUNDLE_ID']
    pid = int(os.environ['CUA_DRIVER_EMBEDDED_HOST_PID'])
    if args[1] == 'check_permissions':
        value = {'source': {'attribution': 'host', 'embedded': True,
                 'host_bundle_id': owner, 'responsible_ppid': pid}}
    elif args[1] == 'health_report':
        value = {'checks': [{'name': 'bundle_identity', 'status': 'pass', 'data': {
                 'bundle_identifier': owner, 'identity_source': 'parent_application', 'parent_process_id': pid}}]}
    elif args[1] == 'get_window_state':
        request = json.loads(args[2])
        assert request['tree_format'] == 'elements'
        assert request['pid'] == 4242 and request['window_id'] == 101
        value = {'pid': 4242, 'window_id': 101, 'degraded': False,
                 'element_count': 2, 'total_element_count': 2, 'returned_element_count': 2,
                 'elements': [{'role': 'AXWebArea', 'label': 'Fixture'},
                              {'role': 'AXTextArea', 'label': 'Message', 'value': 'Preserved draft',
                               'element_token': 'fixture:1', 'element_index': 1, 'parent_index': 0}]}
    else:
        raise AssertionError('Unexpected operation: ' + args[1])
    print(json.dumps(value), flush=True)
    time.sleep(.02)
PYTHON
chmod +x "$probe/Contents/Helpers/cua-driver"
codesign --force --sign - "$probe/Contents/Helpers/cua-driver"
codesign --force --sign - "$probe"
"$probe/Contents/MacOS/probe" --snapshot-fixture
