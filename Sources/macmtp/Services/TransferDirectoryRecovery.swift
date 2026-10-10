import Foundation

enum TransferDirectoryReconnectResult: Equatable {
    case reconnected
    case deviceUnavailable
    case storageChanged
    case failed
}

enum TransferDirectoryRecoveryOutcome: String, Equatable {
    case recovered
    case deviceUnavailable = "device_unavailable"
    case storageChanged = "storage_changed"
    case reconnectFailed = "reconnect_failed"
    case retryFailed = "retry_failed"
}

struct TransferDirectoryRecoveryFailure: Error, LocalizedError {
    let underlying: Error
    let outcome: TransferDirectoryRecoveryOutcome

    var errorDescription: String? { underlying.localizedDescription }
}

func shouldStopTransferQueue(afterDirectoryPreparationError error: Error) -> Bool {
    error is TransferDirectoryRecoveryFailure
        || isMTPTransportFailure(error)
        || isTransferStorageFull(error)
}

/// Reconciles one directory at a time and checks cancellation between native
/// operations, so a cancel during an existence probe cannot start a create.
@MainActor
func prepareMissingTransferDirectory(
    checkExists: () async throws -> Bool,
    prepareParent: () async throws -> Void,
    create: () async throws -> Void,
    confirmCreated: (() async throws -> Bool)? = nil,
    isCancelled: () -> Bool
) async throws {
    guard !isCancelled() else { throw CancellationError() }
    let alreadyExists = try await checkExists()
    guard !isCancelled() else { throw CancellationError() }
    guard !alreadyExists else { return }

    try await prepareParent()
    guard !isCancelled() else { throw CancellationError() }
    try await create()
    guard !isCancelled() else { throw CancellationError() }

    if let confirmCreated {
        let wasCreated = try await confirmCreated()
        guard !isCancelled() else { throw CancellationError() }
        guard wasCreated else {
            throw KalamError.operationNotReconciled("make_directory")
        }
    }
}

/// Retries only the directory-preparation operation. Callers provide a fresh
/// reconciliation step so a directory created before a lost response is found.
@MainActor
func prepareTransferDirectoryWithRecovery(
    prepare: () async throws -> Void,
    shouldRecover: (Error) -> Bool,
    isCancelled: () -> Bool,
    reconnect: () async -> TransferDirectoryReconnectResult,
    retryPreparation: () async throws -> Void,
    onRecoveryStarted: (Error) -> Void = { _ in },
    onRecoveryFinished: (TransferDirectoryRecoveryOutcome) -> Void = { _ in }
) async throws -> TransferDirectoryRecoveryOutcome? {
    do {
        try await prepare()
        return nil
    } catch {
        let initialError = error
        guard shouldRecover(initialError) else { throw initialError }
        guard !isCancelled() else { throw CancellationError() }

        onRecoveryStarted(initialError)
        let reconnectResult = await reconnect()
        guard !isCancelled() else { throw CancellationError() }

        let failureOutcome: TransferDirectoryRecoveryOutcome
        switch reconnectResult {
        case .reconnected:
            do {
                try await retryPreparation()
                guard !isCancelled() else { throw CancellationError() }
                onRecoveryFinished(.recovered)
                return .recovered
            } catch {
                guard !isCancelled() else { throw CancellationError() }
                let failure = TransferDirectoryRecoveryFailure(
                    underlying: error,
                    outcome: .retryFailed
                )
                onRecoveryFinished(.retryFailed)
                throw failure
            }
        case .deviceUnavailable:
            failureOutcome = .deviceUnavailable
        case .storageChanged:
            failureOutcome = .storageChanged
        case .failed:
            failureOutcome = .reconnectFailed
        }

        let failure = TransferDirectoryRecoveryFailure(
            underlying: initialError,
            outcome: failureOutcome
        )
        onRecoveryFinished(failureOutcome)
        throw failure
    }
}

enum TransferTelemetryContext {
    static func sourceScanStarted(direction: TransferDirection) -> [String: Any] {
        [
            "operation": "transfer",
            "direction": direction == .localToMTP ? "local_to_mtp" : "mtp_to_local",
            "operation_phase": "source_scan"
        ]
    }

    static func make(
        direction: TransferDirection,
        fileCount: Int,
        totalBytes: Int64,
        retryCount: Int = 0,
        recoveryOutcome: String? = nil,
        phase: String? = nil,
        nativeErrorType: String? = nil
    ) -> [String: Any] {
        var context: [String: Any] = [
            "operation": "transfer",
            "direction": direction == .localToMTP ? "local_to_mtp" : "mtp_to_local",
            "file_count": fileCount,
            "total_bytes": totalBytes,
            "retry_count": retryCount
        ]
        if let recoveryOutcome {
            context["recovery_result"] = recoveryOutcome
        }
        if let phase {
            context["operation_phase"] = phase
        }
        if let nativeErrorType {
            context["native_error_type"] = nativeErrorType
        }
        return context
    }
}
