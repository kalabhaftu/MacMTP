import Foundation

public struct PTPConflictDetector {
    public static let knownAndroidVendorIDs: Set<UInt16> = [
        0x18D1, 0x04E8, 0x0BB4, 0x0FCE, 0x1004, 0x22B8, 0x12D1, 
        0x2717, 0x2A70, 0x22D9, 0x2D95, 0x17EF, 0x3725
    ]

    public static func classifyError(_ errorDescription: String, ptpVendorIDs: [UInt16]) -> Bool {
        let normalizedError = errorDescription.uppercased()
        guard normalizedError.contains("LIBUSB_ERROR_NOT_FOUND")
                || normalizedError.contains("NO SUCH DEVICE")
                || normalizedError.contains("DEVICE NOT FOUND") else {
            return false
        }

        return ptpVendorIDs.contains(where: knownAndroidVendorIDs.contains)
    }
}
