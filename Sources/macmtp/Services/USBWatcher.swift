import Foundation
import CKalam
import IOKit
import IOKit.usb

struct USBDeviceIdentity: Hashable, Sendable {
    let vendorID: UInt16
    let productID: UInt16
    let locationID: UInt32?
    let serialNumber: String?

    func matches(vendorID: UInt16, productID: UInt16, serialNumber: String?) -> Bool {
        guard self.vendorID == vendorID, self.productID == productID else { return false }

        let nativeSerial = serialNumber?.trimmingCharacters(in: .whitespacesAndNewlines)
        let deviceSerial = self.serialNumber?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let nativeSerial, !nativeSerial.isEmpty,
              let deviceSerial, !deviceSerial.isEmpty else {
            return true
        }
        return nativeSerial == deviceSerial
    }
}

struct USBDeviceNames: Equatable, Sendable {
    let vendorID: UInt16
    let productID: UInt16
    let manufacturer: String
    let product: String
}

struct USBConnectionLifecycle: Equatable {
    private(set) var generation: UInt64 = 0

    mutating func attachScheduled() -> UInt64 {
        generation &+= 1
        return generation
    }

    mutating func detached() -> UInt64 {
        generation &+= 1
        return generation
    }

    func accepts(_ token: UInt64) -> Bool {
        token == generation
    }
}

func newlyAttachedUSBIdentities(
    _ identities: [USBDeviceIdentity],
    known: Set<USBDeviceIdentity>
) -> [USBDeviceIdentity] {
    var seen = known
    return identities.filter { seen.insert($0).inserted }
}

func usbInventoryChanged(
    previous: Set<USBDeviceIdentity>,
    current: Set<USBDeviceIdentity>
) -> Bool {
    previous != current
}

@MainActor
public final class USBWatcher: ObservableObject, @unchecked Sendable {
    
    
    public static let shared = USBWatcher()
    
    
    private var notificationPort: IONotificationPortRef?
    private var addedIterator: io_iterator_t = 0
    private var removedIterator: io_iterator_t = 0
    private var runLoopSource: CFRunLoopSource?
    private var isWatching = false
    private var knownDeviceIdentities: Set<USBDeviceIdentity> = []
    private var availableDeviceIdentities: Set<USBDeviceIdentity> = []
    private var availableDeviceNames: [USBDeviceNames] = []
    
    
    private init() {}


    
    
    public func startWatching() {
        guard !isWatching else { return }
        
        guard let port = IONotificationPortCreate(kIOMainPortDefault) else {
            return
        }
        self.notificationPort = port
        self.isWatching = true
        
        self.runLoopSource = IONotificationPortGetRunLoopSource(port).takeUnretainedValue()
        CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        
        guard let matchingDict1 = IOServiceMatching(kIOUSBDeviceClassName),
              let matchingDict2 = IOServiceMatching(kIOUSBDeviceClassName) else {
            cleanupWatchingResources()
            return
        }
        
        let selfPtr = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        
        let addedResult = IOServiceAddMatchingNotification(
            port,
            kIOPublishNotification,
            matchingDict1,
            { (refcon, iterator) in
                let watcher = Unmanaged<USBWatcher>.fromOpaque(refcon!).takeUnretainedValue()
                Task { @MainActor in
                    watcher.handleDevicesAdded(iterator: iterator)
                }
            },
            selfPtr,
            &addedIterator
        )
        
        if addedResult != kIOReturnSuccess {
            cleanupWatchingResources()
            return
        }
        
        // IOKit returns already-published devices through this iterator. Drain
        // it immediately so a phone connected before launch is not missed.
        handleDevicesAdded(iterator: addedIterator, isInitialScan: true)
        
        let removedResult = IOServiceAddMatchingNotification(
            port,
            kIOTerminatedNotification,
            matchingDict2,
            { (refcon, iterator) in
                let watcher = Unmanaged<USBWatcher>.fromOpaque(refcon!).takeUnretainedValue()
                Task { @MainActor in
                    await watcher.handleDevicesRemoved(iterator: iterator)
                }
            },
            selfPtr,
            &removedIterator
        )
        
        if removedResult != kIOReturnSuccess {
            cleanupWatchingResources()
            return
        }
        
        Task { @MainActor in
            await handleDevicesRemoved(iterator: removedIterator, isInitialScan: true)
        }
        
    }
    
    public func stopWatching() {
        guard isWatching || notificationPort != nil || addedIterator != 0 || removedIterator != 0 else { return }
        cleanupWatchingResources()
    }

    @discardableResult
    func reenumerateMTPDevices() -> Int32 {
        macmtp_reenumerate_mtp_devices()
    }

    private func cleanupWatchingResources() {
        knownDeviceIdentities.removeAll()
        availableDeviceIdentities.removeAll()
        availableDeviceNames.removeAll()
        MTPConnectionCoordinator.shared.updateAvailableDevices([])
        
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
            runLoopSource = nil
        }
        
        if addedIterator != 0 {
            IOObjectRelease(addedIterator)
            addedIterator = 0
        }
        
        if removedIterator != 0 {
            IOObjectRelease(removedIterator)
            removedIterator = 0
        }
        
