import Foundation
import Testing
@testable import macmtp

private enum FakeDirectoryFailureMode {
    case failFirst
    case failFirstAfterCreating
    case failEveryAttempt
}

@MainActor
private final class FakeDirectoryBridge {
    private let failureMode: FakeDirectoryFailureMode
    private(set) var directoryExists = false
    private(set) var existenceChecks = 0
    private(set) var makeDirectoryCalls = 0

    init(failureMode: FakeDirectoryFailureMode) {
        self.failureMode = failureMode
    }

    func prepareDirectory(
        isCancelled: @escaping () -> Bool = { false },
        afterExistenceCheck: (() async -> Void)? = nil
    ) async throws {
        try await prepareMissingTransferDirectory(
            checkExists: {
                self.existenceChecks += 1
                await afterExistenceCheck?()
                return self.directoryExists
            },
            prepareParent: {},
            create: {
                self.makeDirectoryCalls += 1
                switch self.failureMode {
                case .failFirst where self.makeDirectoryCalls == 1:
                    throw deviceLockedError()
                case .failFirstAfterCreating where self.makeDirectoryCalls == 1:
                    self.directoryExists = true
                    throw deviceLockedError()
                case .failEveryAttempt:
                    throw deviceLockedError()
                default:
                    self.directoryExists = true
                }
            },
            isCancelled: isCancelled
        )
    }
}

private func deviceLockedError() -> KalamError {
    .nativeOperationFailed(
        operation: "make_directory",
        errorType: "ErrorDeviceLocked",
        message: "device is not open"
    )
}

@Test @MainActor
func transferDirectoryRecoveryReconnectsAndRetriesOnce() async throws {
    let bridge = FakeDirectoryBridge(failureMode: .failFirst)
    var reconnectCalls = 0
    var recoveryEvents: [TransferDirectoryRecoveryOutcome] = []
    var initialFailureType: String?

    let outcome = try await prepareTransferDirectoryWithRecovery(
        prepare: { try await bridge.prepareDirectory() },
        shouldRecover: shouldRecoverMTPDirectoryCreation,
        isCancelled: { false },
        reconnect: {
            reconnectCalls += 1
            return .reconnected
        },
        retryPreparation: { try await bridge.prepareDirectory() },
        onRecoveryStarted: { initialFailureType = nativeErrorType(for: $0) },
        onRecoveryFinished: { recoveryEvents.append($0) }
    )

    #expect(outcome == .recovered)
    #expect(reconnectCalls == 1)
    #expect(bridge.makeDirectoryCalls == 2)
    #expect(bridge.directoryExists)
    #expect(initialFailureType == "ErrorDeviceLocked")
    #expect(recoveryEvents == [.recovered])
}

@Test @MainActor
func transferDirectoryRecoveryReconcilesDirectoryCreatedBeforeLostResponse() async throws {
    let bridge = FakeDirectoryBridge(failureMode: .failFirstAfterCreating)
    var reconnectCalls = 0

    let outcome = try await prepareTransferDirectoryWithRecovery(
        prepare: { try await bridge.prepareDirectory() },
        shouldRecover: shouldRecoverMTPDirectoryCreation,
        isCancelled: { false },
        reconnect: {
            reconnectCalls += 1
            return .reconnected
        },
        retryPreparation: { try await bridge.prepareDirectory() }
    )

    #expect(outcome == .recovered)
    #expect(reconnectCalls == 1)
    #expect(bridge.existenceChecks == 2)
    #expect(bridge.makeDirectoryCalls == 1)
}

@Test @MainActor
func failedTransferDirectoryReconnectReportsOneFinalRecoveryOutcome() async {
    let bridge = FakeDirectoryBridge(failureMode: .failFirst)
    var retryCalls = 0

    do {
        _ = try await prepareTransferDirectoryWithRecovery(
            prepare: { try await bridge.prepareDirectory() },
            shouldRecover: shouldRecoverMTPDirectoryCreation,
            isCancelled: { false },
            reconnect: { .failed },
            retryPreparation: { retryCalls += 1; try await bridge.prepareDirectory() }
        )
        Issue.record("Expected reconnect failure")
    } catch let failure as TransferDirectoryRecoveryFailure {
        #expect(failure.outcome == .reconnectFailed)
        #expect(nativeErrorType(for: failure.underlying) == "ErrorDeviceLocked")
    } catch {
        Issue.record("Unexpected error: \(error)")
    }

    #expect(bridge.makeDirectoryCalls == 1)
    #expect(retryCalls == 0)
}

