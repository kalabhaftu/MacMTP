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
    #expect(!queued.markStarted(operationID: "walk-stale", at: 50))
    #expect(!queued.timeoutIfExpired(
        operationID: "walk-current",
        now: 500,
        timeout: 401,
        includeQueueWait: true
    ))
    #expect(queued.timeoutIfExpired(
        operationID: "walk-current",
        now: 501,
        timeout: 401,
        includeQueueWait: true
    ))

    var startedAtDeadline = DoneOperationActivity()
    startedAtDeadline.begin(operationID: "walk-current", at: 100)
    #expect(startedAtDeadline.markStarted(operationID: "walk-current", at: 500))
    #expect(!startedAtDeadline.timeoutIfExpired(
        operationID: "walk-current",
        now: 501,
        timeout: 401,
        includeQueueWait: true
    ))
    #expect(!startedAtDeadline.hasWaitedToStartTooLong(
        operationID: "walk-current",
        now: 10_000,
        timeout: 1
    ))

    var active = DoneOperationActivity()
    active.begin(operationID: "walk-current", at: 100)
    #expect(active.markStarted(operationID: "walk-current", at: 100))
    #expect(!active.record(operationID: "walk-stale", at: 600))
    #expect(active.record(operationID: "walk-current", at: 600))
    #expect(!active.timeoutIfExpired(
        operationID: "walk-current",
        now: 700,
        timeout: 401,
        includeQueueWait: true
    ))
    #expect(active.timeoutIfExpired(
        operationID: "walk-current",
        now: 1_001,
        timeout: 401,
        includeQueueWait: true
    ))
    #expect(!active.markStarted(operationID: "walk-current", at: 10_001))
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
