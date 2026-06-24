#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────
#  macMTP — Build Script
#  Compiles the macMTP application for macOS (Intel x86_64).
#  Usage:  ./scripts/build.sh [debug|release]
# ──────────────────────────────────────────────────────────────
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
APP_NAME="macMTP"
BUNDLE_ID="com.macmtp.app"
APP_BUNDLE="$PROJECT_ROOT/$APP_NAME.app"
ARCH=$(uname -m)
[ "$ARCH" = "arm64" ] && GOARCH="arm64" || GOARCH="amd64"

BUILD_MODE="${1:-debug}"
BUILD_UNIVERSAL=false

# Parse options
while [[ $# -gt 0 ]]; do
    case "$1" in
        -u|--universal) BUILD_UNIVERSAL=true; shift ;;
        debug|release) BUILD_MODE="$1"; shift ;;
        *) shift ;;  # Skip unknown
    esac
done

# On Intel Macs we can't build universal binary (libusb is Intel-only).
# On Apple Silicon we can (Rosetta handles x86_64 libusb).
if [ "$BUILD_UNIVERSAL" = true ] && [ "$ARCH" != "arm64" ]; then
    echo "  NOTE: Universal builds require Apple Silicon (libusb not available for arm64 on Intel)."
    echo "  Falling back to single-arch build."
    BUILD_UNIVERSAL=false
fi

echo "════════════════════════════════════════════════"
echo "  macMTP Build Script"
echo "  Mode: $BUILD_MODE | Arch: $ARCH"
echo "════════════════════════════════════════════════"

# ── Step 0: Check Prerequisites ──
echo ""
echo "▸ Checking prerequisites..."

if ! command -v swift &>/dev/null; then
    echo "ERROR: Swift compiler not found. Install Xcode Command Line Tools."
    exit 1
fi

if ! command -v go &>/dev/null; then
    echo "ERROR: Go compiler not found. Install via: brew install go"
    exit 1
fi

if ! command -v codesign &>/dev/null; then
    echo "ERROR: codesign not found. Install Xcode Command Line Tools."
    exit 1
fi

if ! pkg-config --exists libusb-1.0 2>/dev/null; then
    echo "ERROR: libusb-1.0 not found. Install via: brew install libusb"
    exit 1
fi

echo "  Swift: $(swift --version 2>&1 | head -1)"
echo "  Go:    $(go version)"
echo "  Arch:  $ARCH"

# ── Step 1: Compile Go Kalam MTP Library ──
echo ""
echo "▸ [1/5] Compiling Go Kalam MTP engine..."
KALAM_DIR="$PROJECT_ROOT/../openmtp/ffi/kalam/native"
KALAM_OUTPUT="$PROJECT_ROOT/Sources/CKalam"

if [ ! -d "$KALAM_DIR" ]; then
    echo "  WARNING: Kalam source directory not found at $KALAM_DIR"
    echo "  Using existing libkalam.a if available..."
