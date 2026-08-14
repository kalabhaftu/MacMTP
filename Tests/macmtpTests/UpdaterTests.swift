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
