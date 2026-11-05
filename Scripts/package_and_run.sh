#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

APP_NAME="Bitz"
# Local builds use their own bundle ID so their TCC grants (mic, screen audio, speech) and UserDefaults stay
# separate from the installed release, and macOS "Quit & Reopen" relaunches this copy, not /Applications/Bitz.app.
# Override with BITZ_BUNDLE_ID=com.bitz.cybercat to test against the release identity.
BUNDLE_ID="${BITZ_BUNDLE_ID:-com.bitz.cybercat.dev}"
APP_BUNDLE="$ROOT_DIR/build/${APP_NAME}.app"
CONTENTS_DIR="$APP_BUNDLE/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
BUILD_CONFIG="${1:-release}"

if [[ -z "${SDKROOT:-}" && -d "/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk" ]]; then
    # Fallback if default SDK is 27.x seed lacking standalone SwiftUI macro binaries
    CURRENT_SDK="$(readlink -f "$(xcrun --show-sdk-path 2>/dev/null || echo "")" 2>/dev/null || echo "")"
    if [[ "$CURRENT_SDK" == *"MacOSX27"* ]]; then
        export SDKROOT="/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk"
    fi
fi

echo "==> Building ${APP_NAME} (${BUILD_CONFIG}) with Xcode Swift toolchain..."
/usr/bin/swift build -c "$BUILD_CONFIG" --product "$APP_NAME"
BIN_PATH="$(/usr/bin/swift build -c "$BUILD_CONFIG" --show-bin-path)/${APP_NAME}"

pkill -x "$APP_NAME" 2>/dev/null || true

rm -rf "$APP_BUNDLE"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"
cp "$BIN_PATH" "$MACOS_DIR/$APP_NAME"
chmod +x "$MACOS_DIR/$APP_NAME"

BIN_DIR="$(dirname "$BIN_PATH")"
if compgen -G "$BIN_DIR"/*.bundle > /dev/null; then
    cp -R "$BIN_DIR"/*.bundle "$RESOURCES_DIR/"
fi

if [[ -f "$ROOT_DIR/Resources/AppIcon.icns" ]]; then
    cp "$ROOT_DIR/Resources/AppIcon.icns" "$RESOURCES_DIR/AppIcon.icns"
fi

if [[ -d "$ROOT_DIR/Resources/Sounds" ]]; then
    mkdir -p "$RESOURCES_DIR/Sounds"
    cp -R "$ROOT_DIR/Resources/Sounds/"* "$RESOURCES_DIR/Sounds/"
fi

"$ROOT_DIR/Scripts/render_info_plist.sh" "$APP_NAME" "$BUNDLE_ID" "$CONTENTS_DIR/Info.plist"

# Hardened runtime (no --deep: the bundle has no nested code); entitlements grant mic and Apple Events access
codesign --force --options runtime --entitlements "$ROOT_DIR/Scripts/Bitz.entitlements" --sign - "$APP_BUNDLE"
codesign --verify --strict "$APP_BUNDLE"

echo "==> Packaged and signed: $APP_BUNDLE"
open "$APP_BUNDLE"
echo "==> Launched ${APP_NAME}.app!"
