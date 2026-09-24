// CKalam shim — required so SPM sees at least one .c file in this target.
// The actual implementation lives in libkalam.a (Go c-archive).
#include "kalam.h"
#include "macmtp_usb.h"

#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/IOCFPlugIn.h>
#include <IOKit/usb/IOUSBLib.h>
#include <IOKit/usb/USB.h>

static bool macmtp_device_has_mtp_interface(IOUSBDeviceInterface187 **device) {
    IOUSBFindInterfaceRequest request = {
        kIOUSBFindInterfaceDontCare,
        kIOUSBFindInterfaceDontCare,
        kIOUSBFindInterfaceDontCare,
        kIOUSBFindInterfaceDontCare
    };
    io_iterator_t interfaces = 0;
    if ((*device)->CreateInterfaceIterator(device, &request, &interfaces) != kIOReturnSuccess) {
        return false;
    }

    bool found = false;
    io_service_t interfaceService;
    while ((interfaceService = IOIteratorNext(interfaces)) != 0) {
        IOCFPlugInInterface **plugin = NULL;
        SInt32 score = 0;
        if (IOCreatePlugInInterfaceForService(
                interfaceService,
                kIOUSBInterfaceUserClientTypeID,
                kIOCFPlugInInterfaceID,
                &plugin,
                &score) == kIOReturnSuccess && plugin != NULL) {
            IOUSBInterfaceInterface **interface = NULL;
            if ((*plugin)->QueryInterface(
                    plugin,
                    CFUUIDGetUUIDBytes(kIOUSBInterfaceInterfaceID100),
                    (LPVOID *)&interface) == kIOReturnSuccess && interface != NULL) {
                UInt8 interfaceClass = 0;
                UInt8 interfaceSubClass = 0;
                UInt8 interfaceProtocol = 0;
                found = (*interface)->GetInterfaceClass(interface, &interfaceClass) == kIOReturnSuccess
                    && (*interface)->GetInterfaceSubClass(interface, &interfaceSubClass) == kIOReturnSuccess
                    && (*interface)->GetInterfaceProtocol(interface, &interfaceProtocol) == kIOReturnSuccess
                    && interfaceClass == kUSBImageInterfaceClass
                    && interfaceSubClass == 1
                    && interfaceProtocol == 1;
                (*interface)->Release(interface);
            }
            (*plugin)->Release(plugin);
        }
        IOObjectRelease(interfaceService);
        if (found) {
            break;
        }
    }
    IOObjectRelease(interfaces);
    return found;
}

int32_t macmtp_reenumerate_mtp_devices(void) {
    CFMutableDictionaryRef matching = IOServiceMatching(kIOUSBDeviceClassName);
    if (matching == NULL) {
        return kIOReturnError;
    }

    io_iterator_t iterator = 0;
    kern_return_t result = IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator);
    if (result != KERN_SUCCESS) {
        return result;
    }

    int32_t reenumerated = 0;
    io_service_t deviceService;
    while ((deviceService = IOIteratorNext(iterator)) != 0) {
        IOCFPlugInInterface **plugin = NULL;
        SInt32 score = 0;
        result = IOCreatePlugInInterfaceForService(
            deviceService,
            kIOUSBDeviceUserClientTypeID,
            kIOCFPlugInInterfaceID,
            &plugin,
            &score
        );
        if (result == kIOReturnSuccess && plugin != NULL) {
            IOUSBDeviceInterface187 **device = NULL;
            result = (*plugin)->QueryInterface(
                plugin,
                CFUUIDGetUUIDBytes(kIOUSBDeviceInterfaceID187),
                (LPVOID *)&device
            );
            if (result == kIOReturnSuccess && device != NULL) {
                if (macmtp_device_has_mtp_interface(device)) {
                    IOReturn openResult = (*device)->USBDeviceOpenSeize(device);
                    if (openResult == kIOReturnSuccess) {
                        IOReturn resetResult = (*device)->USBDeviceReEnumerate(device, 0);
                        (*device)->USBDeviceClose(device);
                        if (resetResult == kIOReturnSuccess) {
                            reenumerated += 1;
                        }
                    }
                }
                (*device)->Release(device);
            }
            (*plugin)->Release(plugin);
        }
        IOObjectRelease(deviceService);
    }
    IOObjectRelease(iterator);
    return reenumerated;
}
