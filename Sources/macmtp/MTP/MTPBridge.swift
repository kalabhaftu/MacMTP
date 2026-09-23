import Foundation

public struct MTPDeviceSelector: Encodable, Sendable, Equatable, Hashable {
    public let vendorId: UInt16
    public let productId: UInt16
    public let serialNumber: String
    public let manufacturer: String
    public let model: String

    private enum CodingKeys: String, CodingKey {
        case vendorId
        case productId
        case serialNumber
    }

    public init(
        vendorId: UInt16,
        productId: UInt16,
        serialNumber: String,
        manufacturer: String = "",
        model: String = ""
    ) {
        self.vendorId = vendorId
        self.productId = productId
        self.serialNumber = serialNumber
        self.manufacturer = manufacturer
        self.model = model
    }

    public var displayName: String {
        let manufacturer = manufacturer.trimmingCharacters(in: .whitespacesAndNewlines)
        let model = model.trimmingCharacters(in: .whitespacesAndNewlines)
        if !manufacturer.isEmpty && !model.isEmpty {
            return model.localizedCaseInsensitiveContains(manufacturer)
                ? model
                : "\(manufacturer) \(model)"
        }
        if !model.isEmpty { return model }
        if !manufacturer.isEmpty { return manufacturer }
        return String(format: "MTP 0x%04x:0x%04x", vendorId, productId)
    }

    public static func == (lhs: MTPDeviceSelector, rhs: MTPDeviceSelector) -> Bool {
        lhs.vendorId == rhs.vendorId
            && lhs.productId == rhs.productId
            && lhs.serialNumber == rhs.serialNumber
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(vendorId)
        hasher.combine(productId)
        hasher.combine(serialNumber)
    }
}

/// The directory coordinator depends on this narrow bridge contract so native
/// transport behavior can be tested without a connected handset.
protocol MTPBridge: Sendable {
    func discoverMTPDevices() async throws -> [MTPDeviceSelector]
    func initialize(selector: MTPDeviceSelector) async throws -> GoDeviceInfoData
    func fetchStorages() async throws -> [GoStorageData]
    func dispose() async throws
    func listDirectory(
        storageId: UInt32,
        path: String,
        recursive: Bool,
        skipHidden: Bool
    ) async throws -> [GoFileInfo]
    func makeDirectory(storageId: UInt32, path: String) async throws -> UInt32?
    func deleteFiles(storageId: UInt32, paths: [String]) async throws
    func renameFile(storageId: UInt32, path: String, newName: String) async throws -> UInt32?
    func checkFilesExist(storageId: UInt32, paths: [String]) async throws -> [Bool]
}

extension KalamBridge: MTPBridge {}
