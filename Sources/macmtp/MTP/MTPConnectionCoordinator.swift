import Foundation

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

    private var availableDevices: Set<MTPDeviceSelector> = []
    private var usbDevicePresent = false
    private var generation: UInt64 = 0
    private var discoveryTask: Task<Void, Never>?
    private var pendingEmptyAvailabilityTask: Task<Void, Never>?
    private var lastUSBInventory: Set<USBDeviceIdentity> = []
    private var claimantRecoveryUsed = false

    private init() {}

    func updateAvailableDevices(_ devices: Set<USBDeviceIdentity>, startAutomatically: Bool = true) {
        guard usbInventoryChanged(previous: lastUSBInventory, current: devices) else { return }
        lastUSBInventory = devices
        if devices.isEmpty {
            pendingEmptyAvailabilityTask?.cancel()
            pendingEmptyAvailabilityTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 400_000_000)
                guard let self, self.usbDevicePresent else { return }
                self.usbDevicePresent = false
                self.availableDevices.removeAll()
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

        guard !MTPDeviceManager.shared.isConnected else {
            state = .connected
            return
        }
        guard startAutomatically else {
            state = .deviceFound
            return
        }
        guard discoveryTask == nil else { return }
        if case .failed = state { return }
        state = .deviceFound
        startDiscovery()
    }

    func retry() {
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
        availableDevices.removeAll()
        state = .deviceFound
        startDiscovery()
    }

    func markSessionLost(message: String) {
        generation &+= 1
        discoveryTask?.cancel()
        discoveryTask = nil
        state = .failed(message: message, technicalDetails: message)
    }

    private func startDiscovery() {
        guard discoveryTask == nil else { return }
        let token = generation
        discoveryTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.discoveryTask = nil }

            for attempt in 1...2 {
                guard self.generation == token, !Task.isCancelled else { return }
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
                ErrorLogger.logMessage(
                    "MTP probe started",
                    level: .info,
                    userInfo: [
                        "event": "mtp_probe_started",
                        "state": "connecting",
                        "generation": Int64(token),
                        "attempt": attempt
                    ]
                )

                do {
                    let selectors = Set(try await MTPDeviceManager.shared.discoverMTPDevices())
                    guard self.generation == token, !Task.isCancelled else { return }
                    self.availableDevices = selectors
                    ErrorLogger.logMessage(
                        "MTP candidate discovery completed",
                        level: .info,
                        userInfo: [
                            "event": "mtp_probe_result",
                            "state": selectors.isEmpty ? "mtp_unavailable" : "mtp_candidate_found",
                            "candidate_count": selectors.count,
                            "candidate_vid_pids": selectors
                                .map { String(format: "0x%04x:0x%04x:%@", $0.vendorId, $0.productId, $0.serialNumber.isEmpty ? "no-serial" : $0.serialNumber) }
                                .joined(separator: ","),
                            "generation": Int64(token),
                            "attempt": attempt
                        ]
                    )

                    if selectors.isEmpty {
                        guard attempt == 1 else {
                            self.state = .deviceFound
                            return
                        }
                        try? await Task.sleep(nanoseconds: 250_000_000)
                        continue
                    }

                    guard selectors.count == 1 else {
                        self.state = .failed(
                            message: "Multiple MTP devices detected. Disconnect all but one device, then Retry.",
                            technicalDetails: "Native MTP descriptor discovery returned \(selectors.count) candidates."
                        )
                        return
                    }

                    guard let identity = selectors.first else { return }
                    if await MTPDeviceManager.shared.connectDevice(selector: identity) {
                        guard self.generation == token else { return }
                        self.state = .connected
                        ErrorLogger.logMessage(
                            "MTP connection established",
                            level: .info,
                            userInfo: [
                                "event": "connection_ready",
                                "state": "connected",
                                "generation": Int64(token),
                                "attempt": attempt
                            ]
                        )
                        return
                    }

                    guard attempt == 1,
                          self.generation == token,
                          !Task.isCancelled,
                          self.availableDevices.contains(identity),
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
                    guard attempt == 1, isTransientProbeFailure(error) else {
                        self.state = .failed(
                            message: "MTP discovery failed: \(error.localizedDescription)",
                            technicalDetails: error.localizedDescription
                        )
                        return
                    }
                    self.releaseMTPInterfaceClaimantsIfNeeded()
                }

                try? await Task.sleep(nanoseconds: 250_000_000)
            }
        }
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
            || details.contains("transaction id mismatch")
            || details.contains("got type")
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
