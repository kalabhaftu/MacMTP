#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
APP_NAME="macMTP"
VERSION="1.0.0"
RELEASE_DIR="$PROJECT_ROOT/release"
APP_BUNDLE="$PROJECT_ROOT/$APP_NAME.app"
APP_DSYM="$PROJECT_ROOT/$APP_NAME.app.dSYM"
TARGETS=()

usage() {
    cat <<EOF
Usage: scripts/release.sh [version] [--arch arm64|x86_64|universal] [--all]
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --arch)
            TARGETS+=("${2:?missing value for --arch}")
            shift 2
            ;;
        -u|--universal)
            TARGETS+=("universal")
            shift
            ;;
        --all)
            TARGETS=("arm64" "x86_64" "universal")
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            if [[ "$1" =~ ^v?[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
                VERSION="${1#v}"
                shift
            else
                echo "ERROR: Unknown argument: $1"
                usage
                exit 1
            fi
            ;;
    esac
done

if [[ ${#TARGETS[@]} -eq 0 ]]; then
    TARGETS=("$(uname -m)")
fi

for required_name in SENTRY_DSN SENTRY_AUTH_TOKEN SENTRY_ORG SENTRY_PROJECT; do
    if [[ -z "${!required_name:-}" ]]; then
        echo "ERROR: $required_name is required for release error tracking." >&2
        exit 1
    fi
done

if ! command -v sentry-cli >/dev/null 2>&1; then
    echo "ERROR: sentry-cli is required to upload release symbols." >&2
    exit 1
fi

echo "========================================"
echo "  macMTP Release"
echo "  Version: $VERSION"
echo "  Targets: ${TARGETS[*]}"
echo "========================================"

rm -rf "$RELEASE_DIR"
mkdir -p "$RELEASE_DIR"

set_version() {
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP_BUNDLE/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $VERSION" "$APP_BUNDLE/Contents/Info.plist"
    codesign -s - --force --deep "$APP_BUNDLE"
}

build_target() {
    local target="$1"

    case "$target" in
        arm64)
            bash "$SCRIPT_DIR/build.sh" release --arch arm64
            ;;
        x86_64)
            bash "$SCRIPT_DIR/build.sh" release --arch x86_64
            ;;
        universal)
            bash "$SCRIPT_DIR/build.sh" release --universal
            ;;
        *)
            echo "ERROR: Unsupported release target: $target"
            exit 1
            ;;
    esac

    if [[ ! -d "$APP_BUNDLE" ]]; then
        echo "ERROR: App bundle not found at $APP_BUNDLE"
        exit 1
    fi
    if [[ ! -d "$APP_DSYM" ]]; then
        echo "ERROR: dSYM bundle not found at $APP_DSYM" >&2
        exit 1
    fi
}

package_target() {
    local target="$1"
    local dmg_name="$APP_NAME-$VERSION-mac-$target.dmg"
    local zip_name="$APP_NAME-$VERSION-mac-$target.zip"
    local dsym_name="$APP_NAME-$VERSION-mac-$target.dSYM.zip"

    set_version

    echo "Packaging $target ZIP..."
    (
        cd "$PROJECT_ROOT"
        ditto -c -k --sequesterRsrc --keepParent "$APP_BUNDLE" "$RELEASE_DIR/$zip_name"
        ditto -c -k --keepParent "$APP_DSYM" "$RELEASE_DIR/$dsym_name"
    )

    echo "Uploading $target debug symbols to Sentry..."
    sentry-cli debug-files upload \
        --org "$SENTRY_ORG" \
        --project "$SENTRY_PROJECT" \
        --type dsym \
        --wait-for 60 \
        "$APP_DSYM"

    echo "Packaging $target DMG..."
    rm -f "$RELEASE_DIR/$dmg_name"
    if command -v create-dmg >/dev/null 2>&1; then
        create-dmg \
            --volname "macMTP" \
            --window-pos 200 120 \
            --window-size 600 400 \
            --icon-size 100 \
            --icon "$APP_NAME.app" 150 190 \
            --hide-extension "$APP_NAME.app" \
            --app-drop-link 450 190 \
            "$RELEASE_DIR/$dmg_name" \
            "$APP_BUNDLE"
    else
        hdiutil create -volname "macMTP" -srcfolder "$APP_BUNDLE" -ov -format UDZO "$RELEASE_DIR/$dmg_name"
    fi

    (
        cd "$RELEASE_DIR"
        shasum -a 256 "$dmg_name" > "$dmg_name.sha256"
        shasum -a 256 "$zip_name" > "$zip_name.sha256"
        shasum -a 256 "$dsym_name" > "$dsym_name.sha256"
    )
}

for target in "${TARGETS[@]}"; do
    echo ""
    echo "Building release target: $target"
    build_target "$target"
    package_target "$target"
done

echo "Writing latest-mac.yml..."
{
    echo "version: $VERSION"
    echo "files:"
    for file in "$RELEASE_DIR"/*.zip "$RELEASE_DIR"/*.dmg; do
        [[ "$file" == *.dSYM.zip ]] && continue
        name="$(basename "$file")"
        echo "  - url: $name"
        echo "    sha256: $(shasum -a 256 "$file" | awk '{print $1}')"
        echo "    size: $(stat -f%z "$file")"
    done
    preferred="$APP_NAME-$VERSION-mac-universal.zip"
    if [[ ! -f "$RELEASE_DIR/$preferred" ]]; then
        preferred="$(basename "$(find "$RELEASE_DIR" -name '*.zip' ! -name '*.dSYM.zip' | sort | head -1)")"
    fi
    echo "path: $preferred"
    echo "releaseDate: '$(date -u +"%Y-%m-%dT%H:%M:%S.000Z")'"
} > "$RELEASE_DIR/latest-mac.yml"

echo ""
echo "Release artifacts:"
ls -lh "$RELEASE_DIR"
