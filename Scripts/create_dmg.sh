#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="Bitz"
BUNDLE_ID="com.bitz.cybercat"
BUILD_DIR="$ROOT_DIR/build"
APP_BUNDLE="$BUILD_DIR/${APP_NAME}.app"
DMG_PATH="$BUILD_DIR/${APP_NAME}.dmg"
DMG_STAGING="$BUILD_DIR/dmg_staging"

echo "==> Packaging ${APP_NAME}.app for release..."

# Always rebuild a clean release Bitz.app so version Info.plist and SwiftPM resource bundles are never stale
echo "==> Compiling release application..."
/usr/bin/swift build -c release --product "$APP_NAME"
BIN_PATH="$(/usr/bin/swift build -c release --show-bin-path)/${APP_NAME}"
BIN_DIR="$(dirname "$BIN_PATH")"
CONTENTS_DIR="$APP_BUNDLE/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"

rm -rf "$APP_BUNDLE"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"
cp "$BIN_PATH" "$MACOS_DIR/$APP_NAME"
chmod +x "$MACOS_DIR/$APP_NAME"

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

echo "==> Staging disk image layout..."
rm -rf "$DMG_STAGING" "$DMG_PATH"
mkdir -p "$DMG_STAGING"
cp -R "$APP_BUNDLE" "$DMG_STAGING/"
ln -s /Applications "$DMG_STAGING/Applications"

echo "==> Creating compressed disk image: ${DMG_PATH}..."
hdiutil create -volname "${APP_NAME}" -srcfolder "$DMG_STAGING" -ov -format UDZO "$DMG_PATH"
rm -rf "$DMG_STAGING"

echo "=========================================================="
echo "✨ Distribution Disk Image Ready!"
echo "📦 DMG: ${DMG_PATH}"
echo "File size: $(du -h "$DMG_PATH" | cut -f1)"
echo "=========================================================="
