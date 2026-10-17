# libusb build patch

Scripted app builds use libusb 1.0.30, downloaded from the official release
and checked against its SHA-256 digest. `scripts/install-libusb.sh` builds
each architecture into this directory's ignored `build/` folder.

`darwin-invalid-address.patch` handles a macOS enumeration entry whose USB
address cannot fit libusb's eight-bit address. It returns `LIBUSB_ERROR_NO_DEVICE`
before allocating a device, allowing enumeration to continue with other devices.
Upstream instead asserts and terminates the process. This was the assertion in
Sentry APPLE-MACOS-18 on macOS 27.0.1, confirmed against the v1.7.8 arm64 dylib
UUID `0fd95c30-6469-3c52-83ca-1059f9591751` and its assertion arguments.

The installer generates the library's dSYM while its temporary object files
still exist. Release packaging uploads these symbols alongside the app's dSYM.

The patch does not truncate addresses or disable assertions globally.
`test-libusb-address-guard.py` compiles the patched function's preflight code
and checks valid and invalid address boundaries before the library is built.

libusb is dynamically linked and licensed under LGPL 2.1 or later. Original
source and license: https://github.com/libusb/libusb/tree/v1.0.30.
The source archive and this patch provide the source used to build the library.
