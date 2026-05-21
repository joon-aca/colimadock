#!/bin/bash
set -euo pipefail

APP_NAME="ColimaDock"
BUILD_DIR=".build/release"
APP_BUNDLE="$APP_NAME.app"

swift build -c release

rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

cp "$BUILD_DIR/$APP_NAME" "$APP_BUNDLE/Contents/MacOS/"
cp "Sources/Info.plist" "$APP_BUNDLE/Contents/"

echo "App bundle created at $APP_BUNDLE"
echo "Run with: open $APP_BUNDLE"
