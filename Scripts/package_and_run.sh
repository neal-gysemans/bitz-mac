#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

APP_NAME="Bitz"
BUNDLE_ID="com.bitz.cybercat"
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

cat > "$CONTENTS_DIR/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>${APP_NAME}</string>
    <key>CFBundleIdentifier</key>
    <string>${BUNDLE_ID}</string>
    <key>CFBundleName</key>
    <string>${APP_NAME}</string>
    <key>CFBundleDisplayName</key>
    <string>Bitz the Cyber Cat</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.3.2</string>
    <key>CFBundleVersion</key>
    <string>6</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>BitzLocalDevLicenseToken</key>
    <string>BITZ1.eyJsaWNlbnNlX2lkIjoiQlRaLUxPQ0FMLURFVi1QUk8iLCJ0aWVyIjoicHJvIiwiaXNzdWVkX2F0IjoxNzc1NjAwMDAwLCJwdXJjaGFzZXJfZW1haWwiOiJsb2NhbC1kZXZAYml0ei5hcHAifQ.7O-bo3C8CbTRuI3ZL2iFQ6biivRBy2POB2PZunmOjgQ2zJRu0Abb3dgOlHNkm3APF-g4pbH1xSEjtOaJsHa7DQ</string>
</dict>
</plist>
EOF

codesign --force --deep --sign - "$APP_BUNDLE"

echo "==> Packaged and signed: $APP_BUNDLE"
open "$APP_BUNDLE"
echo "==> Launched ${APP_NAME}.app!"
