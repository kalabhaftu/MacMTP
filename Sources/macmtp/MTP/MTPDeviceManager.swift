import Foundation
import SwiftUI
import Combine

@MainActor
public final class MTPDeviceManager: ObservableObject {
    public static let shared = MTPDeviceManager()

    // MARK: - Published Properties

    @Published public var isConnected = false
    @Published public var deviceInfo: MTPDeviceInfo?
    @Published public var storages: [MTPStorageInfo] = []
    @Published public var selectedStorageId: UInt32?
    @Published public var currentMTPPath = "/"
    @Published public var mtpFiles: [FileNode] = []
    @Published public var isLoading = false
    @Published public var errorMessage: String?

    // MARK: - Navigation History

    private var backHistory: [String] = []
    private var forwardHistory: [String] = []

    // MARK: - Private state

    private let bridge = KalamBridge.shared
    private let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        // Go constant format: "2006-01-02T15:04:05.000Z"
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS'Z'"
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter
    }()
    /// discard results from stale (pre-navigation) work.
    private var refreshGeneration: UInt64 = 0

    private init() {}

    // MARK: - Navigation History Helpers

    public var canNavigateBack: Bool {
        !backHistory.isEmpty
    }

    public var canNavigateForward: Bool {
        !forwardHistory.isEmpty
    }

    // MARK: - Device Lifecycle

    public func connectDevice() async {
        guard !isLoading else { return }
        isLoading = true
        errorMessage = nil

        do {
            let goDevInfo = try await bridge.initialize()
            
            // Fetch storages immediately
            let goStorages = try await bridge.fetchStorages()
            
            // Map MTPStorageInfo
            let mappedStorages = goStorages.map { item -> MTPStorageInfo in
                let desc = item.Info.StorageDescription
                let type = MTPStorageType.fromMTPCode(item.Info.StorageType)
                return MTPStorageInfo(
                    storageId: item.Sid,
                    description: desc.isEmpty ? "Internal Storage" : desc,
                    totalCapacity: item.Info.MaxCapability,
                    freeSpace: item.Info.FreeSpaceInBytes,
                    storageType: type
                )
            }

            // Map MTPDeviceInfo
            let mappedDevInfo = MTPDeviceInfo(
                manufacturer: goDevInfo.mtpDeviceInfo?.Manufacturer ?? goDevInfo.usbDeviceInfo?.Manufacturer ?? "Unknown",
                model: goDevInfo.mtpDeviceInfo?.Model ?? goDevInfo.usbDeviceInfo?.Product ?? "MTP Device",
                serialNumber: goDevInfo.mtpDeviceInfo?.SerialNumber ?? goDevInfo.usbDeviceInfo?.SerialNumber ?? "000000",
                deviceVersion: goDevInfo.mtpDeviceInfo?.DeviceVersion ?? "1.0",
                storages: mappedStorages
            )

            self.deviceInfo = mappedDevInfo
            self.storages = mappedStorages
            self.isConnected = true
            
            // Automatically select first storage if none selected
            if let firstStorage = mappedStorages.first {
                self.selectedStorageId = firstStorage.storageId
                self.currentMTPPath = "/"
                self.backHistory.removeAll()
                self.forwardHistory.removeAll()
                await refreshFiles()
            }
        } catch {
            ErrorLogger.log(error, message: "MTP connection failed")
            self.errorMessage = "Failed to connect: \(error.localizedDescription)"
            self.isConnected = false
            self.deviceInfo = nil
            self.storages = []
            self.selectedStorageId = nil
            self.mtpFiles = []
        }

        isLoading = false
    }

    public func disconnectDevice() async {
        isLoading = true
        errorMessage = nil
        
        // Notify about interrupted transfer if one is active
        if FileTransferService.shared.activeBatch?.isActive == true {
            Task { @MainActor in
                FileTransferService.shared.cancelTransfer()
                FileTransferService.shared.postTransferNotification(
                    title: "Transfer Interrupted",
                    body: "Device disconnected during file transfer",
                    isError: true
                )
            }
        }
        
        do {
            try await bridge.dispose()
        } catch {
            ErrorLogger.log(error, message: "Failed to dispose MTP device cleanly")
        }
        
        self.isConnected = false
        self.deviceInfo = nil
        self.storages = []
        self.selectedStorageId = nil
        self.mtpFiles = []
        self.currentMTPPath = "/"
        self.backHistory.removeAll()
        self.forwardHistory.removeAll()
        self.isLoading = false
    }

    public func refreshStorages() async {
        guard isConnected else { return }
        do {
            let goStorages = try await bridge.fetchStorages()
            let mappedStorages = goStorages.map { item -> MTPStorageInfo in
                let desc = item.Info.StorageDescription
                let type = MTPStorageType.fromMTPCode(item.Info.StorageType)
                return MTPStorageInfo(
                    storageId: item.Sid,
                    description: desc.isEmpty ? "Internal Storage" : desc,
                    totalCapacity: item.Info.MaxCapability,
                    freeSpace: item.Info.FreeSpaceInBytes,
                    storageType: type
                )
            }
            self.storages = mappedStorages
            if let dev = self.deviceInfo {
                self.deviceInfo = MTPDeviceInfo(
                    manufacturer: dev.manufacturer,
                    model: dev.model,
                    serialNumber: dev.serialNumber,
                    deviceVersion: dev.deviceVersion,
                    storages: mappedStorages
                )
            }
        } catch {
            ErrorLogger.log(error, message: "Failed to refresh storages")
        }
    }

    // MARK: - Directory Navigation

    public func refreshFiles() async {
        guard isConnected, let storageId = selectedStorageId else { return }
        isLoading = true
        errorMessage = nil

        do {
            let goFiles = try await bridge.listDirectory(storageId: storageId, path: currentMTPPath)
            
            // Map GoFileInfo to FileNode
            let mapped = goFiles.map { item -> FileNode in
                let modDate = dateFormatter.date(from: item.dateAdded) ?? Date()
                return FileNode(
                    name: item.name,
                    path: item.path,
                    parentPath: item.parentPath,
                    isDirectory: item.isFolder,
                    size: item.size,
                    modificationDate: modDate,
                    objectId: item.objectId,
                    parentId: item.parentId,
                    isSelected: false
                )
            }
            self.mtpFiles = mapped
            
            // MTP directory sizes are too expensive to calculate automatically as recursive Walk blocks the single-threaded MTP session.
        } catch {
            ErrorLogger.log(error, message: "Failed to list MTP directory")
            self.errorMessage = "Failed to list directory: \(error.localizedDescription)"
            self.mtpFiles = []
        }

        isLoading = false
    }

    public func navigateTo(path: String) async {
        guard isConnected else { return }
        if path == currentMTPPath { return }
        
        backHistory.append(currentMTPPath)
        forwardHistory.removeAll()
        
        currentMTPPath = path
        await refreshFiles()
    }

    public func navigateUp() async {
        guard isConnected else { return }
        if currentMTPPath == "/" || currentMTPPath.isEmpty { return }
        
        let components = currentMTPPath.split(separator: "/")
        if components.isEmpty {
            await navigateTo(path: "/")
        } else {
            let parent = "/" + components.dropLast().joined(separator: "/")
            await navigateTo(path: parent)
        }
    }

    public func navigateBack() async {
        guard let previous = backHistory.popLast() else { return }
        forwardHistory.append(currentMTPPath)
        currentMTPPath = previous
        await refreshFiles()
    }

    public func navigateForward() async {
        guard let next = forwardHistory.popLast() else { return }
        backHistory.append(currentMTPPath)
        currentMTPPath = next
        await refreshFiles()
    }

    public func selectStorage(_ storageId: UInt32) async {
        guard selectedStorageId != storageId else { return }
        selectedStorageId = storageId
        currentMTPPath = "/"
        backHistory.removeAll()
        forwardHistory.removeAll()
        await refreshFiles()
    }

    // MARK: - File Operations

    public func createFolder(name: String) async throws {
        guard isConnected, let storageId = selectedStorageId else {
            throw KalamError.deviceNotConnected
        }
        
        let pathSeparator = currentMTPPath == "/" ? "" : "/"
        let fullPath = "\(currentMTPPath)\(pathSeparator)\(name)"
        
        try await bridge.makeDirectory(storageId: storageId, path: fullPath)
        await refreshFiles()
    }

    public func deleteFiles(paths: [String]) async throws {
        guard isConnected, let storageId = selectedStorageId else {
            throw KalamError.deviceNotConnected
        }
        
        try await bridge.deleteFiles(storageId: storageId, paths: paths)
        await refreshFiles()
    }

    public func renameFile(path: String, newName: String) async throws {
        guard isConnected, let storageId = selectedStorageId else {
            throw KalamError.deviceNotConnected
        }
        
        try await bridge.renameFile(storageId: storageId, path: path, newName: newName)
        await refreshFiles()
    }

    public func checkFilesExist(files: [String]) async throws -> [Bool] {
        guard isConnected, let storageId = selectedStorageId else {
            throw KalamError.deviceNotConnected
        }
        
        return try await bridge.checkFilesExist(storageId: storageId, paths: files)
    }
}
