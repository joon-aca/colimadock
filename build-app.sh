#!/bin/bash
# Builds ColimaDock.app.
#   UNIVERSAL=1  build arm64 + x86_64 (release builds); default is this Mac's arch only
#   VERSION=x.y.z stamp the bundle version (release builds); default keeps Info.plist's
set -euo pipefail

APP_NAME="ColimaDock"
APP_BUNDLE="$APP_NAME.app"

ICON_SCRIPT="Scripts/make-icon.swift"
ICON_FILE=".build/AppIcon.icns"

if [ "${UNIVERSAL:-0}" = "1" ]; then
    swift build -c release --arch arm64 --arch x86_64
    BUILD_DIR=".build/apple/Products/Release"
else
    swift build -c release
    BUILD_DIR=".build/release"
fi

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

# The git tag is the version's source of truth; the build number is the commit count.
if [ -n "${VERSION:-}" ]; then
    PLIST="$APP_BUNDLE/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$PLIST"
    /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $(git rev-list --count HEAD)" "$PLIST"
fi

echo "App bundle created at $APP_BUNDLE ($(lipo -archs "$APP_BUNDLE/Contents/MacOS/$APP_NAME"))"
echo "Run with: open $APP_BUNDLE"
