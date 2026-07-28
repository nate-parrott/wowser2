#!/bin/bash
# Toggle the CEF (Chromium engine) build flag and re-resolve packages so Xcode
# picks up the changed dependency graph. Usage: scripts/cef/toggle.sh [on|off]
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
MARKER="$ROOT/Wowser/Core/.cef-enabled"

case "${1:-}" in
    on)  touch "$MARKER" ;;
    off) rm -f "$MARKER" ;;
    *)
        if [ -f "$MARKER" ]; then echo "CEF is ON ($MARKER exists)"; else echo "CEF is OFF"; fi
        echo "usage: $0 on|off"
        exit 0
        ;;
esac

echo "==> Re-resolving packages (required after toggling)..."
xcodebuild -project "$ROOT/Wowser.xcodeproj" -resolvePackageDependencies > /dev/null
echo "==> CEF is now ${1}."
if [ "${1}" = "on" ] && [ ! -d "$ROOT/Wowser/Core/.cef/dist" ]; then
    echo "note: CEF artifacts not staged yet — run scripts/cef/setup.sh once."
fi
