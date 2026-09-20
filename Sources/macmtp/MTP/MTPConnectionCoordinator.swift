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
        case .deviceFound: return "Android device detected"
        case .connecting(let attempt): return "Connecting, attempt \(attempt) of 2"
        case .connected: return "Connected"
        case .failed: return "Connection failed"
        }
    }

    var detail: String {
        switch self {
        case .usbAbsent: return "Connect an Android device and select File Transfer (MTP)."
        case .deviceFound: return "Starting MTP session…"
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

    private var availableDevices: Set<USBDeviceIdentity> = []
    private var generation: UInt64 = 0
    private var connectionTask: Task<Void, Never>?

    private init() {}

    func updateAvailableDevices(_ devices: Set<USBDeviceIdentity>, startAutomatically: Bool = true) {
        availableDevices = devices
        guard !devices.isEmpty else {
            generation &+= 1
            connectionTask?.cancel()
            connectionTask = nil
            state = .usbAbsent
            if MTPDeviceManager.shared.isConnected || MTPDeviceManager.shared.isLoading {
                MTPDeviceManager.shared.invalidateConnection(
                    message: "The Android device was disconnected."
                )
            }
            return
        }

        guard !MTPDeviceManager.shared.isConnected else {
            state = .connected
            return
        }
        guard startAutomatically else {
            state = .deviceFound
            return
        }
        guard connectionTask == nil else { return }
        if case .failed = state { return }
        state = .deviceFound
        startConnection()
    }

    func retry() {
        generation &+= 1
        connectionTask?.cancel()
        connectionTask = nil
        guard !availableDevices.isEmpty else {
            state = .usbAbsent
            return
        }
        state = .deviceFound
        startConnection()
    }

    func markSessionLost(message: String) {
        generation &+= 1
        connectionTask?.cancel()
        connectionTask = nil
        state = .failed(message: message, technicalDetails: message)
    }

    private func startConnection() {
        guard connectionTask == nil,
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
