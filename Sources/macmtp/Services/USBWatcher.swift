import Foundation
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
    
    
    private init() {}

    var availableSelector: MTPDeviceSelector? {
        availableDeviceIdentities.first?.selector
    }
    

    
    
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

    private func cleanupWatchingResources() {
        knownDeviceIdentities.removeAll()
        availableDeviceIdentities.removeAll()
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
        let allDeviceIdentities = connectedDeviceIdentities()
        availableDeviceIdentities = allDeviceIdentities
        MTPConnectionCoordinator.shared.updateAvailableDevices(
            availableDeviceIdentities,
            startAutomatically: UserDefaults.standard.object(forKey: "autoDetectDevice") as? Bool ?? true
        )
        ErrorLogger.logMessage(
            "USB device availability changed",
            level: .info,
            userInfo: [
                "event": "usb_scan",
                "state": availableDeviceIdentities.isEmpty ? "usb_absent" : "usb_detected",
                "initial_scan": isInitialScan,
                "usb_device_count": availableDeviceIdentities.count,
                "usb_vendor_ids": Array(Set(allDeviceIdentities.map(\.vendorID))).sorted()
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
        let allDeviceIdentities = connectedDeviceIdentities()
        availableDeviceIdentities = allDeviceIdentities
        knownDeviceIdentities = availableDeviceIdentities
        MTPConnectionCoordinator.shared.updateAvailableDevices(
            availableDeviceIdentities,
            startAutomatically: UserDefaults.standard.object(forKey: "autoDetectDevice") as? Bool ?? true
        )
        ErrorLogger.logMessage(
            "USB device availability changed",
            level: .info,
            userInfo: [
                "event": "usb_scan",
                "state": availableDeviceIdentities.isEmpty ? "usb_absent" : "usb_detected",
                "usb_device_count": availableDeviceIdentities.count,
                "usb_vendor_ids": Array(Set(allDeviceIdentities.map(\.vendorID))).sorted()
            ]
        )
    }
    
    private func deviceIdentity(for device: io_object_t) -> USBDeviceIdentity? {
        let vendorID = (IORegistryEntryCreateCFProperty(device, "idVendor" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? NSNumber)?.uint16Value
        let productID = (IORegistryEntryCreateCFProperty(device, "idProduct" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? NSNumber)?.uint16Value
        let locationID = (IORegistryEntryCreateCFProperty(device, "locationID" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? NSNumber)?.uint32Value
        let serial = IORegistryEntryCreateCFProperty(device, "USB Serial Number" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String
        let productName = IORegistryEntryCreateCFProperty(device, "USB Product Name" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String
        let nonPhoneProductWords = ["mouse", "keyboard", "camera", "hub", "bluetooth", "audio"]
        if let productName,
           nonPhoneProductWords.contains(where: { productName.localizedCaseInsensitiveContains($0) }) {
            return nil
        }
        guard let vendorID, let productID else { return nil }
        return USBDeviceIdentity(
            vendorID: vendorID,
            productID: productID,
            locationID: locationID,
            serialNumber: serial
        )
    }

    private func getDeviceName(device: io_object_t) -> String? {
        var nameChar = [CChar](repeating: 0, count: 128)
        let result = IORegistryEntryGetName(device, &nameChar)
        if result == kIOReturnSuccess {
            return String(decoding: nameChar.map { UInt8(bitPattern: $0) }, as: UTF8.self)
                .trimmingCharacters(in: .controlCharacters)
        }
        return nil
    }

    public func getConnectedAndroidVendorIDs() -> [UInt16] {
        Array(Set(androidDeviceIdentities().map(\.vendorID))).sorted()
    }

    private func androidDeviceIdentities() -> Set<USBDeviceIdentity> {
        connectedDeviceIdentities().filter {
            PTPConflictDetector.knownAndroidVendorIDs.contains($0.vendorID)
        }
    }

    private func connectedDeviceIdentities() -> Set<USBDeviceIdentity> {
        guard let matchingDict = IOServiceMatching(kIOUSBDeviceClassName) as? [String: Any] else {
            return []
        }

        var iterator: io_iterator_t = 0
        let result = IOServiceGetMatchingServices(kIOMainPortDefault, matchingDict as CFDictionary, &iterator)

        if result != kIOReturnSuccess {
            return []
        }
        defer { IOObjectRelease(iterator) }

        var identities: Set<USBDeviceIdentity> = []
        while case let device = IOIteratorNext(iterator), device != 0 {
            defer { IOObjectRelease(device) }
            if let identity = deviceIdentity(for: device) {
                identities.insert(identity)
            }
        }
        return identities
    }
}
