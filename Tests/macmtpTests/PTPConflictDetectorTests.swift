import Testing
import Foundation
@testable import macmtp

@Test
func recognizesKnownAndroidVendorWithLibUSBNotFoundError() {
    #expect(
        PTPConflictDetector.classifyError(
            "LIBUSB_ERROR_NOT_FOUND while opening device",
            ptpVendorIDs: [0x18D1]
        )
    )
}

@Test
func recognizesCommonDeviceNotFoundWordingCaseInsensitively() {
    #expect(
        PTPConflictDetector.classifyError(
            "No Such Device",
            ptpVendorIDs: [0x04E8]
        )
    )
}

@Test
func rejectsUnknownVendorOrUnrelatedError() {
    #expect(
        !PTPConflictDetector.classifyError(
            "LIBUSB_ERROR_NOT_FOUND",
            ptpVendorIDs: [0x1234]
        )
    )
    #expect(
        !PTPConflictDetector.classifyError(
            "permission denied",
            ptpVendorIDs: [0x18D1]
        )
    )
}

@Test
func progressIsClampedToFileBounds() {
    var item = TransferItem(
        sourcePath: "/tmp/file",
        destinationPath: "/storage/file",
        fileSize: 100,
        direction: .localToMTP,
        startTime: Date()
    )

    item.updateProgress(bytesTransferred: 200)

    #expect(item.bytesTransferred == 100)
    #expect(item.progress == 1)
}

@Test
func skippedItemCountsAsCompleteForItsOwnProgress() {
    var item = TransferItem(
        sourcePath: "/tmp/file",
        destinationPath: "/storage/file",
        fileSize: 100,
        direction: .localToMTP
    )

    item.markSkipped()

    #expect(item.bytesTransferred == 100)
    #expect(item.progress == 1)
}
