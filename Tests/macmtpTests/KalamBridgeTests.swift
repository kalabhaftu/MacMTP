import Foundation
import Testing
@testable import macmtp

@Test
func malformedTransferCallbacksFailInsteadOfDisappearing() {
    #expect(throws: KalamError.self) {
        try decodeMTPPreprocessCallback("not-json")
    }
    #expect(throws: KalamError.self) {
        try decodeMTPProgressCallback(#"{"error":"","errorType":"","data":null}"#)
    }
}

@Test
func completedNativeCancellationIsNotRearmedByTheBridge() {
    let cancellation = KalamError.nativeOperationFailed(
        operation: "transfer",
        errorType: "ErrorTransferCancelled",
        message: "transfer cancelled"
    )

    #expect(!shouldSignalNativeCancellation(after: cancellation))
    #expect(shouldSignalNativeCancellation(after: KalamError.timedOut("upload")))
}

@Test
func transferWatchdogUsesInactivityInsteadOfWallClockAge() {
    #expect(!transferActivityExpired(lastActivity: 100, now: 500, timeout: 401))
    #expect(transferActivityExpired(lastActivity: 100, now: 501, timeout: 401))
    #expect(!transferActivityExpired(lastActivity: 600, now: 500, timeout: 1))
}

@Test
func directoryWalkActivityOnlyRefreshesItsMatchingOperation() {
    var queued = DoneOperationActivity()
    queued.begin(operationID: "walk-current", at: 100)
    let staleStartAccepted = queued.markStarted(operationID: "walk-stale", at: 50)
    #expect(!staleStartAccepted)
    let queuedExpiredBeforeDeadline = queued.timeoutIfExpired(
        operationID: "walk-current",
        now: 500,
        timeout: 401,
        includeQueueWait: true
    )
    #expect(!queuedExpiredBeforeDeadline)
    let queuedExpiredAtDeadline = queued.timeoutIfExpired(
        operationID: "walk-current",
        now: 501,
        timeout: 401,
        includeQueueWait: true
    )
    #expect(queuedExpiredAtDeadline)

    var startedAtDeadline = DoneOperationActivity()
    startedAtDeadline.begin(operationID: "walk-current", at: 100)
    let markedStarted = startedAtDeadline.markStarted(operationID: "walk-current", at: 500)
    #expect(markedStarted)
    let activeExpiredImmediately = startedAtDeadline.timeoutIfExpired(
        operationID: "walk-current",
        now: 501,
        timeout: 401,
        includeQueueWait: true
    )
    #expect(!activeExpiredImmediately)
    #expect(!startedAtDeadline.hasWaitedToStartTooLong(
        operationID: "walk-current",
        now: 10_000,
        timeout: 1
    ))

    var active = DoneOperationActivity()
    active.begin(operationID: "walk-current", at: 100)
    let activeStartAccepted = active.markStarted(operationID: "walk-current", at: 100)
    #expect(activeStartAccepted)
    let staleActivityAccepted = active.record(operationID: "walk-stale", at: 600)
    #expect(!staleActivityAccepted)
    let currentActivityAccepted = active.record(operationID: "walk-current", at: 600)
    #expect(currentActivityAccepted)
    let activeExpiredBeforeDeadline = active.timeoutIfExpired(
        operationID: "walk-current",
        now: 700,
        timeout: 401,
        includeQueueWait: true
    )
    #expect(!activeExpiredBeforeDeadline)
    let activeExpiredAtDeadline = active.timeoutIfExpired(
        operationID: "walk-current",
        now: 1_001,
        timeout: 401,
        includeQueueWait: true
    )
    #expect(activeExpiredAtDeadline)
    let staleStartAfterTimeout = active.markStarted(operationID: "walk-current", at: 10_001)
    #expect(!staleStartAfterTimeout)
}

@Test
func directoryWatchdogTimeoutAndNativeCompletionHaveOneWinner() async {
    let timedOutRegistry = KalamRegistry()
    do {
        _ = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
            timedOutRegistry.setDoneContinuation(continuation, operationID: "walk-timeout")
            #expect(timedOutRegistry.markDoneOperationStarted(operationID: "walk-timeout"))
            #expect(timedOutRegistry.timeoutDoneIfExpired(
                operationID: "walk-timeout",
                timeout: 0,
                includeQueueWait: true,
                error: KalamError.timedOut("list_directory")
            ))
            #expect(!timedOutRegistry.markDoneOperationStarted(operationID: "walk-timeout"))
            timedOutRegistry.resolveDone(with: #"{"operationId":"walk-timeout","data":true}"#)
        }
        Issue.record("Expected the timeout to win")
    } catch let error as KalamError {
        #expect(error.localizedDescription.contains("timed out"))
    } catch {
        Issue.record("Unexpected continuation error: \(error)")
    }

    let completedRegistry = KalamRegistry()
    do {
        let response = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
            completedRegistry.setDoneContinuation(continuation, operationID: "walk-complete")
            #expect(completedRegistry.markDoneOperationStarted(operationID: "walk-complete"))
            completedRegistry.resolveDone(with: #"{"operationId":"walk-complete","data":true}"#)
            #expect(!completedRegistry.timeoutDoneIfExpired(
                operationID: "walk-complete",
                timeout: 0,
                includeQueueWait: true,
                error: KalamError.timedOut("list_directory")
            ))
        }
        #expect(response.contains("\"data\":true"))
    } catch {
        Issue.record("Expected the native completion to win, got: \(error)")
    }
}

