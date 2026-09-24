#!/bin/bash
set -euo pipefail

APP_NAME="ColimaDock"
BUILD_DIR=".build/release"
APP_BUNDLE="$APP_NAME.app"

ICON_SCRIPT="Scripts/make-icon.swift"
ICON_FILE=".build/AppIcon.icns"

swift build -c release

# The icon is drawn by code; regenerate only when the drawing changes.
if [ ! -f "$ICON_FILE" ] || [ "$ICON_SCRIPT" -nt "$ICON_FILE" ]; then
    swift "$ICON_SCRIPT" "$ICON_FILE"
fi

rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

cp "$BUILD_DIR/$APP_NAME" "$APP_BUNDLE/Contents/MacOS/"
cp "Sources/Info.plist" "$APP_BUNDLE/Contents/"
cp "$ICON_FILE" "$APP_BUNDLE/Contents/Resources/AppIcon.icns"

echo "App bundle created at $APP_BUNDLE"
echo "Run with: open $APP_BUNDLE"
