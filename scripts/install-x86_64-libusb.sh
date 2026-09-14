#!/usr/bin/env bash
set -euo pipefail

DEST_DIR="${1:-/usr/local/opt/libusb}"

if [[ -f "$DEST_DIR/lib/libusb-1.0.dylib" && -f "$DEST_DIR/lib/pkgconfig/libusb-1.0.pc" ]]; then
    echo "x86_64 libusb is already installed at $DEST_DIR"
    exit 0
fi

echo "Installing x86_64 libusb to $DEST_DIR..."
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/libusb-x86_64.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT

curl -fsSL https://github.com/libusb/libusb/releases/download/v1.0.27/libusb-1.0.27.tar.bz2 | tar -xj -C "$TMP_DIR"
cd "$TMP_DIR/libusb-1.0.27"

./configure \
    --prefix="$DEST_DIR" \
    --disable-dependency-tracking \
    CFLAGS="-arch x86_64 -mmacosx-version-min=14.0" \
    LDFLAGS="-arch x86_64"

make -j"$(sysctl -n hw.ncpu || echo 4)"
sudo make install
echo "x86_64 libusb installed successfully at $DEST_DIR"
