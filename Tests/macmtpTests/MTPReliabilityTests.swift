import Foundation
import Testing
@testable import macmtp

private actor TestEventLog {
    private(set) var values: [String] = []

    func append(_ value: String) {
        values.append(value)
    }
}

@Test
func fifoOperationGatePreservesWaitingOrder() async {
    let gate = FIFOOperationGate()
    let log = TestEventLog()

    await gate.enter()
    let first = Task {
        await gate.enter()
        await log.append("first")
        gate.leave()
    }
    try? await Task.sleep(nanoseconds: 20_000_000)
    let second = Task {
        await gate.enter()
        await log.append("second")
        gate.leave()
    }
    try? await Task.sleep(nanoseconds: 20_000_000)
    gate.leave()

    await first.value
    await second.value
    let values = await log.values
    #expect(values == ["first", "second"])
}

@Test
func simpleMTPResponsesRequireTrueDataAndPreserveNativeErrorType() {
    do {
        try validateSimpleMTPResult(
            GoSimpleResult(error: nil, errorType: nil, data: false),
            operation: "make_directory",
            fallback: "Directory creation was not confirmed."
        )
        Issue.record("An incomplete response should fail validation")
    } catch let error as KalamError {
        #expect(error.localizedDescription.contains("Directory creation was not confirmed."))
    } catch {
        Issue.record("Unexpected error: \(error)")
    }

    do {
        try validateSimpleMTPResult(
            GoSimpleResult(error: "Already exists", errorType: "ErrorDuplicate", data: false),
            operation: "make_directory",
            fallback: "Directory creation was not confirmed."
        )
        Issue.record("A native error response should fail validation")
    } catch let error as KalamError {
        guard case .nativeOperationFailed(_, let errorType, let message) = error else {
            Issue.record("Native response was normalized to the wrong error")
            return
        }
        #expect(errorType == "ErrorDuplicate")
        #expect(message == "Already exists")
    } catch {
        Issue.record("Unexpected error: \(error)")
    }
}

@Test
func mtpFolderNamesAreTrimmedAndInvalidNamesRejected() {
    do {
        #expect(try normalizedMTPChildName("  New Folder  ") == "New Folder")
        _ = try normalizedMTPChildName("folder/name")
        Issue.record("Path separators should be rejected")
    } catch let error as KalamError {
        #expect(error.localizedDescription.contains("path separators"))
    } catch {
        Issue.record("Unexpected error: \(error)")
    }
}

@Test
func duplicateMTPFolderErrorsAreExplicit() {
    let error = KalamError.itemAlreadyExists("New Folder")
    #expect(error.localizedDescription == "A file or folder named \"New Folder\" already exists in this directory.")
    #expect(ErrorLogger.shouldReport(error) == false)
}

@Test
func refreshRequestsOnlyShareWhenStoragePathAndVisibilityMatch() {
    let request = MTPDirectoryRefreshKey(storageId: 1, path: "/", showHidden: false)
    #expect(MTPRefreshRules.sharesRequest(active: request, requested: request))
    #expect(!MTPRefreshRules.sharesRequest(
        active: request,
        requested: MTPDirectoryRefreshKey(storageId: 1, path: "/DCIM", showHidden: false)
    ))
    #expect(!MTPRefreshRules.sharesRequest(
        active: request,
        requested: MTPDirectoryRefreshKey(storageId: 1, path: "/", showHidden: true)
    ))
}