@Test @MainActor
func repeatedTransferDirectoryFailureStopsAfterOneRetry() async {
    let bridge = FakeDirectoryBridge(failureMode: .failEveryAttempt)
    var reconnectCalls = 0

    do {
        _ = try await prepareTransferDirectoryWithRecovery(
            prepare: { try await bridge.prepareDirectory() },
            shouldRecover: shouldRecoverMTPDirectoryCreation,
            isCancelled: { false },
            reconnect: {
                reconnectCalls += 1
                return .reconnected
            },
            retryPreparation: { try await bridge.prepareDirectory() }
        )
        Issue.record("Expected the retry to fail")
    } catch let failure as TransferDirectoryRecoveryFailure {
        #expect(failure.outcome == .retryFailed)
        #expect(nativeErrorType(for: failure.underlying) == "ErrorDeviceLocked")
    } catch {
        Issue.record("Unexpected error: \(error)")
    }

    #expect(reconnectCalls == 1)
    #expect(bridge.makeDirectoryCalls == 2)
}

@Test
func failedDirectoryRecoveryAlwaysStopsTheTransferQueue() {
    let deviceLocked = KalamError.nativeOperationFailed(
        operation: "make_directory",
        errorType: "ErrorDeviceLocked",
        message: "device locked"
    )
    let outcomes: [TransferDirectoryRecoveryOutcome] = [
        .deviceUnavailable,
        .storageChanged,
        .reconnectFailed,
        .retryFailed
    ]

    for outcome in outcomes {
        let failure = TransferDirectoryRecoveryFailure(underlying: deviceLocked, outcome: outcome)
        #expect(shouldStopTransferQueue(afterDirectoryPreparationError: failure))
    }
}

@Test @MainActor
func cancellationDuringTransferDirectoryRecoveryDoesNotRetry() async {
    let bridge = FakeDirectoryBridge(failureMode: .failFirst)
    var cancelled = false
    var retryCalls = 0

    do {
        _ = try await prepareTransferDirectoryWithRecovery(
            prepare: { try await bridge.prepareDirectory() },
            shouldRecover: shouldRecoverMTPDirectoryCreation,
            isCancelled: { cancelled },
            reconnect: {
                cancelled = true
                return .reconnected
            },
            retryPreparation: { retryCalls += 1; try await bridge.prepareDirectory() }
        )
        Issue.record("Expected cancellation")
    } catch is CancellationError {
        // Expected: the directory retry must not run after cancellation.
    } catch {
        Issue.record("Unexpected error: \(error)")
    }

    #expect(retryCalls == 0)
    #expect(bridge.makeDirectoryCalls == 1)
    #expect(bridge.existenceChecks == 1)
}

@Test @MainActor
func cancellationDuringRetryExistenceCheckDoesNotCreateDirectory() async {
    let bridge = FakeDirectoryBridge(failureMode: .failFirst)
    var cancelled = false

    do {
        _ = try await prepareTransferDirectoryWithRecovery(
            prepare: { try await bridge.prepareDirectory() },
            shouldRecover: shouldRecoverMTPDirectoryCreation,
            isCancelled: { cancelled },
            reconnect: { .reconnected },
            retryPreparation: {
                try await bridge.prepareDirectory(isCancelled: { cancelled }) {
                    guard bridge.existenceChecks == 2 else { return }
                    await Task { @MainActor in cancelled = true }.value
                }
            }
        )
        Issue.record("Expected cancellation during the retry existence check")
    } catch is CancellationError {
        // Cancellation after the probe must prevent the following create.
    } catch {
        Issue.record("Unexpected error: \(error)")
    }

    #expect(bridge.existenceChecks == 2)
    #expect(bridge.makeDirectoryCalls == 1)
    #expect(!bridge.directoryExists)
}
