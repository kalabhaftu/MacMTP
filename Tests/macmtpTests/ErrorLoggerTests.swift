import Testing
@testable import macmtp

@Test
func sentryDSNValidationRequiresSecureCompleteEndpoint() {
    #expect(ErrorLogger.isValidDSN("https://public-key@example.ingest.sentry.io/12345"))
    #expect(!ErrorLogger.isValidDSN("http://public-key@example.ingest.sentry.io/12345"))
    #expect(!ErrorLogger.isValidDSN("https://example.ingest.sentry.io/12345"))
    #expect(!ErrorLogger.isValidDSN("https://public-key@example.ingest.sentry.io/project"))
}

@Test
func errorReportingSanitizesLocalPaths() {
    let input = "Failed at /Users/alice/Documents/private.txt and /Volumes/Phone/DCIM/photo.jpg"
    let sanitized = ErrorLogger.sanitize(input)

    #expect(!sanitized.contains("alice"))
    #expect(!sanitized.contains("Phone"))
    #expect(sanitized == "Failed at <redacted-path> and <redacted-path>")
}

@Test
func testReportResultsExplainTransportAcceptance() {
    #expect(TestReportResult.accepted.message == "Test report accepted by Sentry.")
    #expect(TestReportResult.rejected(statusCode: 403).message.contains("HTTP 403"))
    #expect(TestReportResult.unavailable.message == "Test report could not reach Sentry.")
}

@Test
func expectedMTPStatesAreNotReportedAsErrors() {
    #expect(!ErrorLogger.shouldReport(KalamError.deviceNotConnected))
    #expect(ErrorLogger.shouldReport(KalamError.operationInProgress))
    #expect(!ErrorLogger.shouldReport(KalamError.operationFailed("no MTP devices found")))
    #expect(ErrorLogger.shouldReport(KalamError.operationFailed("transaction ID mismatch")))
}

@Test
func transportFailureClassificationKeepsContentionSeparateFromBrokenSessions() {
    #expect(!isMTPTransportFailure(KalamError.operationInProgress))
    #expect(isMTPTransportFailure(KalamError.deviceNotConnected))
    #expect(isMTPTransportFailure(KalamError.operationFailed("transaction ID mismatch: got 7, expected 6")))
    #expect(isMTPTransportFailure(KalamError.transferFailed("libusb: device disconnected")))
}

@Test
func transferCompletionRequiresValidJSONAndPreservesNativeErrors() {
    guard case .success = decodeMTPTransferCompletion(#"{"data":true}"#) else {
        Issue.record("Expected a valid transfer completion")
        return
    }
    guard case .failure(let nativeError) = decodeMTPTransferCompletion(#"{"error":"transaction ID mismatch"}"#) else {
        Issue.record("Expected the native transfer error")
        return
    }
    #expect(nativeError.localizedDescription.contains("transaction ID mismatch"))

    guard case .failure(let malformedError) = decodeMTPTransferCompletion("not-json") else {
        Issue.record("Expected malformed completion to fail")
        return
    }
    #expect(malformedError is KalamError)
}

@Test
func nativeDirectoryErrorsPreserveTypeAndNeverRenderBlank() {
    let error = KalamError.nativeOperationFailed(
        operation: "list_directory",
        errorType: "ErrorListDirectory",
        message: ""
    )

    #expect(error.localizedDescription.contains("ErrorListDirectory"))
    #expect(!error.localizedDescription.hasSuffix(": "))
    #expect(shouldRetryMTPDirectory(error))
    #expect(ErrorLogger.shouldReport(error))
}

@Test
func transferCompletionRejectsMissingNativeData() {
    guard case .failure = decodeMTPTransferCompletion(#"{"error":"","errorType":"","data":null}"#) else {
        Issue.record("Expected an incomplete completion response to fail")
        return
    }
}
