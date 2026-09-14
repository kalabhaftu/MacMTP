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

@Test
func fallbackUpdateURLMatchesPublished171UniversalAssetName() {
    #expect(
        fallbackUpdateDMGURL(for: "v1.7.1")?.absoluteString
            == "https://github.com/kalabhaftu/MacMTP/releases/download/v1.7.1/macMTP-1.7.1-mac-universal.dmg"
    )
    #expect(
        fallbackUpdateDMGURL(for: "1.7.1")?.absoluteString
            == "https://github.com/kalabhaftu/MacMTP/releases/download/1.7.1/macMTP-1.7.1-mac-universal.dmg"
    )
}

@Test
func versionComparisonCorrectlyDetectsUpgradeFrom170To171() {
    let local170 = normalizedVersion("1.7.0")
    let remote171 = normalizedVersion("v1.7.1")
    #expect(remote171.compare(local170, options: .numeric) == .orderedDescending)

    let local171 = normalizedVersion("1.7.1")
    #expect(remote171.compare(local171, options: .numeric) == .orderedSame)

    let remote172 = normalizedVersion("v1.7.2")
    #expect(remote172.compare(local171, options: .numeric) == .orderedDescending)
}

@Test
func universalDMGAssetMatchesPublishedReleaseArtifacts() {
    let assets: [[String: Any]] = [
        ["name": "macMTP-1.7.1-mac-arm64.dmg", "browser_download_url": "https://example.com/arm64.dmg"],
        ["name": "macMTP-1.7.1-mac-universal.dmg", "browser_download_url": "https://example.com/universal.dmg"],
        ["name": "macMTP-1.7.1-mac-x86_64.dmg", "browser_download_url": "https://example.com/x86_64.dmg"],
        ["name": "SHA256SUMS.txt", "browser_download_url": "https://example.com/sums.txt"],
        ["name": "latest-mac.yml", "browser_download_url": "https://example.com/latest.yml"]
    ]

    let dmgAsset = assets.first { ($0["name"] as? String ?? "").hasSuffix("-universal.dmg") } ??
                   assets.first { ($0["name"] as? String ?? "").hasSuffix(".dmg") }

    #expect(dmgAsset?["name"] as? String == "macMTP-1.7.1-mac-universal.dmg")
    #expect(dmgAsset?["browser_download_url"] as? String == "https://example.com/universal.dmg")
}

