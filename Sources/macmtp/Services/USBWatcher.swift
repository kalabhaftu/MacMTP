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
    private var connectionLifecycle = USBConnectionLifecycle()
    private var pendingAutoConnectTask: Task<Void, Never>?
    private var activeDeviceVendorID: UInt16?
    private var activeDeviceProductID: UInt16?
    private var activeDeviceSerialNumber: String?
    private var knownDeviceIdentities: Set<USBDeviceIdentity> = []
    
    
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
            await handleDevicesRemoved(iterator: removedIterator)
        }
        
    }
    
    public func stopWatching() {
        guard isWatching || notificationPort != nil || addedIterator != 0 || removedIterator != 0 else { return }
        cleanupWatchingResources()
    }

    @discardableResult
    public func reconnectIfAvailable() -> Bool {
        guard isWatching,
              UserDefaults.standard.object(forKey: "autoDetectDevice") as? Bool ?? true else { return false }
        let identities = connectedDeviceIdentities()
        guard let vendorID = activeDeviceVendorID,
              let productID = activeDeviceProductID,
              identities.contains(where: {
                  $0.matches(vendorID: vendorID, productID: productID, serialNumber: activeDeviceSerialNumber)
              }) else { return false }
        knownDeviceIdentities.formUnion(identities)
        scheduleAutoConnect(
            isInitialScan: false,
            vendorID: vendorID,
            productID: productID,
            serialNumber: activeDeviceSerialNumber
        )
        return true
    }

    public func registerActiveDevice(vendorID: UInt16?, productID: UInt16?, serialNumber: String?) {
        activeDeviceVendorID = vendorID
        activeDeviceProductID = productID
        activeDeviceSerialNumber = serialNumber
    }

    public func clearActiveDevice() {
        activeDeviceVendorID = nil
        activeDeviceProductID = nil
        activeDeviceSerialNumber = nil
    }

    private func cleanupWatchingResources() {
        pendingAutoConnectTask?.cancel()
        pendingAutoConnectTask = nil
        _ = connectionLifecycle.detached()
        clearActiveDevice()
        knownDeviceIdentities.removeAll()
        
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
        
        let newIdentities = newlyAttachedUSBIdentities(identities, known: knownDeviceIdentities)
        knownDeviceIdentities.formUnion(identities)
        let shouldRetryKnownCandidate = newIdentities.isEmpty
            && pendingAutoConnectTask == nil
            && MTPDeviceManager.shared.isConnected == false
        guard (!newIdentities.isEmpty || shouldRetryKnownCandidate),
              activeDeviceVendorID == nil,
              activeDeviceProductID == nil else { return }
        guard UserDefaults.standard.object(forKey: "autoDetectDevice") as? Bool ?? true else { return }
        scheduleAutoConnect(isInitialScan: isInitialScan)
    }
    
    private func handleDevicesRemoved(iterator: io_iterator_t) async {
        var removedIdentities: [USBDeviceIdentity] = []
        while case let device = IOIteratorNext(iterator), device != 0 {
            if let identity = deviceIdentity(for: device) {
                removedIdentities.append(identity)
                knownDeviceIdentities.remove(identity)
            }
            IOObjectRelease(device)
        }
        
        try? await Task.sleep(nanoseconds: 50_000_000)
        let remainingIdentities = connectedDeviceIdentities()
        knownDeviceIdentities = remainingIdentities
        guard let vendorID = activeDeviceVendorID,
              let productID = activeDeviceProductID else { return }
        let matchesActiveDevice: (USBDeviceIdentity) -> Bool = {
            $0.matches(vendorID: vendorID, productID: productID, serialNumber: self.activeDeviceSerialNumber)
        }
        let removedActiveDevice = removedIdentities.contains(where: matchesActiveDevice)
        let activeDeviceIsGone = !remainingIdentities.contains(where: matchesActiveDevice)
        guard removedActiveDevice || activeDeviceIsGone else { return }

        pendingAutoConnectTask?.cancel()
        pendingAutoConnectTask = nil
        _ = connectionLifecycle.detached()
        clearActiveDevice()
        ErrorLogger.logMessage(
            "USB device detached",
            level: .info,
            userInfo: [
                "usb_event": "detach",
                "connection_state": MTPDeviceManager.shared.isConnected ? "connected" : "connecting"
            ]
        )
        MTPDeviceManager.shared.invalidateConnection(
            message: "The Android device was disconnected. Reconnect it and try again."
        )
    }

    private func scheduleAutoConnect(
        isInitialScan: Bool,
        vendorID: UInt16? = nil,
        productID: UInt16? = nil,
        serialNumber: String? = nil
    ) {
        pendingAutoConnectTask?.cancel()
        let token = connectionLifecycle.attachScheduled()
        ErrorLogger.logMessage(
            "USB device attached",
            level: .info,
            userInfo: [
                "usb_event": "attach",
                "connection_state": "pending",
                "initial_scan": isInitialScan
            ]
        )

        pendingAutoConnectTask = Task { @MainActor [weak self] in
            let delays: [UInt64] = [300_000_000, 750_000_000, 1_500_000_000]
            for delay in delays {
                try? await Task.sleep(nanoseconds: delay)
                guard !Task.isCancelled,
                      let self,
                      self.connectionLifecycle.accepts(token) else { return }
                guard !MTPDeviceManager.shared.isConnected else {
                    self.pendingAutoConnectTask = nil
                    return
                }

                let identities = self.connectedDeviceIdentities()
                if let vendorID, let productID {
                    guard identities.contains(where: {
                        $0.matches(vendorID: vendorID, productID: productID, serialNumber: serialNumber)
                    }) else { return }
                } else {
                    guard !identities.isEmpty else { return }
                }

                if await MTPDeviceManager.shared.connectDevice() {
                    guard self.connectionLifecycle.accepts(token) else { return }
                    self.pendingAutoConnectTask = nil
                    return
                }
                if MTPDeviceManager.shared.isConnected {
                    self.pendingAutoConnectTask = nil
                    return
                }
            }

            guard let self,
                  self.connectionLifecycle.accepts(token) else { return }
            self.pendingAutoConnectTask = nil
            ErrorLogger.logMessage(
                "MTP auto-connect attempts exhausted",
                level: .warning,
                userInfo: [
                    "operation": "initialize",
                    "operation_phase": "connection",
                    "reconnect_result": "attempts_exhausted"
                ]
            )
        }
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
        Array(Set(connectedDeviceIdentities().map(\.vendorID))).sorted()
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
