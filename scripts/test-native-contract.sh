#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SEND_SOURCE="$ROOT_DIR/Vendor/Kalam/native/send_to_js/main.go"
NATIVE_HELPERS="$ROOT_DIR/Vendor/Kalam/native/helpers.go"
BRIDGE_SOURCE="$ROOT_DIR/Sources/macmtp/MTP/KalamBridge.swift"
KALAM_SOURCE="$ROOT_DIR/Vendor/Kalam/native/kalam.go"
USB_SOURCE="$ROOT_DIR/Vendor/Kalam/native/vendor/github.com/ganeshrvel/usb/usb.go"

require_pattern() {
    local pattern="$1"
    local file="$2"
    if ! grep -Eq -- "$pattern" "$file"; then
        echo "ERROR: native response contract is missing: $pattern" >&2
        exit 1
    fi
}

# These assertions protect the JSON boundary compiled into the app from the
# vendored Kalam source.
require_pattern 'outputFiles := make\(\[\]FileInfo, 0, len\(files\)\)' "$SEND_SOURCE"
require_pattern 'fdSlice := make\(\[\]FileExistsData, 0, len\(fc\)\)' "$SEND_SOURCE"
require_pattern 'storages = make\(\[\]mtpx.StorageData, 0\)' "$SEND_SOURCE"
require_pattern 'type MutationResult struct' "$SEND_SOURCE"
require_pattern 'ObjectId  uint32' "$SEND_SOURCE"
require_pattern 'json:"objectId"' "$SEND_SOURCE"
require_pattern 'makeDirectoryWithResult' "$KALAM_SOURCE"
require_pattern 'renameFileWithResult' "$KALAM_SOURCE"
require_pattern 'func BeginTransfer' "$KALAM_SOURCE"
require_pattern 'func CancelTransfer' "$KALAM_SOURCE"
require_pattern 'func SetOperationID' "$KALAM_SOURCE"
require_pattern 'func SendOperationActivity' "$SEND_SOURCE"
require_pattern 'macMTP_activity_callback' "$SEND_SOURCE"
require_pattern 'send_to_js\.SendOperationActivity\(\)' "$NATIVE_HELPERS"
require_pattern '@_cdecl\("macMTP_activity_callback"\)' "$BRIDGE_SOURCE"
require_pattern 'func Initialize\(inputJSON \*C.char\)' "$KALAM_SOURCE"
require_pattern 'func DiscoverMTPDevices' "$KALAM_SOURCE"
require_pattern 'ErrorTransferCancelled' "$ROOT_DIR/Vendor/Kalam/native/send_to_js/enums.go"
require_pattern 'libusb_interrupt_transfer' "$USB_SOURCE"

(
    cd "$ROOT_DIR/Vendor/Kalam/native"
    go test -mod=vendor ./... github.com/ganeshrvel/go-mtpfs/mtp github.com/ganeshrvel/go-mtpx
)

echo "Verified native collection and mutation response contract."
