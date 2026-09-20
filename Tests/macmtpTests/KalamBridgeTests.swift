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
func lateDoneCallbackAfterContinuationCleanupIsIgnored() async {
    do {
        _ = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
            KalamRegistry.shared.setDoneContinuation(continuation)
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