else
    (
        cd "$KALAM_DIR"
        CGO_ENABLED=1 \
        GOARCH="${GOARCH:-amd64}" \
        GOOS=darwin \
        CGO_CFLAGS="-mmacosx-version-min=14.0" \
        CGO_LDFLAGS="-mmacosx-version-min=14.0" \
        go build -tags nosigsegv -buildmode=c-archive \
            -o "$KALAM_OUTPUT/libkalam.a" \
            ./*.go
    )
    cp "$KALAM_DIR/libkalam.h" "$KALAM_OUTPUT/include/kalam.h" 2>/dev/null || true
    echo "  ✓ libkalam.a compiled successfully"
fi

# Verify the static library exists
if [ ! -f "$KALAM_OUTPUT/libkalam.a" ]; then
    echo "ERROR: libkalam.a not found. Cannot build without MTP engine."
    exit 1
fi

# ── Step 2: Build Swift Application ──
echo ""
echo "▸ [2/5] Building Swift application ($BUILD_MODE)..."

cd "$PROJECT_ROOT"

if [ "$BUILD_UNIVERSAL" = true ]; then
    echo "  Building universal binary (x86_64 + arm64)..."
    # Build for arm64 natively
    swift build -c release --triple arm64-apple-macosx 2>&1
    # Build for x86_64 via Rosetta
    swift build -c release --triple x86_64-apple-macosx 2>&1
    # Lipo them together
    mkdir -p "$PROJECT_ROOT/.build/universal"
    lipo -create -output "$PROJECT_ROOT/.build/universal/macmtp" \
        "$PROJECT_ROOT/.build/arm64-apple-macosx/release/macmtp" \
        "$PROJECT_ROOT/.build/x86_64-apple-macosx/release/macmtp"
    SWIFT_BIN="$PROJECT_ROOT/.build/universal/macmtp"
else
    if [ "$BUILD_MODE" = "release" ]; then
        swift build -c release 2>&1
        SWIFT_BIN="$PROJECT_ROOT/.build/release/macmtp"
    else
        swift build 2>&1
        SWIFT_BIN="$PROJECT_ROOT/.build/debug/macmtp"
    fi
fi

if [ ! -f "$SWIFT_BIN" ]; then
    echo "ERROR: Swift build failed. Binary not found at $SWIFT_BIN"
    exit 1
fi

echo "  ✓ Swift build succeeded"

# ── Step 3: Create App Bundle ──
echo ""
echo "▸ [3/5] Creating macOS .app bundle..."

rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

# Copy the binary
cp "$SWIFT_BIN" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"

# Copy libusb dylib alongside the binary
LIBUSB_PATH="$(pkg-config --variable=libdir libusb-1.0)/libusb-1.0.0.dylib"
if [ -f "$LIBUSB_PATH" ]; then
    cp "$LIBUSB_PATH" "$APP_BUNDLE/Contents/MacOS/libusb.dylib"
    # Fix the rpath so the binary finds libusb next to itself
    install_name_tool -change "$LIBUSB_PATH" "@executable_path/libusb.dylib" \
        "$APP_BUNDLE/Contents/MacOS/$APP_NAME" 2>/dev/null || true
    echo "  ✓ Bundled libusb.dylib"
fi

# Write Info.plist
cat > "$APP_BUNDLE/Contents/Info.plist" << 'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>macMTP</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIdentifier</key>
    <string>com.macmtp.app</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>macMTP</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSEnvironment</key>
    <dict>
        <key>GODEBUG</key>
        <string>asyncpreemptoff=1</string>
        <key>GOTRACEBACK</key>
        <string>none</string>
    </dict>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSSupportsAutomaticTermination</key>
    <false/>
    <key>NSSupportsSuddenTermination</key>
    <false/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
    <key>LSUIElement</key>
    <false/>
    <key>NSHumanReadableCopyright</key>
    <string>Copyright © 2024 macMTP Contributors. MIT License.</string>
    <key>com.apple.security.device.usb</key>
    <true/>
</dict>
</plist>
PLIST

# Copy app icon
if [ -f "$PROJECT_ROOT/Resources/AppIcon.icns" ]; then
    cp "$PROJECT_ROOT/Resources/AppIcon.icns" "$APP_BUNDLE/Contents/Resources/"
    echo "  ✓ Bundled AppIcon.icns"
fi

# Write PkgInfo
echo -n "APPL????" > "$APP_BUNDLE/Contents/PkgInfo"

echo "  ✓ App bundle created at $APP_BUNDLE"

# ── Step 4: Ad-hoc Code Sign ──
echo ""
echo "▸ [4/5] Code signing (ad-hoc)..."

# Sign libusb first if bundled
if [ -f "$APP_BUNDLE/Contents/MacOS/libusb.dylib" ]; then
    codesign -s - --force "$APP_BUNDLE/Contents/MacOS/libusb.dylib"
fi

# Sign the main binary
codesign -s - --force --deep "$APP_BUNDLE"
echo "  ✓ Ad-hoc signed"

# ── Step 5: Verify ──
echo ""
echo "▸ [5/5] Verifying build..."
codesign --verify --verbose "$APP_BUNDLE" 2>&1 || true

FILE_SIZE=$(du -sh "$APP_BUNDLE" | cut -f1)
echo ""
echo "════════════════════════════════════════════════"
echo "  ✅ BUILD SUCCESSFUL"
echo "  App:  $APP_BUNDLE"
echo "  Size: $FILE_SIZE"
echo "  Mode: $BUILD_MODE"
echo "════════════════════════════════════════════════"
echo ""
echo "  To run:  open $APP_BUNDLE"
echo ""
