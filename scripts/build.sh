#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
APP_NAME="macMTP"
APP_BUNDLE="$PROJECT_ROOT/$APP_NAME.app"
APP_DSYM="$PROJECT_ROOT/$APP_NAME.app.dSYM"
BUILD_MODE="debug"
BUILD_UNIVERSAL=false
TARGET_ARCH="$(uname -m)"

usage() {
    cat <<EOF
Usage: scripts/build.sh [debug|release] [--arch arm64|x86_64] [--universal]
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        debug|release)
            BUILD_MODE="$1"
            shift
            ;;
        --arch)
            TARGET_ARCH="${2:?missing value for --arch}"
            shift 2
            ;;
        -u|--universal)
            BUILD_UNIVERSAL=true
            TARGET_ARCH="universal"
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "ERROR: Unknown argument: $1"
            usage
            exit 1
            ;;
    esac
done

if [[ "$TARGET_ARCH" != "arm64" && "$TARGET_ARCH" != "x86_64" && "$TARGET_ARCH" != "universal" ]]; then
    echo "ERROR: Unsupported architecture: $TARGET_ARCH"
    exit 1
fi

echo "========================================"
echo "  macMTP Build"
echo "  Mode: $BUILD_MODE"
echo "  Target: $TARGET_ARCH"
echo "========================================"

for tool in swift go codesign pkg-config xcrun; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "ERROR: Required tool '$tool' was not found."
        exit 1
    fi
done

go_arch_for() {
    case "$1" in
        arm64) echo "arm64" ;;
        x86_64) echo "amd64" ;;
        *) echo "ERROR: unsupported Go arch $1" >&2; exit 1 ;;
    esac
}

triple_for() {
    case "$1" in
        arm64) echo "arm64-apple-macosx" ;;
        x86_64) echo "x86_64-apple-macosx" ;;
        *) echo "ERROR: unsupported Swift arch $1" >&2; exit 1 ;;
    esac
}

libusb_pc_dir_for() {
    local arch="$1"
    local candidates=()

    if [[ "$arch" == "arm64" ]]; then
        candidates+=(
            "${MACMTP_ARM64_LIBUSB_PKGCONFIG:-}"
            "/opt/homebrew/opt/libusb/lib/pkgconfig"
            "/opt/homebrew/lib/pkgconfig"
        )
    else
        candidates+=(
            "${MACMTP_X86_64_LIBUSB_PKGCONFIG:-}"
            "/usr/local/opt/libusb/lib/pkgconfig"
            "/usr/local/lib/pkgconfig"
        )
    fi

    for candidate in "${candidates[@]}"; do
        if [[ -n "$candidate" && -f "$candidate/libusb-1.0.pc" ]]; then
            echo "$candidate"
            return 0
        fi
    done

    if pkg-config --exists libusb-1.0 2>/dev/null; then
        pkg-config --variable=pcfiledir libusb-1.0
        return 0
    fi

    echo "ERROR: libusb pkg-config file not found for $arch." >&2
    echo "Install libusb for that architecture or set MACMTP_${arch}_LIBUSB_PKGCONFIG." >&2
    exit 1
}

libusb_lib_dir_for() {
    local pc_dir="$1"
    PKG_CONFIG_PATH="$pc_dir" pkg-config --variable=libdir libusb-1.0
}

libusb_dylib_for() {
    local lib_dir="$1"
    for dylib in "$lib_dir/libusb-1.0.0.dylib" "$lib_dir/libusb-1.0.dylib"; do
        if [[ -f "$dylib" ]]; then
            echo "$dylib"
            return 0
        fi
    done
    echo "ERROR: libusb dylib not found in $lib_dir" >&2
    exit 1
}

validate_dylib_arch() {
    local dylib="$1"
    local arch="$2"
    if ! lipo -archs "$dylib" | tr ' ' '\n' | grep -qx "$arch"; then
        echo "ERROR: $dylib does not contain $arch. Found: $(lipo -archs "$dylib")"
        exit 1
    fi
}

KALAM_DIR="$PROJECT_ROOT/../openmtp/ffi/kalam/native"
KALAM_OUTPUT="$PROJECT_ROOT/Sources/CKalam"
if [[ ! -d "$KALAM_DIR" ]]; then
    echo "ERROR: Kalam source directory not found at $KALAM_DIR"
    echo "CI must checkout ganeshrvel/openmtp next to this repository."
    exit 1
fi

