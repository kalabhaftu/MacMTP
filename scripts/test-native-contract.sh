#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SEND_SOURCE="$ROOT_DIR/Vendor/Kalam/native/send_to_js/main.go"
KALAM_SOURCE="$ROOT_DIR/Vendor/Kalam/native/kalam.go"

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

echo "Verified native collection and mutation response contract."
