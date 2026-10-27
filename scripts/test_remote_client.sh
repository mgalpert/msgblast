#!/bin/bash
# End-to-end remote control over a real TLS socket: the Demo profile (simulated
# agents and Messages, no real sends) listens on this Mac's Tailscale or LAN address
# for this run only; scripts/remote_client pairs, reads the snapshot, and sends.
# Usage: bash scripts/test_remote_client.sh build/<derived-data> [evidence-dir]
set -euo pipefail
root="$(cd -- "$(dirname -- "$0")/.." && pwd)"
build="$(cd -- "${1:?derived data directory}" && pwd)"
evidence="${2:-}"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/msgblast-remote-client.XXXXXX")"
server_pid=""
cleanup() { touch "$tmp/done"; [ -n "$server_pid" ] && wait "$server_pid" 2>/dev/null || true; rm -rf "$tmp"; }
trap cleanup EXIT
source "$root/scripts/remote_fixture_lib.sh"
build_remote_fixture_model
(cd "$root/scripts/remote_client" && swift build -c debug >/dev/null)
real_client="$root/scripts/remote_client/.build/debug/msgblast-remote"
# Keep harness state in the temporary folder, never the user's default client state.
client() { "$real_client" "$@" --state "${STATE:-$tmp/state.json}"; }

MSGBLAST_REMOTE_OFFER_FILE="$tmp/offer.txt" MSGBLAST_REMOTE_DONE_FILE="$tmp/done" MSGBLAST_REMOTE_ALLOW_MESSAGES=1 \
    MSGBLAST_REMOTE_EVIDENCE_DIR="$evidence" "$tmp/model" --demo --isolated-demo --remote-listen-fixture &
server_pid=$!
for _ in $(seq 1 200); do [ -s "$tmp/offer.txt" ] && break; sleep 0.1; done
[ -s "$tmp/offer.txt" ] || { echo "The Demo Mac did not publish a pairing link"; exit 1; }
cd "$tmp"
log() { echo "\$ msgblast-remote $*" | tee -a "$tmp/session.txt"; }

log pair '<link>' --name "Remote client harness" --once
client pair "$(cat offer.txt)" --name "Remote client harness" --once | tee -a session.txt
grep -q "Paired with" session.txt
grep -q "Snapshot seq" session.txt

log pair '<same link again>' --once
if STATE="$tmp/second.json" client pair "$(cat offer.txt)" --once > reuse.txt 2>&1; then echo "A used code paired twice"; exit 1; fi
cat reuse.txt | tee -a session.txt
grep -q "pairingClosed" reuse.txt

agent="$(grep -o "messages:[0-9A-F-]*" session.txt | head -1)"
log send --to "$agent" "Hello from the remote client"
client send --to "$agent" "Hello from the remote client" | tee -a session.txt
grep -q "applied" session.txt

log keep-awake on
client keep-awake on | tee -a session.txt

log send --to nobody "Should be refused"
if client send --to nobody "Should be refused" > refused.txt; then echo "Unknown agent was accepted"; exit 1; fi
cat refused.txt | tee -a session.txt
grep -q "unknownAgent" refused.txt

log watch --once
client watch --once | tee -a session.txt
touch done
wait "$server_pid"; server_pid=""
[ -n "$evidence" ] && cp session.txt "$evidence/remote-client-session.txt"
echo "PASS: the remote client paired over TLS with a pinned key, refused a reused code, read the snapshot, sent to a simulated Messages agent, set keep-awake, was refused for an unknown agent, and resumed. Demo profile; simulated Messages; port open for this run only."
