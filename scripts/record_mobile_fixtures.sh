#!/bin/bash
# Records phone reducer fixtures from the Demo profile through scripts/remote_client.
# The Demo profile listens on this Mac's Tailscale or LAN address for this run only;
# Messages, agents and replies are simulated, lock is simulated, nothing real is sent.
# Usage: bash scripts/record_mobile_fixtures.sh build/<derived-data> [output-dir]
set -euo pipefail
root="$(cd -- "$(dirname -- "$0")/.." && pwd)"
build="$(cd -- "${1:?derived data directory}" && pwd)"
out="${2:-$root/msgblastMobileTests/Fixtures}"
mkdir -p "$out"
out="$(cd -- "$out" && pwd)"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/msgblast-mobile-fixtures.XXXXXX")"
server_pid=""; watch_pid=""
cleanup() { touch "$tmp/done"; [ -n "$watch_pid" ] && kill "$watch_pid" 2>/dev/null || true; [ -n "$server_pid" ] && wait "$server_pid" 2>/dev/null || true; rm -rf "$tmp"; }
trap cleanup EXIT
source "$root/scripts/remote_fixture_lib.sh"
build_remote_fixture_model
(cd "$root/scripts/remote_client" && swift build -c debug >/dev/null)
bin="$root/scripts/remote_client/.build/debug/msgblast-remote"
client() { "$bin" "$@" --state "$tmp/state.json"; }

MSGBLAST_REMOTE_OFFER_FILE="$tmp/offer.txt" MSGBLAST_REMOTE_DONE_FILE="$tmp/done" MSGBLAST_REMOTE_ALLOW_MESSAGES=1 \
    MSGBLAST_REMOTE_LOCK_FILE="$tmp/lock" MSGBLAST_REMOTE_UNLOCK_FILE="$tmp/unlock" MSGBLAST_REMOTE_REPLACE_FILE="$tmp/replace" \
    "$tmp/model" --demo --isolated-demo --remote-listen-fixture &
server_pid=$!
for _ in $(seq 1 300); do [ -s "$tmp/offer.txt" ] && break; sleep 0.1; done
[ -s "$tmp/offer.txt" ] || { echo "The Demo Mac did not publish a pairing link"; exit 1; }
rm -f "$out"/*.jsonl

# 1. Pairing and the first snapshot.
client pair "$(cat "$tmp/offer.txt")" --name "Fixture phone" --once --record "$out/snapshot.jsonl" > /dev/null
agent="$(python3 - "$out/snapshot.jsonl" <<'PY'
import json, sys
for line in open(sys.argv[1]):
    event = json.loads(line)
    if event["kind"] == "snapshot":
        print(next(a["agentID"] for a in event["snapshot"]["agents"] if a["agentID"].startswith("messages:")))
        break
PY
)"
# 2. A send and the events that follow it in the same session (conversation, attempt, simulated reply).
client send --to "$agent" "Fixture question from the phone" --linger 4 --record "$out/send.jsonl" > /dev/null
# 3. Resume from the saved cursor after another change made in a separate session.
client send --to "$agent" "Second fixture question" --linger 3 > /dev/null
python3 - "$tmp/state.json" <<'PY'
import json, sys
state = json.load(open(sys.argv[1])); state["sinceSeq"] = state["sinceSeq"] - 3; json.dump(state, open(sys.argv[1], "w"))
PY
client watch --once --record "$out/resume.jsonl" > /dev/null
# 4. Simulated lock, then unlock, in one watching session.
"$bin" watch --record "$out/locked.jsonl" --state "$tmp/state.json" > /dev/null &
watch_pid=$!
sleep 1.5; touch "$tmp/lock"; sleep 1.5; touch "$tmp/unlock"; sleep 2
kill "$watch_pid" 2>/dev/null || true; wait "$watch_pid" 2>/dev/null || true; watch_pid=""
# 5. Another phone replaces this one; this phone's next connection is refused.
touch "$tmp/replace"
for _ in $(seq 1 50); do [ -s "$tmp/replace.offer" ] && break; sleep 0.1; done
"$bin" pair "$(cat "$tmp/replace.offer")" --name "Replacement phone" --once --state "$tmp/other.json" > /dev/null
client watch --once --record "$out/replaced.jsonl" > /dev/null || true
touch "$tmp/done"; wait "$server_pid"; server_pid=""
# Fixtures are committed: replace this Mac's name with a neutral one.
python3 - "$out" <<'PY'
import json, pathlib, socket, sys, subprocess
name = subprocess.run(["scutil", "--get", "ComputerName"], capture_output=True, text=True).stdout.strip()
for path in pathlib.Path(sys.argv[1]).glob("*.jsonl"):
    text = path.read_text()
    if name: text = text.replace(json.dumps(name)[1:-1], "Demo Mac")
    path.write_text(text)
PY
wc -l "$out"/*.jsonl
echo "Recorded Demo-profile fixtures in $out (simulated Messages, simulated lock)."
