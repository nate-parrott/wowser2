#!/bin/bash
# Xcode "Embed CEF" build phase.
#
# No-ops unless the CEF build flag (Wowser/Core/.cef-enabled) is present, so
# WebKit-only builds pay nothing. When enabled, assembles the pieces a CEF app
# bundle requires (see CefSwift docs/bundling.md):
#   Contents/Frameworks/Chromium Embedded Framework.framework
#   Contents/Frameworks/<App> Helper[ (Alerts|GPU|Plugin|Renderer)].app  x5
# Helper names are load-bearing: CEF derives them from the main executable
# name. All five helpers contain the same cef-helper binary, renamed.
# Signing is inside-out (framework -> helpers); Xcode signs the main app after
# this phase runs.
#
# Requires scripts/cef/setup.sh to have been run once (downloads CEF, builds
# cef-helper).
set -euo pipefail

CORE="$SRCROOT/Wowser/Core"

if [ ! -f "$CORE/.cef-enabled" ]; then
    echo "CEF disabled (no Core/.cef-enabled) — skipping embed."
    exit 0
fi

FRAMEWORK_SRC="$(/bin/ls -d "$CORE/.cef/dist/"*/Release/"Chromium Embedded Framework.framework" 2>/dev/null | head -1 || true)"
HELPER_BIN="$CORE/.build/release/cef-helper"

if [ -z "$FRAMEWORK_SRC" ] || [ ! -f "$HELPER_BIN" ]; then
    echo "error: CEF is enabled but artifacts are missing. Run scripts/cef/setup.sh first." >&2
    echo "  expected framework under: $CORE/.cef/dist/*/Release/" >&2
    echo "  expected helper binary:   $HELPER_BIN" >&2
    exit 1
fi

APP_CONTENTS="$BUILT_PRODUCTS_DIR/$CONTENTS_FOLDER_PATH"
FRAMEWORKS_DIR="$BUILT_PRODUCTS_DIR/$FRAMEWORKS_FOLDER_PATH"
EXEC="$EXECUTABLE_NAME"
BUNDLE_ID="$PRODUCT_BUNDLE_IDENTIFIER"
IDENTITY="${EXPANDED_CODE_SIGN_IDENTITY:--}"
if [ -z "$IDENTITY" ]; then IDENTITY="-"; fi

mkdir -p "$FRAMEWORKS_DIR"

echo "==> Embedding Chromium Embedded Framework"
rsync -a --delete "$FRAMEWORK_SRC" "$FRAMEWORKS_DIR/"

make_helper() {
    local suffix="$1"        # "" or e.g. " (GPU)"
    local id_suffix="$2"     # e.g. ".helper.gpu"
    local name="$EXEC Helper$suffix"
    local app="$FRAMEWORKS_DIR/$name.app"
    local contents="$app/Contents"

    mkdir -p "$contents/MacOS"
    cp -f "$HELPER_BIN" "$contents/MacOS/$name"
    printf 'APPL????' > "$contents/PkgInfo"
    cat > "$contents/Info.plist" << PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key><string>en</string>
	<key>CFBundleExecutable</key><string>$name</string>
	<key>CFBundleIdentifier</key><string>$BUNDLE_ID$id_suffix</string>
	<key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
	<key>CFBundleName</key><string>$name</string>
	<key>CFBundleDisplayName</key><string>$name</string>
	<key>CFBundlePackageType</key><string>APPL</string>
	<key>CFBundleShortVersionString</key><string>1.0</string>
	<key>CFBundleVersion</key><string>1</string>
	<key>LSMinimumSystemVersion</key><string>14.0</string>
	<key>LSUIElement</key><true/>
	<key>LSFileQuarantineEnabled</key><true/>
	<key>NSSupportsAutomaticGraphicsSwitching</key><true/>
</dict>
</plist>
PLIST
    echo "$app"
}

echo "==> Assembling helper apps"
HELPER_APPS=()
HELPER_APPS+=("$(make_helper ""            ".helper")")
HELPER_APPS+=("$(make_helper " (Alerts)"   ".helper.alerts")")
HELPER_APPS+=("$(make_helper " (GPU)"      ".helper.gpu")")
HELPER_APPS+=("$(make_helper " (Plugin)"   ".helper.plugin")")
HELPER_APPS+=("$(make_helper " (Renderer)" ".helper.renderer")")

echo "==> Codesigning (inside-out, identity: $IDENTITY)"
codesign --force --sign "$IDENTITY" "$FRAMEWORKS_DIR/Chromium Embedded Framework.framework"
for app in "${HELPER_APPS[@]}"; do
    codesign --force --sign "$IDENTITY" "$app"
done

echo "==> CEF embedded into $APP_CONTENTS"