        if let port = notificationPort {
            IONotificationPortDestroy(port)
            notificationPort = nil
        }
        
        isWatching = false
    }
    
    
    private func handleDevicesAdded(iterator: io_iterator_t, isInitialScan: Bool = false) {
        var identities: [USBDeviceIdentity] = []
        while case let device = IOIteratorNext(iterator), device != 0 {
            if let identity = deviceIdentity(for: device) {
                identities.append(identity)
            }
            IOObjectRelease(device)
        }
        
        knownDeviceIdentities.formUnion(identities)
        let inventory = connectedUSBDeviceInventory()
        availableDeviceIdentities = inventory.identities
        availableDeviceNames = inventory.names
        MTPConnectionCoordinator.shared.updateAvailableDevices(
            availableDeviceIdentities,
            usbNames: availableDeviceNames,
            startAutomatically: UserDefaults.standard.object(forKey: "autoDetectDevice") as? Bool ?? true
        )
        ErrorLogger.logMessage(
            "USB device availability changed",
            level: .info,
            userInfo: [
                "event": "usb_inventory_changed",
                "state": availableDeviceIdentities.isEmpty ? "usb_absent" : "usb_detected",
                "initial_scan": isInitialScan,
                "usb_device_count": availableDeviceIdentities.count,
                "usb_vendor_ids": Array(Set(inventory.identities.map(\.vendorID))).sorted()
            ]
        )
    }
    
    private func handleDevicesRemoved(iterator: io_iterator_t, isInitialScan: Bool = false) async {
        while case let device = IOIteratorNext(iterator), device != 0 {
            if let identity = deviceIdentity(for: device) {
                knownDeviceIdentities.remove(identity)
            }
            IOObjectRelease(device)
        }

        // Draining the removal iterator arms future notifications; it is not a
        // device-removal event and must not cancel the launch-time connection.
        guard !isInitialScan else { return }
        
        try? await Task.sleep(nanoseconds: 150_000_000)
        let inventory = connectedUSBDeviceInventory()
        availableDeviceIdentities = inventory.identities
        availableDeviceNames = inventory.names
        knownDeviceIdentities = availableDeviceIdentities
        MTPConnectionCoordinator.shared.updateAvailableDevices(
            availableDeviceIdentities,
            usbNames: availableDeviceNames,
            startAutomatically: UserDefaults.standard.object(forKey: "autoDetectDevice") as? Bool ?? true
        )
        ErrorLogger.logMessage(
            "USB device availability changed",
            level: .info,
            userInfo: [
                "event": "usb_inventory_changed",
                "state": availableDeviceIdentities.isEmpty ? "usb_absent" : "usb_detected",
                "usb_device_count": availableDeviceIdentities.count,
                "usb_vendor_ids": Array(Set(inventory.identities.map(\.vendorID))).sorted()
            ]
        )
    }
    
    private func deviceIdentity(for device: io_object_t) -> USBDeviceIdentity? {
        let vendorID = (IORegistryEntryCreateCFProperty(device, "idVendor" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? NSNumber)?.uint16Value
        let productID = (IORegistryEntryCreateCFProperty(device, "idProduct" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? NSNumber)?.uint16Value
        let locationID = (IORegistryEntryCreateCFProperty(device, "locationID" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? NSNumber)?.uint32Value
        let serial = IORegistryEntryCreateCFProperty(device, "USB Serial Number" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String
        guard let vendorID, let productID else { return nil }
        return USBDeviceIdentity(
            vendorID: vendorID,
            productID: productID,
            locationID: locationID,
            serialNumber: serial
        )
    }

    private func deviceNames(for device: io_object_t) -> USBDeviceNames? {
        let vendorID = (IORegistryEntryCreateCFProperty(device, "idVendor" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? NSNumber)?.uint16Value
        let productID = (IORegistryEntryCreateCFProperty(device, "idProduct" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? NSNumber)?.uint16Value
        guard let vendorID, let productID else { return nil }
        return USBDeviceNames(
            vendorID: vendorID,
            productID: productID,
            manufacturer: IORegistryEntryCreateCFProperty(device, "USB Vendor Name" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String ?? "",
            product: IORegistryEntryCreateCFProperty(device, "USB Product Name" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String ?? ""
        )
    }

    private func connectedUSBDeviceInventory() -> (identities: Set<USBDeviceIdentity>, names: [USBDeviceNames]) {
        guard let matchingDict = IOServiceMatching(kIOUSBDeviceClassName) as? [String: Any] else {
            return ([], [])
        }

        var iterator: io_iterator_t = 0
        let result = IOServiceGetMatchingServices(kIOMainPortDefault, matchingDict as CFDictionary, &iterator)

        if result != kIOReturnSuccess {
            return ([], [])
        }
        defer { IOObjectRelease(iterator) }

        var identities: Set<USBDeviceIdentity> = []
        var names: [USBDeviceNames] = []
        while case let device = IOIteratorNext(iterator), device != 0 {
            defer { IOObjectRelease(device) }
            if let identity = deviceIdentity(for: device) {
                identities.insert(identity)
            }
            if let deviceNames = deviceNames(for: device) {
                names.append(deviceNames)
            }
        }
        return (identities, names)
    }
}
