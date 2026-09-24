import Foundation

func mergeMTPSelectors(
    discovered: Set<MTPDeviceSelector>,
    active: MTPDeviceSelector?,
    activeConnected: Bool,
    failed: Set<MTPDeviceSelector>,
    inventory: Set<USBDeviceIdentity>
) -> Set<MTPDeviceSelector> {
    var merged = discovered
    if activeConnected, let active, selectorIsPresent(active, in: inventory) {
        merged.insert(active)
    }
    for selector in failed where selectorIsPresent(selector, in: inventory) {
        if selector.serialNumber.isEmpty,
           merged.contains(where: { $0.vendorId == selector.vendorId && $0.productId == selector.productId }) {
            continue
        }
        if !selector.serialNumber.isEmpty {
            merged = Set(merged.filter {
                !($0.vendorId == selector.vendorId && $0.productId == selector.productId && $0.serialNumber.isEmpty)
            })
        }
        merged.insert(selector)
    }
    return merged
}

func orderedMTPConnectionCandidates(
    _ selectors: [MTPDeviceSelector],
    failed: Set<MTPDeviceSelector>
) -> [MTPDeviceSelector] {
    let ordered = selectors.sorted { lhs, rhs in
        let nameOrder = lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName)
        if nameOrder != .orderedSame { return nameOrder == .orderedAscending }
        if lhs.vendorId != rhs.vendorId { return lhs.vendorId < rhs.vendorId }
        if lhs.productId != rhs.productId { return lhs.productId < rhs.productId }
        return lhs.serialNumber < rhs.serialNumber
    }
    return ordered.filter { !failed.contains($0) } + ordered.filter { failed.contains($0) }
}

func mtpRecoveryDelayNanoseconds(attempt: Int) -> UInt64 {
    attempt <= 1 ? 2_000_000_000 : 4_000_000_000
}

private func selectorIsPresent(_ selector: MTPDeviceSelector, in inventory: Set<USBDeviceIdentity>) -> Bool {
    inventory.contains {
        $0.matches(
            vendorID: selector.vendorId,
            productID: selector.productId,
            serialNumber: selector.serialNumber
        )
    }
}

public enum MTPConnectionState: Equatable {
    case usbAbsent
    case deviceFound
    case connecting(attempt: Int)
    case connected
    case failed(message: String, technicalDetails: String)

    var title: String {
        switch self {
        case .usbAbsent: return "USB device not connected"
        case .deviceFound: return "USB device detected"
        case .connecting(let attempt): return "Connecting, attempt \(attempt) of 2"
        case .connected: return "Connected"
        case .failed: return "Connection failed"
        }
    }

    var detail: String {
        switch self {
        case .usbAbsent: return "Connect an Android device and select File Transfer (MTP)."
        case .deviceFound: return "USB device detected, but MTP is not ready. Select File Transfer (MTP) on the phone, then Retry."
        case .connecting: return "Opening the MTP session…"
        case .connected: return "Connected via USB"
        case .failed(let message, _): return message
        }
    }
}

@MainActor
final class MTPConnectionCoordinator: ObservableObject {
    static let shared = MTPConnectionCoordinator()

    @Published private(set) var state: MTPConnectionState = .usbAbsent
    @Published private(set) var availableMTPDevices: [MTPDeviceSelector] = []

    private var availableDevices: Set<MTPDeviceSelector> = []
    private var usbDevicePresent = false
    private var generation: UInt64 = 0
    private var discoveryTask: Task<Void, Never>?
    private var pendingEmptyAvailabilityTask: Task<Void, Never>?
    private var lastUSBInventory: Set<USBDeviceIdentity> = []
    private var claimantRecoveryUsed = false
    private var failedSelectors: Set<MTPDeviceSelector> = []

    private init() {}

