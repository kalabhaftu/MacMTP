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
        
        guard let port = IONotificationPortCreate(kIOMainPortDefault) else {
            return
        }
        self.notificationPort = port
        
        // Get run loop source and add to main run loop
        self.runLoopSource = IONotificationPortGetRunLoopSource(port).takeUnretainedValue()
        CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        
        // Set up matching dictionaries for USB devices
        // We match any USB device and filter inside the callback.
        // Android MTP devices typically present as USB devices.
        guard let matchingDict1 = IOServiceMatching(kIOUSBDeviceClassName),
              let matchingDict2 = IOServiceMatching(kIOUSBDeviceClassName) else {
            return
        }
        
        // Self pointer to pass to C callbacks
        let selfPtr = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        
        // 1. Register for device insertion
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
            stopWatching()
            return
        }
        
        // Arm the iterator by consuming existing terminated entries
        Task { @MainActor in
            await handleDevicesRemoved(iterator: removedIterator)
        }
        
        isWatching = true
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
    }
    
    // MARK: - Private Event Handlers
    
    private func handleDevicesAdded(iterator: io_iterator_t, isInitialScan: Bool = false) async {
        var deviceCount = 0
        while case let device = IOIteratorNext(iterator), device != 0 {
            deviceCount += 1
            IOObjectRelease(device)
        }
        
        if deviceCount > 0 {
            let autoDetect = UserDefaults.standard.object(forKey: "autoDetectDevice") as? Bool ?? true
            if autoDetect {
                if !isInitialScan {
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                }
                await MTPDeviceManager.shared.connectDevice()
            }
        }
    }
    
    private func handleDevicesRemoved(iterator: io_iterator_t) async {
        var deviceCount = 0
        while case let device = IOIteratorNext(iterator), device != 0 {
            deviceCount += 1
            IOObjectRelease(device)
        }
        
        if deviceCount > 0 {
            await verifyMtpConnection()
        }
    }
    
    private func verifyMtpConnection() async {
        guard MTPDeviceManager.shared.isConnected else { return }

        let result = try? await KalamBridge.shared.fetchStorages()
        if result == nil {
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
