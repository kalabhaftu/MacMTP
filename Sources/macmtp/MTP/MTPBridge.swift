import Foundation

/// The directory coordinator depends on this narrow bridge contract so native
/// transport behavior can be tested without a connected handset.
protocol MTPBridge: Sendable {
    func initialize() async throws -> GoDeviceInfoData
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

