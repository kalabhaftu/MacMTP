import Foundation
import IOKit
import IOKit.usb

@MainActor
public final class USBWatcher: ObservableObject, @unchecked Sendable {
    
    // MARK: - Singleton
    
    public static let shared = USBWatcher()
    
    // MARK: - Private Properties
    
    private var notificationPort: IONotificationPortRef?
    private var addedIterator: io_iterator_t = 0
    private var removedIterator: io_iterator_t = 0
    private var runLoopSource: CFRunLoopSource?
    private var isWatching = false
    
    // MARK: - Initializer
    
    private init() {}
    

    
    // MARK: - Public Methods
    
    public func startWatching() {
        guard !isWatching else { return }
        
        // Create notification port
        guard let port = IONotificationPortCreate(kIOMainPortDefault) else {
            print("USBWatcher: Failed to create IONotificationPort")
            return
        }
        self.notificationPort = port
        
        // Get run loop source and add to main run loop
        self.runLoopSource = IONotificationPortGetRunLoopSource(port).takeUnretainedValue()
        CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        
        // Set up matching dictionary for USB devices
        // We match any USB device and filter inside the callback, or match specifically.
        // Android MTP devices typically present as USB devices.
        guard let matchingDict = IOServiceMatching(kIOUSBDeviceClassName) as? [String: Any] else {
            print("USBWatcher: Failed to create matching dictionary")
            return
        }
        
        // We need to keep a copy of the matching dictionary for the second notification
        let matchingDictCopy = matchingDict as CFDictionary
        
        // Self pointer to pass to C callbacks
        let selfPtr = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        
        // 1. Register for device insertion
        let addedResult = IOServiceAddMatchingNotification(
            port,
            kIOPublishNotification,
            matchingDictCopy,
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
            print("USBWatcher: Failed to register for device insertion notifications")
            stopWatching()
            return
        }
        
        // Arm the iterator by consuming any existing devices
        Task { @MainActor in
            await handleDevicesAdded(iterator: addedIterator, isInitialScan: true)
        }
        
        // 2. Register for device removal
        let removedResult = IOServiceAddMatchingNotification(
            port,
            kIOTerminatedNotification,
            matchingDictCopy,
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
            print("USBWatcher: Failed to register for device removal notifications")
            stopWatching()
            return
        }
        
        // Arm the iterator by consuming existing terminated entries
        Task { @MainActor in
            await handleDevicesRemoved(iterator: removedIterator)
        }
        
        isWatching = true
        print("USBWatcher: Started monitoring USB ports")
    }
    
    public func stopWatching() {
        guard isWatching else { return }
        
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
        print("USBWatcher: Stopped monitoring USB ports")
    }
    
    // MARK: - Private Event Handlers
    
    private func handleDevicesAdded(iterator: io_iterator_t, isInitialScan: Bool = false) async {
        var deviceCount = 0
        while case let device = IOIteratorNext(iterator), device != 0 {
            deviceCount += 1
            
            // Get device details if needed (e.g. name, vendor, product ID)
            if let name = getDeviceName(device: device) {
                print("USBWatcher: USB Device Connected - \(name)")
            }
            
            IOObjectRelease(device)
        }
        
        // Trigger MTP scan when a new USB device is connected (skip initial scan to avoid double connection at launch)
        if deviceCount > 0 && !isInitialScan {
            print("USBWatcher: USB device change detected, scanning MTP devices...")
            // Wait briefly for the device descriptor to settle
            try? await Task.sleep(nanoseconds: 1_000_000_000) // 1 second
            await MTPDeviceManager.shared.connectDevice()
        }
    }
    
    private func handleDevicesRemoved(iterator: io_iterator_t) async {
        var deviceCount = 0
        while case let device = IOIteratorNext(iterator), device != 0 {
            deviceCount += 1
            if let name = getDeviceName(device: device) {
                print("USBWatcher: USB Device Disconnected - \(name)")
            }
            IOObjectRelease(device)
        }
        
        if deviceCount > 0 {
            print("USBWatcher: USB device removal detected, checking MTP connection...")
            // Verify if device is still accessible, if not disconnect
            // MTPDeviceManager will check connection or disconnect
            await verifyMtpConnection()
        }
    }
    
    private func verifyMtpConnection() async {
        guard MTPDeviceManager.shared.isConnected else { return }

        let result = try? await KalamBridge.shared.fetchStorages()
        if result == nil {
            print("USBWatcher: Active MTP device is no longer reachable. Disconnecting...")
            await MTPDeviceManager.shared.disconnectDevice()
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
}
