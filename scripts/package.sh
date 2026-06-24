#!/bin/bash
set -euo pipefail

PRODUCT_NAME="macMTP"
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$PROJECT_DIR/.build"
APP_BUNDLE="$BUILD_DIR/$PRODUCT_NAME.app"

echo "Building $PRODUCT_NAME..."
swift build -c release --product macmtp

BINARY_PATH="$BUILD_DIR/release/macmtp"

echo "Creating app bundle at $APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

cp "$BINARY_PATH" "$APP_BUNDLE/Contents/MacOS/$PRODUCT_NAME"
cp "$PROJECT_DIR/Resources/Info.plist" "$APP_BUNDLE/Contents/Info.plist"

# Copy app icon if available
if [ -f "$PROJECT_DIR/Resources/AppIcon.icns" ]; then
    cp "$PROJECT_DIR/Resources/AppIcon.icns" "$APP_BUNDLE/Contents/Resources/"
fi

echo "App bundle created at $APP_BUNDLE"
echo "Run with: open $APP_BUNDLE"
