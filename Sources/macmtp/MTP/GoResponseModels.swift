import Foundation

public struct GoErrorResponse: Decodable, Sendable {
    public let error: String?
    public let errorType: String?
}

public struct GoTransferCompletionResponse: Decodable, Sendable {
    public let error: String?
    public let errorType: String?
    public let data: Bool?
}

public struct GoMtpDeviceInfo: Decodable, Sendable {
    public let Manufacturer: String
    public let Model: String
    public let DeviceVersion: String
    public let SerialNumber: String
    public let StandardVersion: UInt16?
    public let MTPVendorExtensionID: UInt32?
    public let MTPVersion: UInt16?
    public let MTPExtension: String?
    public let FunctionalMode: UInt16?
}

public struct GoUsbDeviceInfo: Decodable, Sendable {
    public let IdVendor: UInt16?
    public let IdProduct: UInt16?
    public let Device: UInt16?
    public let Manufacturer: String?
    public let Product: String?
    public let SerialNumber: String?
}

public struct GoDeviceInfoData: Decodable, Sendable {
    public let mtpDeviceInfo: GoMtpDeviceInfo?
    public let usbDeviceInfo: GoUsbDeviceInfo?
}

public struct GoDeviceInfoResult: Decodable, Sendable {
    public let error: String?
    public let errorType: String?
    public let data: GoDeviceInfoData?
}

public struct GoStorageInfo: Decodable, Sendable {
    public let StorageType: UInt16
    public let FilesystemType: UInt16
    public let AccessCapability: UInt16
    public let MaxCapability: UInt64
    public let FreeSpaceInBytes: UInt64
    public let FreeSpaceInImages: UInt32
    public let StorageDescription: String
    public let VolumeLabel: String
}

public struct GoStorageData: Decodable, Sendable {
    public let Sid: UInt32
    public let Info: GoStorageInfo
}

public struct GoStoragesResult: Decodable, Sendable {
    public let error: String?
    public let errorType: String?
    public let data: [GoStorageData]
}

public struct GoFileInfo: Decodable, Sendable {
    public let size: Int64
    public let isFolder: Bool
    public let dateAdded: String
    public let name: String
    public let path: String
    public let parentPath: String
    public let `extension`: String
    public let parentId: UInt32
    public let objectId: UInt32
}

public struct GoWalkResult: Decodable, Sendable {
    public let error: String?
    public let errorType: String?
    public let data: [GoFileInfo]
}

public struct GoSimpleResult: Decodable, Sendable {
    public let error: String?
    public let errorType: String?
    public let data: Bool?
    public let objectId: UInt32?

    public init(error: String?, errorType: String?, data: Bool?, objectId: UInt32? = nil) {
        self.error = error
        self.errorType = errorType
        self.data = data
        self.objectId = objectId
    }
}

public struct GoFileExistsEntry: Decodable, Sendable {
    public let fullpath: String
    public let exists: Bool
}

public struct GoFileExistsResult: Decodable, Sendable {
    public let error: String?
    public let errorType: String?
    public let data: [GoFileExistsEntry]
}

public struct GoTransferPreprocessData: Decodable, Sendable {
    public let fullPath: String
    public let name: String
    public let size: Int64
}

public struct GoPreprocessResult: Decodable, Sendable {
    public let error: String?
    public let errorType: String?
    public let data: GoTransferPreprocessData?
}

public struct GoTransferSizeInfo: Decodable, Sendable {
    public let total: Int64
    public let sent: Int64
    public let progress: Float
}

public struct GoTransferProgressInfo: Decodable, Sendable {
    public let fullPath: String
    public let name: String
    public let elapsedTime: Int64
    public let speed: Double
    public let totalFiles: Int64
    public let totalDirectories: Int64
    public let filesSent: Int64
    public let filesSentProgress: Float
    public let activeFileSize: GoTransferSizeInfo
    public let bulkFileSize: GoTransferSizeInfo
    public let status: String
}

public struct GoProgressResult: Decodable, Sendable {
    public let error: String?
    public let errorType: String?
    public let data: GoTransferProgressInfo?
}
