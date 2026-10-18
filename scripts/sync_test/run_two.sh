#!/bin/bash
# Run two Wowser debug instances side by side that sync with each other.
#
# Each instance gets its own throwaway data directory (BrowserState, history,
# autofill, sync state…) and in-memory website data, and they share a local
# folder as the sync transport. Writes to that folder are delayed by a random
# 0..LATENCY seconds (in order), to simulate a slow sync service.
#
#   scripts/sync_test/run_two.sh                 # build, then launch A and B
#   scripts/sync_test/run_two.sh --latency 0     # basically instant
#   scripts/sync_test/run_two.sh --no-build      # reuse the last build
#   scripts/sync_test/run_two.sh --keep          # don't delete the temp dirs on exit
#
# Logs: <work>/A.log, <work>/B.log. Sync folder: <work>/shared.
# Each instance's MCP server: A on 48301, B on 48302 (drive them with BrowserJS).
# Ctrl-C quits both.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
LATENCY=2
BUILD=1
KEEP=0
DERIVED="${WOWSER_SYNC_TEST_DERIVED_DATA:-${TMPDIR:-/tmp}/wowser-sync-test-dd}"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --latency) LATENCY="$2"; shift 2 ;;
        --no-build) BUILD=0; shift ;;
        --keep) KEEP=1; shift ;;
        -h|--help) sed -n '2,17p' "$0"; exit 0 ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

if [[ $BUILD == 1 ]]; then
    echo "Building Wowser (Debug) into ${DERIVED}…"
    xcodebuild -project "$ROOT/Wowser.xcodeproj" -scheme Wowser -configuration Debug \
        -destination 'platform=macOS' -derivedDataPath "$DERIVED" build -quiet
fi

APP="$(find "$DERIVED/Build/Products/Debug" -maxdepth 1 -name '*.app' | head -1)"
if [[ -z "$APP" ]]; then
    echo "No app found in $DERIVED/Build/Products/Debug (run without --no-build)" >&2
    exit 1
fi
EXE="$APP/Contents/MacOS/$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$APP/Contents/Info.plist")"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/wowser-sync-test.XXXXXX")"
mkdir -p "$WORK/A" "$WORK/B" "$WORK/shared"

PIDS=()
cleanup() {
    echo
    echo "Stopping..."
    for pid in "${PIDS[@]}"; do kill "$pid" 2>/dev/null || true; done
    wait 2>/dev/null || true
    if [[ $KEEP == 1 ]]; then
        echo "Kept $WORK"
    else
        rm -rf "$WORK"
    fi
}
trap cleanup EXIT INT TERM

launch() {
    local name="$1" port="$2"
    # `script -F` gives the app a pty so print() isn't block-buffered. Its
    # stdin must stay open (EOF makes script hang up the app).
    env WOWSER_DATA_DIR="$WORK/$name" \
        WOWSER_SYNC_FOLDER="$WORK/shared" \
        WOWSER_SYNC_LATENCY="0-$LATENCY" \
        WOWSER_SYNC_DEVICE_NAME="Test $name" \
        WOWSER_EPHEMERAL_WEBSITE_DATA=1 \
        WOWSER_MCP_PORT="$port" \
        script -q -F "$WORK/$name.log" "$EXE" < <(tail -f /dev/null) >/dev/null 2>&1 &
    PIDS+=($!)
}

launch A 48301
launch B 48302

cat <<EOF
Launched two instances (latency 0–${LATENCY}s):
  A: log $WORK/A.log  MCP :48301
  B: log $WORK/B.log  MCP :48302
  sync folder: $WORK/shared
Sync state and debug info: Settings → General → Sync (in either window).
Ctrl-C to quit both.
EOF

# Poll rather than `wait`: a stray signal can interrupt `wait`, and the EXIT
# trap would then kill both apps. Exit once either app quits.
while kill -0 "${PIDS[0]}" 2>/dev/null && kill -0 "${PIDS[1]}" 2>/dev/null; do
    sleep 1
done
