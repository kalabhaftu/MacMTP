import Foundation
import IOKit
import IOKit.usb

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

    private func cleanupWatchingResources() {
        pendingAutoConnectTask?.cancel()
        pendingAutoConnectTask = nil
        _ = connectionLifecycle.detached()
        
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
        var deviceCount = 0
        while case let device = IOIteratorNext(iterator), device != 0 {
            deviceCount += 1
            IOObjectRelease(device)
        }
        
        guard deviceCount > 0 else { return }
        guard UserDefaults.standard.object(forKey: "autoDetectDevice") as? Bool ?? true else { return }
        scheduleAutoConnect(isInitialScan: isInitialScan)
    }
    
    private func handleDevicesRemoved(iterator: io_iterator_t) async {
        var deviceCount = 0
        while case let device = IOIteratorNext(iterator), device != 0 {
            deviceCount += 1
            IOObjectRelease(device)
        }
        
        guard deviceCount > 0, getConnectedAndroidVendorIDs().isEmpty else { return }

        pendingAutoConnectTask?.cancel()
        pendingAutoConnectTask = nil
        _ = connectionLifecycle.detached()
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
                  !self.getConnectedAndroidVendorIDs().isEmpty else { return }

            self.pendingAutoConnectTask = nil
            await MTPDeviceManager.shared.connectDevice()
        }
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
        guard let matchingDict = IOServiceMatching(kIOUSBDeviceClassName) as? [String: Any] else {
            return []
        }

        var iterator: io_iterator_t = 0
        let result = IOServiceGetMatchingServices(kIOMainPortDefault, matchingDict as CFDictionary, &iterator)

        if result != kIOReturnSuccess {
            return []
        }
        defer { IOObjectRelease(iterator) }

        var vids: [UInt16] = []
        while case let device = IOIteratorNext(iterator), device != 0 {
            defer { IOObjectRelease(device) }

            if let vendorIDNum = IORegistryEntryCreateCFProperty(device, "idVendor" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? NSNumber {
                vids.append(vendorIDNum.uint16Value)
            }
        }
        return vids
    }
}
