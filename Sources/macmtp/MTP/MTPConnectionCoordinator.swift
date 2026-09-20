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
        case .deviceFound: return "Checking for an MTP interface…"
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
    private var connectionTask: Task<Void, Never>?
    private var discoveryTask: Task<Void, Never>?
    private var pendingEmptyAvailabilityTask: Task<Void, Never>?

    private init() {}

    func updateAvailableDevices(_ devices: Set<USBDeviceIdentity>, startAutomatically: Bool = true) {
        if devices.isEmpty {
            pendingEmptyAvailabilityTask?.cancel()
            pendingEmptyAvailabilityTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 400_000_000)
                guard let self, self.usbDevicePresent else { return }
                self.usbDevicePresent = false
                self.availableDevices.removeAll()
                self.generation &+= 1
                self.discoveryTask?.cancel()
                self.discoveryTask = nil
                self.connectionTask?.cancel()
                self.connectionTask = nil
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
        guard connectionTask == nil, discoveryTask == nil else { return }
        if case .failed = state { return }
        state = .deviceFound
        startDiscovery()
    }

    func retry() {
        generation &+= 1
        connectionTask?.cancel()
        connectionTask = nil
        discoveryTask?.cancel()
        discoveryTask = nil
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
        connectionTask?.cancel()
        connectionTask = nil
        state = .failed(message: message, technicalDetails: message)
    }

    private func startDiscovery() {
        guard discoveryTask == nil else { return }
        let token = generation
        discoveryTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.discoveryTask = nil }

            do {
                let selectors = Set(try await MTPDeviceManager.shared.discoverMTPDevices())
                guard self.generation == token, !Task.isCancelled else { return }
                self.availableDevices = selectors
                ErrorLogger.logMessage(
                    "MTP candidate discovery completed",
                    level: .info,
                    userInfo: [
                        "event": "mtp_probe",
                        "state": selectors.isEmpty ? "mtp_unavailable" : "mtp_candidate_found",
                        "candidate_count": selectors.count,
                        "generation": Int64(token)
                    ]
                )
                guard !selectors.isEmpty else {
                    self.state = .failed(
                        message: "USB device detected, but no MTP interface is available. Select File Transfer (MTP) on the phone, then Retry.",
                        technicalDetails: "Native MTP descriptor discovery returned zero candidates."
                    )
                    return
                }
                guard selectors.count == 1 else {
                    self.state = .failed(
                        message: "Multiple MTP devices detected. Disconnect all but one device, then Retry.",
                        technicalDetails: "Native MTP descriptor discovery returned \(selectors.count) candidates."
                    )
                    return
                }
                self.startConnection()
            } catch {
                guard self.generation == token, !Task.isCancelled else { return }
                self.state = .failed(
                    message: "MTP discovery failed: \(error.localizedDescription)",
                    technicalDetails: error.localizedDescription
                )
            }
        }
    }

    private func startConnection() {
        guard connectionTask == nil,
              availableDevices.count == 1,
              let identity = availableDevices.first else { return }

        let token = generation
        connectionTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.connectionTask = nil }

            for attempt in 1...2 {
                guard self.generation == token,
                      !Task.isCancelled,
                      self.availableDevices.contains(identity) else { return }

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

                if await MTPDeviceManager.shared.connectDevice(selector: identity.selector) {
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
                    self.state = .failed(
                        message: message,
                        technicalDetails: message
                    )
                    return
                }

                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }
    }
}

extension USBDeviceIdentity {
    var selector: MTPDeviceSelector {
        MTPDeviceSelector(
            vendorId: vendorID,
            productId: productID,
            serialNumber: serialNumber?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        )
    }
}