    func updateAvailableDevices(_ devices: Set<USBDeviceIdentity>, startAutomatically: Bool = true) {
        let hasNewDevice = !newlyAttachedUSBIdentities(Array(devices), known: lastUSBInventory).isEmpty
        guard usbInventoryChanged(previous: lastUSBInventory, current: devices) else { return }
        lastUSBInventory = devices
        if devices.isEmpty {
            pendingEmptyAvailabilityTask?.cancel()
            pendingEmptyAvailabilityTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 400_000_000)
                guard let self, self.usbDevicePresent else { return }
                self.usbDevicePresent = false
                self.availableDevices.removeAll()
                self.availableMTPDevices.removeAll()
                self.failedSelectors.removeAll()
                self.lastUSBInventory.removeAll()
                self.generation &+= 1
                self.discoveryTask?.cancel()
                self.discoveryTask = nil
                self.state = .usbAbsent
                ErrorLogger.logMessage(
                    "USB device lost",
                    level: .warning,
                    userInfo: [
                        "event": "usb_lost",
                        "state": "usb_absent",
                        "generation": Int64(self.generation)
                    ]
                )
                if MTPDeviceManager.shared.isConnected || MTPDeviceManager.shared.isLoading {
                    MTPDeviceManager.shared.invalidateConnection(
                        message: "The Android device was disconnected."
                    )
                }
                self.pendingEmptyAvailabilityTask = nil
            }
            return
        }

        usbDevicePresent = true
        claimantRecoveryUsed = false
        pendingEmptyAvailabilityTask?.cancel()
        pendingEmptyAvailabilityTask = nil
        failedSelectors = failedSelectors.filter { selectorIsPresent($0, in: devices) }

        if let active = MTPDeviceManager.shared.activeSelector,
           MTPDeviceManager.shared.isConnected,
           !devices.contains(where: {
               $0.matches(
                   vendorID: active.vendorId,
                   productID: active.productId,
                   serialNumber: active.serialNumber
               )
           }) {
            MTPDeviceManager.shared.invalidateConnection(
                message: "The active Android device was disconnected.",
                reconnectAutomatically: true
            )
            return
        }

        guard startAutomatically else {
            state = MTPDeviceManager.shared.isConnected ? .connected : .deviceFound
            return
        }
        guard discoveryTask == nil else { return }
        if case .failed = state, !hasNewDevice, !MTPDeviceManager.shared.isConnected { return }
        state = .deviceFound
        startDiscovery()
    }

    func refreshAvailableDevices() {
        guard usbDevicePresent, discoveryTask == nil else { return }
        startDiscovery()
    }

    func switchToDevice(_ selector: MTPDeviceSelector) {
        guard availableDevices.contains(selector), discoveryTask == nil else { return }
        generation &+= 1
        let token = generation
        let previousSelector = MTPDeviceManager.shared.activeSelector
        state = .connecting(attempt: 1)
        discoveryTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.generation == token {
                    self.discoveryTask = nil
                }
            }
            let connected = await MTPDeviceManager.shared.switchDevice(to: selector)
            guard self.generation == token, !Task.isCancelled else { return }
            if connected {
                self.failedSelectors.remove(selector)
                self.state = .connected
            } else {
                self.failedSelectors.insert(selector)
                if let previousSelector,
                   previousSelector != selector,
                   selectorIsPresent(previousSelector, in: self.lastUSBInventory),
                   await MTPDeviceManager.shared.switchDevice(to: previousSelector) {
                    self.state = .connected
                    return
                }
                let message = MTPDeviceManager.shared.errorMessage ?? "The MTP session could not be opened."
                self.state = .failed(message: message, technicalDetails: message)
            }
        }
    }

    func retry() {
        guard !MTPDeviceManager.shared.isConnectionRecoveryInFlight else { return }
        guard !FileTransferService.shared.isTransferInFlight else {
            state = .failed(
                message: "The previous transfer is still cancelling. Try again when cleanup finishes.",
                technicalDetails: "MTP transfer cleanup is still in flight."
            )
            return
        }
        if MTPDeviceManager.shared.isConnected {
            state = .connected
            Task { @MainActor in
                await MTPDeviceManager.shared.refreshFiles()
            }
            return
        }

        generation &+= 1
        discoveryTask?.cancel()
        discoveryTask = nil
        claimantRecoveryUsed = false
        guard usbDevicePresent else {
            state = .usbAbsent
            return
        }
        state = .deviceFound
        startDiscovery()
    }

    func markSessionLost(message: String, failedSelector: MTPDeviceSelector? = nil) {
        generation &+= 1
        discoveryTask?.cancel()
        discoveryTask = nil
        if let failedSelector {
            failedSelectors.insert(failedSelector)
        }
        state = .failed(message: message, technicalDetails: message)
    }

    private func startDiscovery() {
        guard discoveryTask == nil else { return }
        let token = generation
        discoveryTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.generation == token {
                    self.discoveryTask = nil
                }
            }

            let maxAttempts = MTPDeviceManager.shared.isConnected ? 1 : 2
            for attempt in 1...maxAttempts {
                guard self.generation == token, !Task.isCancelled else { return }
                let passiveProbe = MTPDeviceManager.shared.isConnected
                if !passiveProbe, !self.failedSelectors.isEmpty {
                    try? await Task.sleep(nanoseconds: mtpRecoveryDelayNanoseconds(attempt: attempt))
                    guard self.generation == token, !Task.isCancelled else { return }
                }
                if !passiveProbe {
                    self.state = .connecting(attempt: attempt)
                    ErrorLogger.logMessage(
                        "MTP connection attempt",
                        level: .info,
                        userInfo: [
                            "event": "connection_attempt",
                            "state": "connecting",
                            "generation": Int64(token),
                            "attempt": attempt
                        ]
                    )
                }
                ErrorLogger.logMessage(
                    "MTP probe started",
                    level: .info,
                    userInfo: [
                        "event": passiveProbe ? "mtp_inventory_probe_started" : "mtp_probe_started",
                        "state": passiveProbe ? "connected" : "connecting",
                        "generation": Int64(token),
                        "attempt": attempt
                    ]
                )

                do {
                    let selectors = Set(try await MTPDeviceManager.shared.discoverMTPDevices())
                    guard self.generation == token, !Task.isCancelled else { return }
                    let mergedSelectors = mergeMTPSelectors(
                        discovered: selectors,
                        active: MTPDeviceManager.shared.activeSelector,
                        activeConnected: MTPDeviceManager.shared.isConnected,
                        failed: self.failedSelectors,
                        inventory: self.lastUSBInventory
                    )
                    self.availableDevices = mergedSelectors
                    self.availableMTPDevices = self.sortSelectors(Array(mergedSelectors))
                    ErrorLogger.logMessage(
                        "MTP candidate discovery completed",
                        level: .info,
                        userInfo: [
                            "event": "mtp_probe_result",
                            "state": mergedSelectors.isEmpty ? "mtp_unavailable" : "mtp_candidate_found",
                            "candidate_count": mergedSelectors.count,
                            "candidate_vid_pids": mergedSelectors
                                .map { String(format: "0x%04x:0x%04x", $0.vendorId, $0.productId) }
                                .joined(separator: ","),
                            "generation": Int64(token),
                            "attempt": attempt
                        ]
                    )

                    if passiveProbe {
                        self.state = .connected
                        return
                    }

                    if mergedSelectors.isEmpty {
                        if MTPDeviceManager.shared.isConnected {
                            self.state = .connected
                            return
                        }
                        guard attempt == 1 else {
                            self.state = .deviceFound
                            return
                        }
                        try? await Task.sleep(nanoseconds: 250_000_000)
                        continue
                    }

                    let orderedSelectors = self.sortSelectors(Array(mergedSelectors))
                    guard !orderedSelectors.isEmpty else { return }

                    let candidates = orderedMTPConnectionCandidates(orderedSelectors, failed: self.failedSelectors)
                    let connected = await self.connectFirstAvailable(candidates, token: token)

                    if connected {
                        guard self.generation == token else { return }
                        self.state = .connected
                        ErrorLogger.logMessage(
                            "MTP connection established",
                            level: .info,
                            userInfo: [
                                "event": "connection_ready",
                                "state": "connected",
                                "generation": Int64(token),
                                "attempt": attempt,
                                "selected_vid_pid": MTPDeviceManager.shared.activeSelector.map {
                                    String(format: "0x%04x:0x%04x", $0.vendorId, $0.productId)
                                } ?? "unknown"
                            ]
                        )
                        return
                    }

                    guard attempt == 1,
                          self.generation == token,
                          !Task.isCancelled,
                          MTPDeviceManager.shared.canRetryConnection else {
                        let message = MTPDeviceManager.shared.errorMessage ?? "The MTP session could not be opened."
                        self.state = .failed(message: message, technicalDetails: message)
                        return
                    }
                    self.releaseMTPInterfaceClaimantsIfNeeded()
                } catch {
                    guard self.generation == token, !Task.isCancelled else { return }
                    ErrorLogger.logMessage(
                        "MTP probe failed",
                        level: .warning,
                        userInfo: [
                            "event": "mtp_probe_result",
                            "state": "probe_failed",
                            "generation": Int64(token),
                            "attempt": attempt,
                            "native_error_type": nativeErrorType(for: error),
                            "phase": "discovery"
                        ]
                    )
                    if passiveProbe {
                        self.state = .connected
                        return
                    }
                    let retained = self.sortSelectors(self.failedSelectors.filter {
                        selectorIsPresent($0, in: self.lastUSBInventory)
                    })
                    if !retained.isEmpty,
                       await self.connectFirstAvailable(retained, token: token) {
                        self.state = .connected
                        return
                    }
                    guard attempt == 1, isTransientProbeFailure(error) else {
                        self.state = .failed(
                            message: "MTP discovery failed: \(error.localizedDescription)",
                            technicalDetails: error.localizedDescription
                        )
                        return
                    }
                    self.releaseMTPInterfaceClaimantsIfNeeded()
                }

            }
        }
    }

    private func connectFirstAvailable(_ candidates: [MTPDeviceSelector], token: UInt64) async -> Bool {
        for candidate in candidates {
            guard generation == token, !Task.isCancelled else { return false }
            if await MTPDeviceManager.shared.switchDevice(to: candidate) {
                failedSelectors.remove(candidate)
                return true
            }
            failedSelectors.insert(candidate)
        }
        return false
    }

    private func isTransientProbeFailure(_ error: Error) -> Bool {
        let details = error.localizedDescription.lowercased()
        return details.contains("libusb_error_timeout")
            || details.contains("libusb_error_io")
            || details.contains("libusb_error_busy")
            || details.contains("libusb_error_access")
            || details.contains("libusb_error_not_found")
            || details.contains("eof")
            || details.contains("sessionalreadyopened")
            || details.contains("session already open")
            || details.contains("malformed")
            || details.contains("stale")
            || details.contains("unexpected data")
            || details.contains("transaction id mismatch")
            || details.contains("got type")
    }

    private func sortSelectors(_ selectors: [MTPDeviceSelector]) -> [MTPDeviceSelector] {
        selectors.sorted {
            let nameOrder = $0.displayName.localizedCaseInsensitiveCompare($1.displayName)
            if nameOrder != .orderedSame { return nameOrder == .orderedAscending }
            if $0.vendorId != $1.vendorId { return $0.vendorId < $1.vendorId }
            if $0.productId != $1.productId { return $0.productId < $1.productId }
            return $0.serialNumber < $1.serialNumber
        }
    }

    private func releaseMTPInterfaceClaimantsIfNeeded() {
        guard !claimantRecoveryUsed else { return }
        claimantRecoveryUsed = true
        releaseMTPInterfaceClaimants()
    }

    private func releaseMTPInterfaceClaimants() {
        let names = ["ptpcamerad", "mscamerad-xpc"]
        var released: [String] = []

        for name in names {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
            process.arguments = ["-9", "-x", name]
            do {
                try process.run()
                process.waitUntilExit()
                if process.terminationStatus == 0 {
                    released.append(name)
                }
            } catch {
                ErrorLogger.logMessage(
                    "Failed to release MTP interface claimant",
                    level: .warning,
                    userInfo: [
                        "event": "mtp_claimant_release_failed",
                        "process": name,
                        "details": error.localizedDescription
                    ]
                )
            }
        }

        ErrorLogger.logMessage(
            "Released macOS MTP interface claimants",
            level: .info,
            userInfo: [
                "event": "mtp_claimant_release",
                "released": released
            ]
        )
    }
}
