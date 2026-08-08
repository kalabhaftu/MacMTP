import Testing
@testable import macmtp

@Test @MainActor
func transferServiceOwnsPauseAndResumeStateTransitions() {
    let service = FileTransferService.shared
    let batch = TransferBatch()
    service.activeBatch = batch
    defer { service.activeBatch = nil }

    batch.start()
    service.pauseTransfer()
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
