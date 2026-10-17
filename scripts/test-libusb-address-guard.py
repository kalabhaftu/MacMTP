#!/usr/bin/env python3
"""Run the patched Darwin enumeration preflight against address boundaries."""
import pathlib
import subprocess
import sys
import tempfile

source = pathlib.Path(sys.argv[1]).read_text()
signature = "static enum libusb_error process_new_device ("
start = source.rindex(signature)
preflight = source[source.index("{", start) + 1:source.index("  do {", start)]
assert "assert(cached_device->address <= UINT8_MAX)" not in source
# Compile the actual patched preflight, rather than duplicating its condition.
# Reaching the original function body is represented by a success return.
harness = r'''
#include <stdint.h>
#include <stddef.h>
#include <assert.h>
typedef uint8_t UInt8;
enum libusb_error { LIBUSB_SUCCESS = 0, LIBUSB_ERROR_NO_DEVICE = -4 };
struct darwin_cached_device { unsigned int address; };
struct darwin_device_priv;
struct libusb_device;
#define usbi_warn(...) ((void)0)
static int enumerate(unsigned int address) {
  struct darwin_cached_device entry = {address};
  struct darwin_cached_device *cached_device = &entry;
''' + preflight + r'''
  return LIBUSB_SUCCESS;
}
int main(void) {
  assert(enumerate(0) == LIBUSB_SUCCESS);
  assert(enumerate(1) == LIBUSB_SUCCESS);
  assert(enumerate(127) == LIBUSB_SUCCESS);
  assert(enumerate(255) == LIBUSB_SUCCESS);
  assert(enumerate(256) == LIBUSB_ERROR_NO_DEVICE);
  assert(enumerate(65535) == LIBUSB_ERROR_NO_DEVICE);
  /* A bad entry must not affect the next valid entry. */
  assert(enumerate(2) == LIBUSB_SUCCESS);
}
'''
with tempfile.TemporaryDirectory(prefix="macmtp-usb-test-") as directory:
    root = pathlib.Path(directory)
    fixture = root / "address.c"
    fixture.write_text(harness)
    executable = root / "address-test"
    subprocess.run(["cc", "-std=c11", str(fixture), "-o", str(executable)], check=True)
    subprocess.run([str(executable)], check=True)
print("Verified libusb Darwin enumeration preflight address boundaries.")
