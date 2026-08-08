import Foundation
import IOKit
import IOKit.usb

struct USBDeviceIdentity: Hashable, Sendable {
    let vendorID: UInt16
    let productID: UInt16
    let locationID: UInt32?
    let serialNumber: String?
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
    private var activeDeviceIdentity: USBDeviceIdentity?
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
                    await watcher.handleDevicesAdded(iterator: iterator)
                }
            },
            selfPtr,
            &addedIterator
        )
        
        if addedResult != kIOReturnSuccess {
            cleanupWatchingResources()
            return
        }
        
        Task { @MainActor in
            await handleDevicesAdded(iterator: addedIterator, isInitialScan: true)
        }
        
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

    public func reconnectIfAvailable() {
        guard isWatching,
              UserDefaults.standard.object(forKey: "autoDetectDevice") as? Bool ?? true else { return }
        let identities = connectedDeviceIdentities()
        guard let identity = activeDeviceIdentity,
              identities.contains(identity) else { return }
        knownDeviceIdentities.formUnion(identities)
        activeDeviceIdentity = identity
        scheduleAutoConnect(isInitialScan: false)
    }

    private func cleanupWatchingResources() {
        pendingAutoConnectTask?.cancel()
        pendingAutoConnectTask = nil
        _ = connectionLifecycle.detached()
        activeDeviceIdentity = nil
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
    
    
    private func handleDevicesAdded(iterator: io_iterator_t, isInitialScan: Bool = false) async {
        var identities: [USBDeviceIdentity] = []
        while case let device = IOIteratorNext(iterator), device != 0 {
            if let identity = deviceIdentity(for: device) {
                identities.append(identity)
                knownDeviceIdentities.insert(identity)
                activeDeviceIdentity = activeDeviceIdentity ?? identity
            }
            IOObjectRelease(device)
        }
        
        guard !identities.isEmpty else { return }
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
        let removedActiveDevice = activeDeviceIdentity.map(removedIdentities.contains) ?? false
        let activeDeviceIsGone = activeDeviceIdentity.map { !remainingIdentities.contains($0) } ?? false
        let noTrackedDevicesRemain = remainingIdentities.isEmpty
        guard removedActiveDevice || activeDeviceIsGone || noTrackedDevicesRemain else { return }

        pendingAutoConnectTask?.cancel()
        pendingAutoConnectTask = nil
        _ = connectionLifecycle.detached()
        activeDeviceIdentity = nil
        knownDeviceIdentities = remainingIdentities
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

    private func scheduleAutoConnect(isInitialScan: Bool) {
        pendingAutoConnectTask?.cancel()
        let token = connectionLifecycle.attachScheduled()
        let identity = activeDeviceIdentity
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
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled,
                  let self,
                  self.connectionLifecycle.accepts(token),
                  let identity,
                  self.connectedDeviceIdentities().contains(identity) else { return }

            self.pendingAutoConnectTask = nil
            await MTPDeviceManager.shared.connectDevice()
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
