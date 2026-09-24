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