build_kalam_arch() {
    local arch="$1"
    local output="$2"
    local go_arch pc_dir cflags ldflags sysroot staging_dir build_status

    go_arch="$(go_arch_for "$arch")"
    pc_dir="$(libusb_pc_dir_for "$arch")"
    sysroot="$(xcrun --show-sdk-path)"
    cflags="$(PKG_CONFIG_PATH="$pc_dir" pkg-config --cflags libusb-1.0) -arch $arch -mmacosx-version-min=14.0 -isysroot $sysroot"
    ldflags="$(PKG_CONFIG_PATH="$pc_dir" pkg-config --libs libusb-1.0) -arch $arch -mmacosx-version-min=14.0 -isysroot $sysroot"

    echo "  Building libkalam.a for $arch using $pc_dir"
    staging_dir="$(mktemp -d "${TMPDIR:-/tmp}/macmtp-kalam.XXXXXX")"
    cp -R "$KALAM_DIR"/. "$staging_dir"/
    if [[ -f "$PROJECT_ROOT/scripts/kalam.go.patched" ]]; then
        cp "$PROJECT_ROOT/scripts/kalam.go.patched" "$staging_dir/kalam.go"
    fi
    if [[ -f "$PROJECT_ROOT/scripts/send_to_js_main.go.patched" ]]; then
        mkdir -p "$staging_dir/send_to_js"
        cp "$PROJECT_ROOT/scripts/send_to_js_main.go.patched" "$staging_dir/send_to_js/main.go"
    fi

    if (
        cd "$staging_dir"
        PKG_CONFIG_PATH="$pc_dir" \
        CGO_ENABLED=1 \
        GOARCH="$go_arch" \
        GOOS=darwin \
        CC=clang \
        CGO_CFLAGS="$cflags" \
        CGO_LDFLAGS="$ldflags" \
        go build -tags nosigsegv -buildmode=c-archive -o "$output" ./*.go
    ); then
        build_status=0
    else
        build_status=$?
    fi
    rm -rf "$staging_dir"
    return "$build_status"
}

build_swift_arch() {
    local arch="$1"
    local config="$2"
    local pc_dir lib_dir triple build_dir

    pc_dir="$(libusb_pc_dir_for "$arch")"
    lib_dir="$(libusb_lib_dir_for "$pc_dir")"
    triple="$(triple_for "$arch")"

    echo "  Building Swift target for $arch using libusb from $lib_dir" >&2
    if [[ "$config" == "release" ]]; then
        MACMTP_LIBUSB_LIB_DIR="$lib_dir" swift build -c release --triple "$triple" \
            -Xswiftc -Xfrontend -Xswiftc -disable-round-trip-debug-types >&2
        build_dir="$PROJECT_ROOT/.build/$triple/release"
    else
        MACMTP_LIBUSB_LIB_DIR="$lib_dir" swift build --triple "$triple" >&2
        build_dir="$PROJECT_ROOT/.build/$triple/debug"
    fi

    echo "$build_dir/macmtp"
}

copy_libusb_for_bundle() {
    local arch="$1"
    local destination="$2"
    local pc_dir lib_dir dylib

    pc_dir="$(libusb_pc_dir_for "$arch")"
    lib_dir="$(libusb_lib_dir_for "$pc_dir")"
    dylib="$(libusb_dylib_for "$lib_dir")"
    validate_dylib_arch "$dylib" "$arch"
    cp "$dylib" "$destination"
}

echo ""
echo "Step 1: Build Kalam"
mkdir -p "$KALAM_OUTPUT"

if [[ "$BUILD_UNIVERSAL" == true ]]; then
    build_kalam_arch "arm64" "$KALAM_OUTPUT/libkalam_arm64.a"
    build_kalam_arch "x86_64" "$KALAM_OUTPUT/libkalam_x86_64.a"
    lipo -create -output "$KALAM_OUTPUT/libkalam.a" \
        "$KALAM_OUTPUT/libkalam_arm64.a" \
        "$KALAM_OUTPUT/libkalam_x86_64.a"
    rm -f "$KALAM_OUTPUT/libkalam_arm64.a" "$KALAM_OUTPUT/libkalam_x86_64.a"
else
    build_kalam_arch "$TARGET_ARCH" "$KALAM_OUTPUT/libkalam.a"
fi

cp "$KALAM_DIR/libkalam.h" "$KALAM_OUTPUT/include/kalam.h" 2>/dev/null || true

rewrite_libusb_in_binary() {
    local bin="$1"
    local ref
    ref="$(otool -L "$bin" | grep 'libusb' | awk '{print $1}')"
    if [[ -z "$ref" ]]; then
        echo "ERROR: No libusb reference found in $bin" >&2
        exit 1
    fi
    echo "  Rewriting dylib reference in $(basename "$bin"): $ref -> @executable_path/libusb.dylib"
    install_name_tool -change "$ref" "@executable_path/libusb.dylib" "$bin"
}

echo ""
echo "Step 2: Build Swift"
if [[ "$BUILD_UNIVERSAL" == true ]]; then
    ARM_BIN="$(build_swift_arch arm64 release)"
    X86_BIN="$(build_swift_arch x86_64 release)"
    rewrite_libusb_in_binary "$ARM_BIN"
    rewrite_libusb_in_binary "$X86_BIN"
    mkdir -p "$PROJECT_ROOT/.build/universal"
    lipo -create -output "$PROJECT_ROOT/.build/universal/macmtp" "$ARM_BIN" "$X86_BIN"
    SWIFT_BIN="$PROJECT_ROOT/.build/universal/macmtp"
else
    SWIFT_BIN="$(build_swift_arch "$TARGET_ARCH" "$BUILD_MODE")"
fi

if [[ ! -f "$SWIFT_BIN" ]]; then
    echo "ERROR: Swift binary not found at $SWIFT_BIN"
    exit 1
fi

echo ""
echo "Step 3: Create app bundle"
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources"
cp "$SWIFT_BIN" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"

if [[ -f "$PROJECT_ROOT/Resources/Info.plist" ]]; then
    cp "$PROJECT_ROOT/Resources/Info.plist" "$APP_BUNDLE/Contents/Info.plist"
else
    echo "ERROR: Resources/Info.plist not found"
    exit 1
fi

if [[ -n "${SENTRY_DSN:-}" ]]; then
    /usr/libexec/PlistBuddy -c "Add :SentryDSN string $SENTRY_DSN" "$APP_BUNDLE/Contents/Info.plist" 2>/dev/null \
        || /usr/libexec/PlistBuddy -c "Set :SentryDSN $SENTRY_DSN" "$APP_BUNDLE/Contents/Info.plist"
else
    echo "NOTICE: SENTRY_DSN not provided; building app bundle without embedded Sentry DSN."
fi

if [[ -f "$PROJECT_ROOT/Resources/AppIcon.icns" ]]; then
    cp "$PROJECT_ROOT/Resources/AppIcon.icns" "$APP_BUNDLE/Contents/Resources/"
fi

if [[ "$BUILD_UNIVERSAL" == true ]]; then
    TMP_LIBUSB_DIR="$(mktemp -d)"
    copy_libusb_for_bundle arm64 "$TMP_LIBUSB_DIR/libusb_arm64.dylib"
    copy_libusb_for_bundle x86_64 "$TMP_LIBUSB_DIR/libusb_x86_64.dylib"
    lipo -create -output "$APP_BUNDLE/Contents/MacOS/libusb.dylib" \
        "$TMP_LIBUSB_DIR/libusb_arm64.dylib" \
        "$TMP_LIBUSB_DIR/libusb_x86_64.dylib"
    rm -rf "$TMP_LIBUSB_DIR"
else
    copy_libusb_for_bundle "$TARGET_ARCH" "$APP_BUNDLE/Contents/MacOS/libusb.dylib"
fi

install_name_tool -id "@executable_path/libusb.dylib" "$APP_BUNDLE/Contents/MacOS/libusb.dylib"

if [[ "$BUILD_UNIVERSAL" != true ]]; then
    rewrite_libusb_in_binary "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
fi

if otool -L "$APP_BUNDLE/Contents/MacOS/$APP_NAME" | grep 'libusb' | grep -qv '@executable_path'; then
    echo "ERROR: libusb path was not rewritten. Binary still references:"
    otool -L "$APP_BUNDLE/Contents/MacOS/$APP_NAME" | grep 'libusb' | grep -v '@executable_path'
    exit 1
fi

if [[ "$BUILD_MODE" == "release" || "$BUILD_UNIVERSAL" == true ]]; then
    echo "Generating dSYM..."
    rm -rf "$APP_DSYM"
    xcrun dsymutil "$APP_BUNDLE/Contents/MacOS/$APP_NAME" -o "$APP_DSYM"
    if ! xcrun dwarfdump --uuid "$APP_DSYM" | grep -q 'UUID:'; then
        echo "ERROR: Generated dSYM contains no debug UUID." >&2
        exit 1
    fi
fi
echo -n "APPL????" > "$APP_BUNDLE/Contents/PkgInfo"

echo ""
echo "Step 4: Code sign"
codesign -s - --force "$APP_BUNDLE/Contents/MacOS/libusb.dylib"
codesign -s - --force --deep "$APP_BUNDLE"
codesign --verify --verbose "$APP_BUNDLE" >/dev/null 2>&1 || true

echo ""
echo "Build complete: $APP_BUNDLE"
echo "Binary architectures: $(lipo -archs "$APP_BUNDLE/Contents/MacOS/$APP_NAME")"
echo "libusb architectures: $(lipo -archs "$APP_BUNDLE/Contents/MacOS/libusb.dylib")"
