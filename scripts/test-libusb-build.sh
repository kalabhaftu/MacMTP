#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

# Use the real functions inside command substitutions, where Bash clears
# errexit. An installer failure must never fall through to system libusb.
eval "$(sed -n '/^libusb_pc_dir_for() {/,/^}/p' "$ROOT_DIR/scripts/build.sh")"
eval "$(sed -n '/^build_swift_arch() {/,/^}/p' "$ROOT_DIR/scripts/build.sh")"
SCRIPT_DIR="$ROOT_DIR/scripts"
PROJECT_ROOT="$ROOT_DIR"
unset MACMTP_ARM64_LIBUSB_PKGCONFIG MACMTP_X86_64_LIBUSB_PKGCONFIG
bash() { return 42; }

if result="$(libusb_pc_dir_for arm64)"; then
    echo "ERROR: failed libusb installation was accepted" >&2
    exit 1
else
    [[ $? == 42 && -z "$result" ]]
fi
if result="$(build_swift_arch arm64 release)"; then
    echo "ERROR: Swift build continued after failed libusb installation" >&2
    exit 1
else
    [[ $? == 42 && -z "$result" ]]
fi
echo "Verified libusb installer failure stops library discovery and the build."
