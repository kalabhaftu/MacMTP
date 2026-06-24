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
ARCH=$(uname -m)
BUILD_ARGS=""

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

# Create DMG
echo "  Creating DMG installer..."
DMG_TEMP="$RELEASE_DIR/dmg_staging"
DMG_RW="$RELEASE_DIR/$APP_NAME-$VERSION-mac-$ARCH.rw.dmg"
VOLNAME="$APP_NAME $VERSION"

# Detach any stale mounts
hdiutil detach "/Volumes/$VOLNAME" 2>/dev/null || true

mkdir -p "$DMG_TEMP"
cp -R "$APP_BUNDLE" "$DMG_TEMP/"

# Create a symbolic link to /Applications for easy drag-to-install
ln -s /Applications "$DMG_TEMP/Applications"

# Generate white background image
python3 -c "
import struct, zlib
def png(w,h):
    def c(t,d):
        x=t+d
        return struct.pack('>I',len(d))+x+struct.pack('>I',zlib.crc32(x)&0xffffffff)
    hdr=struct.pack('>IIBBBBB',w,h,8,6,0,0,0)
    raw=b''
    for y in range(h):
        raw+=b'\\x00'+b'\\xff\\xff\\xff\\xff'*w
    return b'\\x89PNG\\r\\n\\x1a\\n'+c(b'IHDR',hdr)+c(b'IDAT',zlib.compress(raw))+c(b'IEND',b'')
with open('$DMG_TEMP/.background.png','wb') as f:
    f.write(png(660,440))
"

# Create read-write DMG
hdiutil create -volname "$VOLNAME" -srcfolder "$DMG_TEMP" -ov -format UDRW "$DMG_RW"

# Mount
DEVICE=$(hdiutil attach -readwrite -noverify "$DMG_RW" | tail -1 | awk '{print $1}')
sleep 2

VOLUME_PATH="/Volumes/$VOLNAME"
mkdir "$VOLUME_PATH/.background" 2>/dev/null
mv "$VOLUME_PATH/.background.png" "$VOLUME_PATH/.background/background.png" 2>/dev/null

# Customize volume appearance (only works in GUI session)
SetFile -a V "$VOLUME_PATH/.background" 2>/dev/null || true

if pgrep -q Finder; then
    open "$VOLUME_PATH"
    sleep 3
    osascript -e "
tell application \"Finder\"
    try
        set theWin to (first window whose name = \"$VOLNAME\")
        if theWin is not missing value then
            set current view of theWin to icon view
            set toolbar visible of theWin to false
            set statusbar visible of theWin to false
            set bounds of theWin to {200, 150, 860, 590}
            set opts to icon view options of theWin
            set icon size of opts to 96
            set arrangement of opts to not arranged
            set background picture of opts to file \".background:background.png\"
            set position of item \"$APP_NAME\" of theWin to {140, 270}
            set position of item \"Applications\" of theWin to {520, 270}
        end if
    end try
end tell
" 2>/dev/null && echo "  ✓ Finder view customized" || echo "  (Finder customization skipped — non-interactive session)"
fi

sleep 2

hdiutil detach "$DEVICE"
hdiutil convert "$DMG_RW" -format UDZO -imagekey zlib-level=9 -o "$RELEASE_DIR/$DMG_NAME"

rm -rf "$DMG_TEMP" "$DMG_RW"
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
