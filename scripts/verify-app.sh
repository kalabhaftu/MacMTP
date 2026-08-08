#!/usr/bin/env bash
set -euo pipefail

APP_BUNDLE="${1:-}"
EXPECTED_ARCH="${2:-}"
APP_NAME="macMTP"

if [[ -z "$APP_BUNDLE" || -z "$EXPECTED_ARCH" ]]; then
    echo "Usage: scripts/verify-app.sh <app-bundle> <arm64|x86_64|universal>" >&2
    exit 1
fi

INFO_PLIST="$APP_BUNDLE/Contents/Info.plist"
EXECUTABLE="$APP_BUNDLE/Contents/MacOS/$APP_NAME"
LIBUSB="$APP_BUNDLE/Contents/MacOS/libusb.dylib"

for required_path in "$INFO_PLIST" "$EXECUTABLE" "$LIBUSB"; do
    if [[ ! -e "$required_path" ]]; then
        echo "ERROR: Required app bundle path is missing: $required_path" >&2
        exit 1
    fi
done

plist_value() {
    /usr/libexec/PlistBuddy -c "Print :$1" "$INFO_PLIST"
}

contains_arch() {
    local archs="$1"
    local expected="$2"
    tr ' ' '\n' <<< "$archs" | grep -qx "$expected"
}

executable_archs="$(lipo -archs "$EXECUTABLE")"
libusb_archs="$(lipo -archs "$LIBUSB")"

case "$EXPECTED_ARCH" in
    arm64|x86_64)
        if [[ "$executable_archs" != "$EXPECTED_ARCH" || "$libusb_archs" != "$EXPECTED_ARCH" ]]; then
            echo "ERROR: Expected $EXPECTED_ARCH binaries; executable=$executable_archs libusb=$libusb_archs" >&2
            exit 1
        fi
        ;;
    universal)
        for arch in arm64 x86_64; do
            if ! contains_arch "$executable_archs" "$arch" || ! contains_arch "$libusb_archs" "$arch"; then
                echo "ERROR: Universal bundle is missing $arch; executable=$executable_archs libusb=$libusb_archs" >&2
                exit 1
            fi
        done
        ;;
    *)
        echo "ERROR: Unsupported expected architecture: $EXPECTED_ARCH" >&2
        exit 1
        ;;
esac

[[ "$(plist_value CFBundleIdentifier)" == "com.macmtp.app" ]] || {
    echo "ERROR: Unexpected bundle identifier." >&2
    exit 1
}
[[ "$(plist_value CFBundleExecutable)" == "$APP_NAME" ]] || {
    echo "ERROR: Unexpected bundle executable." >&2
    exit 1
}
[[ "$(plist_value CFBundleShortVersionString)" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
    echo "ERROR: Bundle version is not semantic-version shaped." >&2
    exit 1
}

if ! otool -L "$EXECUTABLE" | grep -Fq '@executable_path/libusb.dylib'; then
    echo "ERROR: Executable does not use the bundled libusb path." >&2
    exit 1
fi
if otool -L "$EXECUTABLE" | grep 'libusb' | grep -vFq '@executable_path/libusb.dylib'; then
    echo "ERROR: Executable still contains an external libusb reference." >&2
    exit 1
fi

if [[ "${MACMTP_REQUIRE_SENTRY_DSN:-0}" == "1" ]]; then
    sentry_dsn="$(plist_value SentryDSN 2>/dev/null || true)"
    if [[ -z "$sentry_dsn" ]]; then
        echo "ERROR: Release bundle does not contain SentryDSN." >&2
        exit 1
    fi
fi

codesign --verify --deep --strict "$APP_BUNDLE"
echo "Verified $APP_BUNDLE ($EXPECTED_ARCH; executable=$executable_archs; libusb=$libusb_archs)"
