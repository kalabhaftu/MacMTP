import Testing
@testable import macmtp

@Test
func fallbackUpdateURLMatchesPublishedUniversalAssetName() {
    #expect(
        fallbackUpdateDMGURL(for: "v1.6.9")?.absoluteString
            == "https://github.com/kalabhaftu/MacMTP/releases/download/v1.6.9/macMTP-1.6.9-mac-universal.dmg"
    )
}

@Test
func updateDownloadErrorPreservesHTTPStatusAndSafeURL() {
    let error = UpdateDownloadError.httpStatus(
        code: 404,
        url: "https://github.com/kalabhaftu/MacMTP/releases/download/v1.6.9/macMTP-1.6.9-mac-universal.dmg"
    )

    #expect(error.localizedDescription == "Update download returned HTTP 404.")
    #expect(error.reportingContext["http_status"] as? Int == 404)
    #expect(error.reportingContext["download_url"] as? String == "https://github.com/kalabhaftu/MacMTP/releases/download/v1.6.9/macMTP-1.6.9-mac-universal.dmg")
}

@Test
@MainActor
func updaterServiceInitialStateIsNotChecking() {
    let updater = UpdaterService.shared
    #expect(!updater.isChecking)
}

@Test
func normalizedVersionExtractsSemanticVersionRegardlessOfTagPrefix() {
    #expect(normalizedVersion("v1.7.1") == "1.7.1")
    #expect(normalizedVersion("1.7.1") == "1.7.1")
    #expect(normalizedVersion("macmtp-1.7.1") == "1.7.1")
    #expect(normalizedVersion("macMTP-v1.7.1") == "1.7.1")
    #expect(normalizedVersion("macMTP 1.6.6") == "1.6.6")
    #expect(normalizedVersion("macMTP v1.6.7") == "1.6.7")
}

