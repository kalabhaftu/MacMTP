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
func emptyDirectoryResponsesDecodeAsAnEmptyCollection() throws {
    let payload = #"{"error":"","errorType":"","data":[]}"#.data(using: .utf8)!
    let result = try JSONDecoder().decode(GoWalkResult.self, from: payload)

    #expect(result.data.isEmpty)
}

@Test
func mutationResponsesPreserveNativeObjectIdentifiers() throws {
    let payload = #"{"error":"","errorType":"","data":true,"objectId":42}"#.data(using: .utf8)!
    let result = try JSONDecoder().decode(GoSimpleResult.self, from: payload)

    #expect(result.data == true)
    #expect(result.objectId == 42)
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

@Test
@MainActor
func directoryCoordinatorCoalescesSameRefreshAndKeepsSnapshotsKeyed() async {
    let coordinator = MTPDirectoryCoordinator()
    let request = MTPDirectoryRefreshKey(storageId: 7, path: "/DCIM", showHidden: false)

    #expect(coordinator.beginRefresh(for: request))
    #expect(!coordinator.beginRefresh(for: request))

    let waiter = Task { @MainActor in
        await coordinator.waitForActiveRefresh()
    }
    try? await Task.sleep(nanoseconds: 10_000_000)
    #expect(coordinator.activeRefreshWaiterCount == 1)

    let node = FileNode(name: "photo.jpg", path: "/DCIM/photo.jpg", parentPath: "/DCIM")
    coordinator.recordSuccessfulListing([node], for: request)
    coordinator.finishRefresh(for: request)
    await waiter.value

    #expect(coordinator.snapshot?.key == request)
    #expect(coordinator.snapshot?.files.map(\.path) == ["/DCIM/photo.jpg"])
    #expect(coordinator.refreshSucceeded(for: request))

    #expect(coordinator.beginRefresh(for: request))
    coordinator.recordFailedRefresh(for: request)
    coordinator.finishRefresh(for: request)
    #expect(!coordinator.refreshSucceeded(for: request))
}

@Test
func mutationReconciliationUsesCanonicalPaths() {
    let original = FileNode(name: "old", path: "/old", parentPath: "/")
    let renamed = MTPDirectoryMutation.rename(oldPath: "/old", newPath: "/new")
    let renamedFiles = MTPDirectoryReconciliation.applying(renamed, to: [original])

    #expect(MTPDirectoryReconciliation.isSatisfied(renamed, by: renamedFiles))
    #expect(renamedFiles.first?.path == "/new")

    let deleted = MTPDirectoryMutation.delete(paths: ["/new"])
    #expect(MTPDirectoryReconciliation.isSatisfied(
        deleted,
        by: MTPDirectoryReconciliation.applying(deleted, to: renamedFiles)
    ))
}

@Test
func usbLifecycleRejectsStaleConnectionCompletions() {
    var lifecycle = USBConnectionLifecycle()
    let first = lifecycle.attachScheduled()
    _ = lifecycle.detached()
    let second = lifecycle.attachScheduled()

    #expect(!lifecycle.accepts(first))
    #expect(lifecycle.accepts(second))
}
