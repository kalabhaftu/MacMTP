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

@Test
func largeTransferBatchesUpdateAggregatesWithoutRepeatedFullScans() {
    let itemCount = 2_000
    let batch = TransferBatch()
    batch.items = (0..<itemCount).map { index in
        TransferItem(
            sourcePath: "/tmp/file-\(index)",
            destinationPath: "/storage/file-\(index)",
            fileSize: 100,
            direction: .localToMTP
        )
    }
    let fullScansAfterInstall = batch.fullRecalculationCount

    for index in 0..<1_000 {
        let progress = Int64((index % 100) + 1)
        batch.updateItem(at: index) { item in
            item.bytesTransferred = progress
            item.status = index.isMultiple(of: 2) ? .completed : .failed
        }
    }

    #expect(batch.totalFileCount == itemCount)
    #expect(batch.totalBytes == 200_000)
    #expect(batch.totalBytesTransferred == 50_500)
    #expect(batch.completedFileCount == 500)
    #expect(batch.failedFileCount == 500)
    #expect(batch.overallProgress == 0.2525)
    #expect(batch.fullRecalculationCount == fullScansAfterInstall)

    batch.currentItemIndex = 0
    for progress in 2...100 {
        batch.updateItem(at: 0) { $0.bytesTransferred = Int64(progress) }
    }
    #expect(batch.currentItem?.progress == 1)
    #expect(batch.totalBytesTransferred == 50_599)
    #expect(batch.fullRecalculationCount == fullScansAfterInstall)

    batch.updateItem(at: 0) { item in
        item.fileSize = 200
        item.bytesTransferred = 200
        item.status = .completed
    }
    #expect(batch.currentItem?.progress == 1)
    #expect(batch.totalBytes == 200_100)
    #expect(batch.totalBytesTransferred == 50_699)
    #expect(batch.completedFileCount == 500)
    #expect(batch.failedFileCount == 500)
    #expect(batch.overallProgress == Double(50_699) / Double(200_100))
    #expect(batch.fullRecalculationCount == fullScansAfterInstall)
}

@Test
func replacingTransferBatchItemsPerformsAFullAggregateRebuild() {
    let batch = TransferBatch()
    batch.items = [
        TransferItem(
            sourcePath: "/tmp/old",
            destinationPath: "/storage/old",
            fileSize: 10,
            direction: .localToMTP,
            status: .completed
        )
    ]
    let scansAfterFirstInstall = batch.fullRecalculationCount

    batch.items = [
        TransferItem(
            sourcePath: "/tmp/new",
            destinationPath: "/storage/new",
            fileSize: 25,
            direction: .localToMTP,
            status: .failed,
            bytesTransferred: 7
        )
    ]

    #expect(batch.fullRecalculationCount == scansAfterFirstInstall + 1)
    #expect(batch.completedFileCount == 0)
    #expect(batch.failedFileCount == 1)
    #expect(batch.totalBytes == 25)
    #expect(batch.totalBytesTransferred == 7)
}

@Test
func directItemArrayMutationKeepsPublishedAggregateValuesInSync() {
    let batch = TransferBatch()
    batch.items = [
        TransferItem(
            sourcePath: "/tmp/file",
            destinationPath: "/storage/file",
            fileSize: 20,
            direction: .localToMTP
        )
    ]
    let scansAfterInstall = batch.fullRecalculationCount

    batch.items[0].bytesTransferred = 5

    #expect(batch.totalBytesTransferred == 5)
    #expect(batch.fullRecalculationCount == scansAfterInstall + 1)
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
func cancellingTransferKeepsBatchVisibleUntilNativeCancellationReturns() {
    let service = FileTransferService.shared
    let batch = TransferBatch()
    service.activeBatch = batch
    batch.start()

    service.cancelTransfer()

    #expect(batch.state == .cancelling)
    #expect(service.activeBatch === batch)

    batch.finishCancellation()
    #expect(batch.state == .cancelled)
}
