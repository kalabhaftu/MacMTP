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