@Test
func repeatedCachedProgressDoesNotCountAsTransferActivity() {
    #expect(transferActivityAdvanced(previousPayload: nil, currentPayload: "first"))
    #expect(!transferActivityAdvanced(previousPayload: "same", currentPayload: "same"))
    #expect(transferActivityAdvanced(previousPayload: "old", currentPayload: "new"))
}

@Test
func transferCompletionWaitsForNativeReturnAndTerminalResult() {
    #expect(!nativeTransferCanFinish(nativeReturned: false, hasResult: true))
    #expect(!nativeTransferCanFinish(nativeReturned: true, hasResult: false))
    #expect(nativeTransferCanFinish(nativeReturned: true, hasResult: true))
}

@Suite(.serialized)
struct KalamSharedRegistryTests {
    @Test
    func lateDoneCallbackAfterContinuationCleanupIsIgnored() async {
        do {
            _ = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
                KalamRegistry.shared.setDoneContinuation(continuation, operationID: "test")
                KalamRegistry.shared.rejectDone(with: KalamError.timedOut("test"))
            }
            Issue.record("Expected the cleaned continuation to fail")
        } catch let error as KalamError {
            #expect(error.localizedDescription.contains("timed out"))
        } catch {
            Issue.record("Unexpected continuation error: \(error)")
        }

        KalamRegistry.shared.resolveDone(with: #"{"data":true}"#)
    }

    @Test
    func callbackForAnotherOperationCannotResumeTheActiveContinuation() async {
        do {
            _ = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
                KalamRegistry.shared.setDoneContinuation(continuation, operationID: "current")
                KalamRegistry.shared.resolveDone(with: #"{"operationId":"late","data":true}"#)
                KalamRegistry.shared.rejectDone(with: KalamError.timedOut("current"))
            }
            Issue.record("Expected the active operation to be rejected")
        } catch let error as KalamError {
            #expect(error.localizedDescription.contains("timed out"))
        } catch {
            Issue.record("Unexpected continuation error: \(error)")
        }
    }

    @Test
    func cancelledInitializationStillRunsNativeCleanup() async throws {
        let log = NativeCommandTestLog()
        let nativeMayReturn = DispatchSemaphore(value: 0)
        let bridge = KalamBridge(doneCallbackTimeoutNanoseconds: 200_000_000)
        let task = Task {
            do {
                let _: GoSimpleResult = try await bridge.executeMTPWithInput(
                    operationName: "initialize", "test"
                ) { _ in
                    log.record("initialize")
                    if nativeMayReturn.wait(timeout: .now() + 5) == .timedOut {
                        log.record("native wait expired")
                    }
                    log.record("native returned")
                }
                Issue.record("Expected initialization to be cancelled")
            } catch {
                log.record("cleanup requested")
                try await bridge.executeMTPCleanup {
                    log.record("dispose")
                    KalamRegistry.shared.resolveDone(with: #"{"data":true}"#)
                }
                throw error
            }
        }
        defer {
            nativeMayReturn.signal()
            task.cancel()
            KalamRegistry.shared.rejectDone(with: CancellationError())
        }
        try await waitForNativeCommand("initialize", in: log)
        task.cancel()
        try await waitForNativeCommand("cleanup requested", in: log)
        try await Task.sleep(nanoseconds: 500_000_000)
        #expect(!log.contains("dispose"))
        #expect(!log.contains("native returned"))
        nativeMayReturn.signal()
        do {
            try await task.value
            Issue.record("Expected cancellation after cleanup")
        } catch is CancellationError {
            #expect(log.contains("dispose"))
            #expect(log.contains("native returned"))
            #expect(!log.contains("native wait expired"))
        }
    }

    @Test
    func cancelledCommandWaitingForTheGateDoesNotStart() async throws {
        let log = NativeCommandTestLog()
        let gate = FIFOOperationGate()
        let bridge = KalamBridge(operationGate: gate)
        let first = Task {
            let _: GoSimpleResult = try await bridge.executeMTP(operationName: "test") {
                log.record("first")
            }
        }
        defer {
            first.cancel()
            KalamRegistry.shared.rejectDone(with: CancellationError())
        }
        try await waitForNativeCommand("first", in: log)
        let queued = Task {
            let _: GoSimpleResult = try await bridge.executeMTPWithInput(
                operationName: "initialize", "test"
            ) { _ in
                log.record("unexpected initialization")
                KalamRegistry.shared.resolveDone(with: #"{"data":true}"#)
            }
        }
        defer { queued.cancel() }
        try await waitForQueuedNativeCommand(in: gate)
        queued.cancel()
        KalamRegistry.shared.resolveDone(with: #"{"data":true}"#)
        try await first.value
        do {
            try await queued.value
            Issue.record("Expected the queued command to be cancelled")
        } catch is CancellationError {
            #expect(!log.contains("unexpected initialization"))
        }
    }
}

private final class NativeCommandTestLog: @unchecked Sendable {
    private let lock = NSLock()
    private var events: Set<String> = []

    func record(_ event: String) {
        lock.withLock { _ = events.insert(event) }
    }

    func contains(_ event: String) -> Bool {
        lock.withLock { events.contains(event) }
    }
}

private func waitForNativeCommand(_ event: String, in log: NativeCommandTestLog) async throws {
    for _ in 0..<2_000 {
        if log.contains(event) { return }
        try await Task.sleep(nanoseconds: 1_000_000)
    }
    throw KalamError.timedOut("test command did not start")
}

private func waitForQueuedNativeCommand(in gate: FIFOOperationGate) async throws {
    for _ in 0..<2_000 {
        if gate.waitingCount > 0 { return }
        try await Task.sleep(nanoseconds: 1_000_000)
    }
    throw KalamError.timedOut("test command did not enter the queue")
}
