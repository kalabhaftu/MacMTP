#ifndef MACMTP_USB_H
#define MACMTP_USB_H

#include <stdint.h>

// Re-enumerate USB still-imaging interfaces to clear a device-side MTP session.
// Returns the number of devices re-enumerated, or a negative IOReturn value.
int32_t macmtp_reenumerate_mtp_devices(void);

#endif
