#!/bin/bash
# One-time setup for CEF (Chromium engine) builds.
#
# Run this after enabling the CEF build flag (`touch Wowser/Core/.cef-enabled`).
# It uses the CefSwift package's plugin to download the pinned CEF distribution
# (cached in Wowser/Core/.cef/, ~120MB download) and builds the cef-helper
# subprocess binary. The Xcode build phase (embed.sh) then assembles these into
# the app bundle on every build.
#
# Re-run only when CefSwift's pinned CEF version changes.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CORE="$ROOT/Wowser/Core"

if [ ! -f "$CORE/.cef-enabled" ]; then
    echo "error: CEF is not enabled. Run: touch Wowser/Core/.cef-enabled" >&2
    exit 1
fi

echo "==> Downloading pinned CEF distribution (cached in Core/.cef/)..."
cd "$CORE"
swift package --allow-writing-to-package-directory --allow-network-connections all cef download

echo "==> Building cef-helper (release)..."
swift build --product cef-helper -c release

echo "==> Done. CEF artifacts staged:"
ls -d "$CORE/.cef/dist/"*/Release/"Chromium Embedded Framework.framework"
ls "$CORE/.build/release/cef-helper"
echo "Xcode builds will now embed CEF automatically (scripts/cef/embed.sh)."
