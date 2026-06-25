#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────
#  macMTP — Release Packaging Script
#  Creates DMG installer and ZIP archive for distribution.
#  Usage:  ./scripts/release.sh [version]
#  Example: ./scripts/release.sh 1.0.0
# ──────────────────────────────────────────────────────────────
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
APP_NAME="macMTP"
VERSION="${1:-1.0.0}"
RELEASE_DIR="$PROJECT_ROOT/release"
APP_BUNDLE="$PROJECT_ROOT/$APP_NAME.app"
ARCH="universal"
BUILD_ARGS="--universal"

# Parse options
while [[ $# -gt 0 ]]; do
    case "$1" in
        -u|--universal) BUILD_ARGS="--universal"; ARCH="universal"; shift ;;
        *) 
            if [[ "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
                VERSION="$1"
            fi
            shift 
            ;;
    esac
done

echo "════════════════════════════════════════════════"
echo "  macMTP Release Packaging"
echo "  Version: $VERSION | Arch: $ARCH"
echo "════════════════════════════════════════════════"

# ── Step 1: Build Release ──
echo ""
echo "▸ [1/4] Building release binary..."
bash "$SCRIPT_DIR/build.sh" release $BUILD_ARGS

if [ ! -d "$APP_BUNDLE" ]; then
    echo "ERROR: App bundle not found at $APP_BUNDLE"
    exit 1
fi

# ── Step 2: Update Version in Info.plist ──
echo ""
echo "▸ [2/4] Setting version to $VERSION..."
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP_BUNDLE/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $VERSION" "$APP_BUNDLE/Contents/Info.plist"

# Re-sign after plist modification
codesign -s - --force --deep "$APP_BUNDLE"

echo "  ✓ Version set to $VERSION"

# ── Step 3: Create Release Directory ──
echo ""
echo "▸ [3/4] Creating release artifacts..."

rm -rf "$RELEASE_DIR"
mkdir -p "$RELEASE_DIR"

DMG_NAME="$APP_NAME-$VERSION-mac-$ARCH.dmg"
ZIP_NAME="$APP_NAME-$VERSION-mac-$ARCH.zip"

# Create ZIP archive
echo "  Creating ZIP archive..."
cd "$PROJECT_ROOT"
ditto -c -k --sequesterRsrc --keepParent "$APP_BUNDLE" "$RELEASE_DIR/$ZIP_NAME"
echo "  ✓ $ZIP_NAME created"

# Create DMG using create-dmg
echo "  Creating DMG installer..."

cd "$RELEASE_DIR"
if command -v create-dmg &> /dev/null; then
    create-dmg "$APP_BUNDLE" || true
else
    npx create-dmg "$APP_BUNDLE" || true
fi

# The resulting DMG is usually named something like macMTP 1.0.0.dmg in the release folder
# Let's rename it to our expected DMG_NAME
mv "$RELEASE_DIR"/*.dmg "$RELEASE_DIR/$DMG_NAME" 2>/dev/null || true

echo "  ✓ $DMG_NAME created"

# ── Step 4: Generate Checksums ──
echo ""
echo "▸ [4/4] Generating checksums..."

cd "$RELEASE_DIR"
shasum -a 256 "$DMG_NAME" > "$DMG_NAME.sha256"
shasum -a 256 "$ZIP_NAME" > "$ZIP_NAME.sha256"

# Generate a release info YAML (similar to OpenMTP's latest-mac.yml)
cat > "$RELEASE_DIR/latest-mac.yml" << YAML
version: $VERSION
files:
  - url: $ZIP_NAME
    sha256: $(shasum -a 256 "$ZIP_NAME" | awk '{print $1}')
    size: $(stat -f%z "$ZIP_NAME")
  - url: $DMG_NAME
    sha256: $(shasum -a 256 "$DMG_NAME" | awk '{print $1}')
    size: $(stat -f%z "$DMG_NAME")
path: $ZIP_NAME
releaseDate: '$(date -u +"%Y-%m-%dT%H:%M:%S.000Z")'
YAML

echo "  ✓ Checksums and release info generated"

# Summary
echo ""
echo "════════════════════════════════════════════════"
echo "  ✅ RELEASE PACKAGING COMPLETE"
echo ""
echo "  Release Directory: $RELEASE_DIR/"
echo "  ┣ $DMG_NAME"
echo "  ┣ $DMG_NAME.sha256"
echo "  ┣ $ZIP_NAME"
echo "  ┣ $ZIP_NAME.sha256"
echo "  ┗ latest-mac.yml"
echo ""
DMG_SIZE=$(du -sh "$RELEASE_DIR/$DMG_NAME" | cut -f1)
ZIP_SIZE=$(du -sh "$RELEASE_DIR/$ZIP_NAME" | cut -f1)
echo "  DMG: $DMG_SIZE | ZIP: $ZIP_SIZE"
echo "════════════════════════════════════════════════"
