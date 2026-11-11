#!/bin/bash
# Serves the Demo profile (simulated agents, Messages and replies; no real sends) on this
# Mac's Tailscale or LAN address for phone UX work, and prints a pairing link.
# Usage: bash scripts/run_demo_mac.sh build/<derived-data> [seconds]   (Ctrl-C to stop)
set -euo pipefail
root="$(cd -- "$(dirname -- "$0")/.." && pwd)"
build="$(cd -- "${1:?derived data directory}" && pwd)"
seconds="${2:-1800}"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/msgblast-demo-mac.XXXXXX")"
server_pid=""
cleanup() { touch "$tmp/done"; [ -n "$server_pid" ] && wait "$server_pid" 2>/dev/null || true; rm -rf "$tmp"; }
trap cleanup EXIT INT TERM
source "$root/scripts/remote_fixture_lib.sh"
build_remote_fixture_model
MSGBLAST_REMOTE_OFFER_FILE="$tmp/offer.txt" MSGBLAST_REMOTE_DONE_FILE="$tmp/done" MSGBLAST_REMOTE_ALLOW_MESSAGES=1 \
    MSGBLAST_REMOTE_LISTEN_SECONDS="$seconds" MSGBLAST_REMOTE_EVIDENCE_DIR="${MSGBLAST_REMOTE_EVIDENCE_DIR:-}" \
    "$tmp/model" --demo --isolated-demo --remote-listen-fixture &
server_pid=$!
for _ in $(seq 1 300); do [ -s "$tmp/offer.txt" ] && break; sleep 0.1; done
[ -s "$tmp/offer.txt" ] || { echo "The Demo Mac did not publish a pairing link"; exit 1; }
echo "Pairing link (one use; refreshed until a phone pairs): $tmp/offer.txt"
cat "$tmp/offer.txt"; echo
# Keep an external copy current for tooling (for example the simulator launch below).
if [ -n "${MSGBLAST_PAIRING_LINK_FILE:-}" ]; then
    ( while kill -0 "$server_pid" 2>/dev/null; do cp "$tmp/offer.txt" "$MSGBLAST_PAIRING_LINK_FILE" 2>/dev/null || true; sleep 2; done ) &
fi
wait "$server_pid"; server_pid=""
