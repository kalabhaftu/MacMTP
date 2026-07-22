import Foundation

enum ScreenshotDemo {
    static let isEnabled = ProcessInfo.processInfo.environment["MACMTP_SCREENSHOT_MODE"] == "1"
        || ProcessInfo.processInfo.arguments.contains("--screenshot-mode")
        || UserDefaults.standard.bool(forKey: "MACMTPScreenshotMode")
    static let requestedPage = ProcessInfo.processInfo.environment["MACMTP_SCREENSHOT_PAGE"]
        ?? argument(after: "--screenshot-page")
        ?? UserDefaults.standard.string(forKey: "MACMTPScreenshotPage")
        ?? "main"

    static let localPath = "/Users/demo/Downloads"
    static let mtpPath = "/Internal shared storage/DCIM/Camera"
    static let localTotalBytes: Int64 = 512_000_000_000
    static let localFreeBytes: Int64 = 173_530_000_000

    static var deviceInfo: MTPDeviceInfo {
        MTPDeviceInfo(
            manufacturer: "Google",
            model: "Pixel 8 Pro",
            serialNumber: "SCREENSHOT-DEMO",
            deviceVersion: "Android 15",
            storages: storages
        )
    }

    static let storages: [MTPStorageInfo] = [
        MTPStorageInfo(
            storageId: 0x0001_0001,
            description: "Internal shared storage",
            totalCapacity: 256_000_000_000,
            freeSpace: 85_370_000_000,
            storageType: .internal
        ),
        MTPStorageInfo(
            storageId: 0x0002_0001,
            description: "SD Card",
            totalCapacity: 128_000_000_000,
            freeSpace: 96_120_000_000,
            storageType: .sdCard
        ),
    ]

    static var localFiles: [FileNode] {
        let base = localPath
        return [
            folder("Design Assets", in: base, daysAgo: 1),
            folder("Release Builds", in: base, daysAgo: 2),
            file("macmtp-1.6.2.dmg", in: base, size: 42_180_608, daysAgo: 0),
            file("README.md", in: base, size: 18_432, daysAgo: 0),
            file("demo-video.mov", in: base, size: 1_247_912_960, daysAgo: 4),
            file("wireframes.fig", in: base, size: 14_663_680, daysAgo: 3),
            file("device-log.txt", in: base, size: 65_920, daysAgo: 6),
            file("photos.zip", in: base, size: 348_127_232, daysAgo: 9),
        ]
    }

    static var mtpFiles: [FileNode] {
        let base = mtpPath
        return [
            folder("Screenshots", in: base, daysAgo: 0),
            folder("Camera", in: base, daysAgo: 1),
            file("IMG_4301.HEIC", in: base, size: 4_882_432, daysAgo: 0),
            file("IMG_4302.HEIC", in: base, size: 5_104_224, daysAgo: 0),
            file("VID_1205.mp4", in: base, size: 734_003_200, daysAgo: 1),
            file("invoice.pdf", in: base, size: 1_679_360, daysAgo: 3),
            file("playlist.m3u", in: base, size: 12_288, daysAgo: 4),
            file("backup.tar.gz", in: base, size: 584_056_832, daysAgo: 8),
        ]
    }

    @MainActor static func transferBatch() -> TransferBatch {
        let batch = TransferBatch()
        batch.items = [
            TransferItem(
                sourcePath: "\(localPath)/demo-video.mov",
                destinationPath: "\(mtpPath)/demo-video.mov",
                fileSize: 1_247_912_960,
                direction: .localToMTP,
                status: .transferring,
                bytesTransferred: 748_747_776,
                speed: 44_000_000,
                startTime: Date().addingTimeInterval(-18)
            ),
            TransferItem(
                sourcePath: "\(localPath)/README.md",
                destinationPath: "\(mtpPath)/README.md",
                fileSize: 18_432,
                direction: .localToMTP,
                status: .completed,
                bytesTransferred: 18_432,
                startTime: Date().addingTimeInterval(-34)
            ),
            TransferItem(
                sourcePath: "\(mtpPath)/invoice.pdf",
                destinationPath: "\(localPath)/invoice.pdf",
                fileSize: 1_679_360,
                direction: .mtpToLocal,
                status: .queued
            ),
        ]
        batch.currentItemIndex = 0
        batch.state = .transferring
        batch.startTime = Date().addingTimeInterval(-18)
        batch.bytesPerSecond = 44_000_000
        return batch
    }

    static var conflicts: [ConflictingFilePair] {
        [
            conflict("IMG_4301.HEIC", sourceSize: 4_882_432, destinationSize: 4_126_720, sourceDaysAgo: 0, destinationDaysAgo: 6),
            conflict("invoice.pdf", sourceSize: 1_679_360, destinationSize: 1_679_360, sourceDaysAgo: 3, destinationDaysAgo: 3),
            conflict("backup.tar.gz", sourceSize: 584_056_832, destinationSize: 512_000_000, sourceDaysAgo: 8, destinationDaysAgo: 21),
        ]
    }

    private static func folder(_ name: String, in parent: String, daysAgo: Int) -> FileNode {
        FileNode(
            name: name,
            path: "\(parent)/\(name)",
            parentPath: parent,
            isDirectory: true,
            modificationDate: date(daysAgo: daysAgo)
        )
    }

    private static func file(_ name: String, in parent: String, size: Int64, daysAgo: Int) -> FileNode {
        FileNode(
            name: name,
            path: "\(parent)/\(name)",
            parentPath: parent,
            size: size,
            modificationDate: date(daysAgo: daysAgo)
        )
    }

    private static func conflict(
        _ name: String,
        sourceSize: Int64,
        destinationSize: Int64,
        sourceDaysAgo: Int,
        destinationDaysAgo: Int
    ) -> ConflictingFilePair {
        ConflictingFilePair(
            fileName: name,
            sourcePath: "\(mtpPath)/\(name)",
            sourceSize: sourceSize,
            sourceDate: date(daysAgo: sourceDaysAgo),
            destinationPath: "\(localPath)/\(name)",
            destinationSize: destinationSize,
            destinationDate: date(daysAgo: destinationDaysAgo)
        )
    }

    private static func date(daysAgo: Int) -> Date {
        Calendar.current.date(byAdding: .day, value: -daysAgo, to: Date()) ?? Date()
    }

    private static func argument(after name: String) -> String? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: name),
              arguments.indices.contains(index + 1) else {
            return nil
        }
        return arguments[index + 1]
    }
}
