import Testing
@testable import macmtp

@Test @MainActor
func transferServiceOwnsPauseAndResumeStateTransitions() {
    let service = FileTransferService.shared
    let batch = TransferBatch()
    service.activeBatch = batch
    defer { service.activeBatch = nil }

    batch.start()
    #expect(service.pauseTransfer())
    #expect(batch.state == .paused)

    service.resumeTransfer()
    #expect(batch.state == .transferring)
}

@Test
func transferBatchProgressStaysWithinDisplayBounds() {
    let batch = TransferBatch()
    batch.items = [
        TransferItem(
            sourcePath: "/tmp/file",
            destinationPath: "/storage/file",
            fileSize: 100,
            direction: .localToMTP,
            bytesTransferred: 200
        )
    ]

    #expect(batch.overallProgress == 1)
}

@Test @MainActor
func concurrentTransferRequestsAreRejectedWithoutStartingAnotherBatch() {
    let service = FileTransferService.shared
    let batch = TransferBatch()
    service.activeBatch = batch
    batch.start()
    defer {
        service.cancelTransfer()
        service.activeBatch = nil
    }

    let source = FileNode(name: "file.txt", path: "/tmp/file.txt")
    #expect(!service.initiateTransfer(
        sources: [source],
        destinationDir: "/storage",
        direction: .localToMTP,
        storageId: 1
    ))
}

@Test @MainActor
func cancellingTransferHidesThePublishedBatchImmediately() {
    let service = FileTransferService.shared
    let batch = TransferBatch()
    service.activeBatch = batch
    batch.start()

    service.cancelTransfer()

    #expect(batch.state == .cancelled)
    #expect(service.activeBatch == nil)
}
