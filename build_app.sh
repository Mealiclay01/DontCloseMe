#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$ROOT_DIR/build"
APP_NAME="DontCloseMe"
APP_BUNDLE="$BUILD_DIR/${APP_NAME}.app"
CONTENTS_DIR="$APP_BUNDLE/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
ICONSET_DIR="$BUILD_DIR/AppIcon.iconset"

echo "1) Building release binary via Swift Package Manager..."
cd "$ROOT_DIR"
swift build -c release

BIN_PATH="$(swift build -c release --show-bin-path)/${APP_NAME}"
if [ ! -f "$BIN_PATH" ]; then
  echo "Error: Binary not found at $BIN_PATH"
  exit 1
fi

echo "2) Creating .app bundle structure..."
rm -rf "$APP_BUNDLE" "$ICONSET_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"

cp "$BIN_PATH" "$MACOS_DIR/${APP_NAME}"
chmod +x "$MACOS_DIR/${APP_NAME}"
cp "$ROOT_DIR/Packaging/Info.plist" "$CONTENTS_DIR/Info.plist"
cp "$ROOT_DIR/Sources/DontCloseMe/Resources/clamshell_watchdog.sh" "$RESOURCES_DIR/clamshell_watchdog.sh"
cp "$ROOT_DIR/Sources/DontCloseMe/Resources/launch_watchdog.sh" "$RESOURCES_DIR/launch_watchdog.sh"
chmod +x "$RESOURCES_DIR/clamshell_watchdog.sh" "$RESOURCES_DIR/launch_watchdog.sh"

# Copy SwiftPM resource bundle if generated
SPM_BUNDLE_DIR="$(swift build -c release --show-bin-path)/DontCloseMe_DontCloseMe.bundle"
if [ -d "$SPM_BUNDLE_DIR" ]; then
  cp -R "$SPM_BUNDLE_DIR" "$RESOURCES_DIR/"
fi

echo "3) Generating AppIcon.icns..."
swift "$ROOT_DIR/Packaging/generate_icon.swift" "$ICONSET_DIR"
iconutil -c icns "$ICONSET_DIR" -o "$RESOURCES_DIR/AppIcon.icns"
rm -rf "$ICONSET_DIR"

echo "4) Ad-hoc signing ${APP_NAME}.app..."
codesign --force --deep --sign - "$APP_BUNDLE"

echo "✅ Built real macOS app: $APP_BUNDLE"
