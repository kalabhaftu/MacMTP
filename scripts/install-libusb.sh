#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ARCH="${1:-$(uname -m)}"
case "$ARCH" in arm64|x86_64) ;; *) echo "Unsupported architecture: $ARCH" >&2; exit 1 ;; esac
DEST_DIR="${2:-$ROOT_DIR/Vendor/libusb/build/$ARCH}"
PATCH_FILE="$ROOT_DIR/Vendor/libusb/darwin-invalid-address.patch"
PATCH_HASH="$(shasum -a 256 "$PATCH_FILE" | awk '{print $1}')"
STAMP="1.0.30-$ARCH-$PATCH_HASH"

if [[ -f "$DEST_DIR/macmtp-build" && "$(cat "$DEST_DIR/macmtp-build")" == "$STAMP" && -f "$DEST_DIR/lib/libusb-1.0.dylib" && -f "$DEST_DIR/lib/pkgconfig/libusb-1.0.pc" && -d "$DEST_DIR/libusb.dylib.dSYM" ]]; then
    exit 0
fi

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/macmtp-libusb.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT
curl -fL --retry 3 -o "$TMP_DIR/libusb.tar.bz2" \
    https://github.com/libusb/libusb/releases/download/v1.0.30/libusb-1.0.30.tar.bz2
echo "fea36f34f9156400209595e300840767ab1a385ede1dc7ee893015aea9c6dbaf  $TMP_DIR/libusb.tar.bz2" | shasum -a 256 -c -
tar -xjf "$TMP_DIR/libusb.tar.bz2" -C "$TMP_DIR"
cd "$TMP_DIR/libusb-1.0.30"
patch -p1 < "$PATCH_FILE"
python3 "$ROOT_DIR/scripts/test-libusb-address-guard.py" "$PWD/libusb/os/darwin_usb.c"
./configure --prefix="$DEST_DIR" --disable-dependency-tracking \
    CFLAGS="-g -O2 -arch $ARCH -mmacosx-version-min=14.0" \
    LDFLAGS="-arch $ARCH -mmacosx-version-min=14.0"
make -j"$(sysctl -n hw.ncpu || echo 4)"
make install
# The temporary object files still exist here; dsymutil needs their DWARF.
dsymutil "$DEST_DIR/lib/libusb-1.0.0.dylib" -o "$DEST_DIR/libusb.dylib.dSYM"
printf '%s\n' "$STAMP" > "$DEST_DIR/macmtp-build"
