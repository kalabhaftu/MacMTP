import Foundation


public enum MTPStorageType: String, Codable, Sendable, CaseIterable {
    case `internal` = "Internal Storage"
    case sdCard = "SD Card"
    case unknown = "Unknown Storage"

    public static func fromMTPCode(_ code: UInt16) -> MTPStorageType {
        switch code {
        case 0x0001, 0x0003:
            return .internal
        case 0x0002, 0x0004:
            return .sdCard
        default:
            return .unknown
        }
    }

    public var iconName: String {
        switch self {
        case .internal:
            return "internaldrive.fill"
        case .sdCard:
            return "sdcard.fill"
        case .unknown:
            return "questionmark.folder.fill"
        }
    }
}


public struct MTPStorageInfo: Identifiable, Codable, Hashable, Sendable {

    public let storageId: UInt32

    public let description: String

    public let totalCapacity: UInt64

    public let freeSpace: UInt64

    public let storageType: MTPStorageType


    public var id: UInt32 { storageId }


    public var formattedTotal: String {
        FormatUtils.formatBytes(totalCapacity)
    }

    public var formattedFree: String {
        FormatUtils.formatBytes(freeSpace)
    }

    public var formattedUsed: String {
        let used = totalCapacity >= freeSpace ? totalCapacity - freeSpace : 0
        return FormatUtils.formatBytes(used)
    }

    public var usagePercent: Double {
        guard totalCapacity > 0 else { return 0.0 }
        let used = Double(totalCapacity - min(freeSpace, totalCapacity))
        return used / Double(totalCapacity)
    }

    public var usageSummary: String {
        let pct = (usagePercent * 100.0)
        return "\(formattedUsed) / \(formattedTotal) used (\(String(format: "%.1f", pct))%)"
    }
}


#if DEBUG
extension MTPStorageInfo {
    public static let mockInternal = MTPStorageInfo(
        storageId: 0x0001_0001,
        description: "Internal shared storage",
        totalCapacity: 128_849_018_880,
        freeSpace: 34_359_738_368,
        storageType: .internal
    )

    public static let mockSDCard = MTPStorageInfo(
        storageId: 0x0002_0001,
        description: "SD Card",
        totalCapacity: 64_424_509_440,
        freeSpace: 55_834_574_848,
        storageType: .sdCard
    )
}
#endif


public struct MTPDeviceInfo: Identifiable, Codable, Hashable, Sendable {

    public let manufacturer: String

    public let model: String

    public let serialNumber: String

    public let deviceVersion: String

    public var storages: [MTPStorageInfo]


    public var id: String {
        "\(manufacturer)_\(model)_\(serialNumber)"
    }


    public var displayName: String {
        if manufacturer.isEmpty { return model }
        if model.isEmpty { return manufacturer }
        if model.localizedCaseInsensitiveContains(manufacturer) {
            return model
        }
        return "\(manufacturer) \(model)"
    }

    public var totalCapacity: UInt64 {
        storages.reduce(0) { $0 + $1.totalCapacity }
    }

    public var totalFreeSpace: UInt64 {
        storages.reduce(0) { $0 + $1.freeSpace }
    }

    public var formattedTotalCapacity: String {
        FormatUtils.formatBytes(totalCapacity)
    }

    public var formattedTotalFreeSpace: String {
        FormatUtils.formatBytes(totalFreeSpace)
    }

    public var hasStorage: Bool {
        !storages.isEmpty
    }

    public var summary: String {
        var parts = [displayName]
        if !deviceVersion.isEmpty {
            parts.append("v\(deviceVersion)")
        }
        return parts.joined(separator: " – ")
    }
}


#if DEBUG
extension MTPDeviceInfo {
    public static let mock = MTPDeviceInfo(
        manufacturer: "Google",
        model: "Pixel 8 Pro",
        serialNumber: "A1B2C3D4E5F6",
        deviceVersion: "14.0",
        storages: [
            .mockInternal,
            .mockSDCard,
        ]
    )

    public static let mockNoStorage = MTPDeviceInfo(
        manufacturer: "Samsung",
        model: "Galaxy S24 Ultra",
        serialNumber: "Z9Y8X7W6V5U4",
        deviceVersion: "One UI 6.1",
        storages: []
    )
}
#endif
