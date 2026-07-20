import Foundation
import SwiftUI

@MainActor
public final class MTPDeviceManager: ObservableObject {
    public static let shared = MTPDeviceManager()


    @Published public var isConnected = false
    @Published public var deviceInfo: MTPDeviceInfo?
    @Published public var storages: [MTPStorageInfo] = []
    @Published public var selectedStorageId: UInt32?
    @Published public var currentMTPPath = "/"
    @Published public var mtpFiles: [FileNode] = []
    @Published public var isLoading = false
    @Published public var errorMessage: String?


    private var backHistory: [String] = []
    private var forwardHistory: [String] = []


    private let bridge = KalamBridge.shared
    private let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS'Z'"
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter
    }()
    private var refreshGeneration: UInt64 = 0

    private init() {}


    public var canNavigateBack: Bool {
        !backHistory.isEmpty
    }

    public var canNavigateForward: Bool {
        !forwardHistory.isEmpty
    }


    public func connectDevice() async {
        guard !isLoading else { return }
        isLoading = true
        errorMessage = nil

        do {
            let goDevInfo = try await bridge.initialize()
            
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
            
            if let firstStorage = mappedStorages.first {
                self.selectedStorageId = firstStorage.storageId
                self.currentMTPPath = "/"
                self.backHistory.removeAll()
                self.forwardHistory.removeAll()
                await refreshFiles()
            }
        } catch {
            ErrorLogger.log(error, message: "MTP connection failed")

            // Initialization can succeed before storage enumeration fails. Release
            // the native handle so a retry does not inherit a stale session.
            try? await bridge.dispose()

            let androidVendorIDs = USBWatcher.shared.getConnectedAndroidVendorIDs()
            let isConflict = PTPConflictDetector.classifyError(error.localizedDescription, ptpVendorIDs: androidVendorIDs)

            if isConflict {
                self.errorMessage = "Connection Failed: macOS has blocked access to the device.\n\nmacOS automatically claims PTP/MTP devices if apps like Image Capture or Preview are open. Please close them.\n\nYou may need to physically disconnect and reconnect your phone, or ensure its USB connection mode is set to \"File Transfer\" or \"MTP\", then click Retry."
            } else {
                self.errorMessage = "Failed to connect: \(error.localizedDescription)"
            }

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
            if let selectedStorageId,
               !mappedStorages.contains(where: { $0.storageId == selectedStorageId }) {
                self.selectedStorageId = mappedStorages.first?.storageId
                self.currentMTPPath = "/"
                self.backHistory.removeAll()
                self.forwardHistory.removeAll()
            }
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


    public func refreshFiles() async {
        guard isConnected, let storageId = selectedStorageId else { return }
        isLoading = true
        errorMessage = nil

        refreshGeneration += 1
        let generation = refreshGeneration
        let requestedPath = currentMTPPath

        do {
            let showHidden = UserDefaults.standard.object(forKey: "showHiddenFilesMTP") as? Bool ?? false
            let goFiles = try await bridge.listDirectory(
                storageId: storageId,
                path: requestedPath,
                skipHidden: !showHidden
            )

            // If the user navigated again while this request was in flight,
            // a newer refreshFiles() call already owns the latest generation.
            // Discard this stale result instead of clobbering mtpFiles.
            guard generation == refreshGeneration else { return }

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

        } catch {
            guard generation == refreshGeneration else { return }
            ErrorLogger.log(error, message: "Failed to list MTP directory")
            self.errorMessage = "Failed to list directory: \(error.localizedDescription)"
            self.mtpFiles = []
        }

        if generation == refreshGeneration {
            isLoading = false
        }
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
        guard storages.contains(where: { $0.storageId == storageId }) else { return }
        guard selectedStorageId != storageId || currentMTPPath != "/" else {
            await refreshFiles()
            return
        }
        selectedStorageId = storageId
        currentMTPPath = "/"
        backHistory.removeAll()
        forwardHistory.removeAll()
        await refreshFiles()
    }


    public func createFolder(name: String) async throws {
        guard isConnected, let storageId = selectedStorageId else {
            throw KalamError.deviceNotConnected
        }
        
        try validateChildName(name)
        let pathSeparator = currentMTPPath == "/" ? "" : "/"
        let fullPath = "\(currentMTPPath)\(pathSeparator)\(name)"
        
        try await bridge.makeDirectory(storageId: storageId, path: fullPath)
        await refreshFiles()
    }

    public func deleteFiles(paths: [String]) async throws {
        guard isConnected, let storageId = selectedStorageId else {
            throw KalamError.deviceNotConnected
        }
        
        guard !paths.isEmpty else { return }
        try await bridge.deleteFiles(storageId: storageId, paths: paths)
        await refreshFiles()
    }

    public func renameFile(path: String, newName: String) async throws {
        guard isConnected, let storageId = selectedStorageId else {
            throw KalamError.deviceNotConnected
        }
        
        try validateChildName(newName)
        try await bridge.renameFile(storageId: storageId, path: path, newName: newName)
        await refreshFiles()
    }

    public func checkFilesExist(files: [String]) async throws -> [Bool] {
        guard isConnected, let storageId = selectedStorageId else {
            throw KalamError.deviceNotConnected
        }
        
        return try await bridge.checkFilesExist(storageId: storageId, paths: files)
    }

    private func validateChildName(_ name: String) throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed != ".",
              trimmed != "..",
              !trimmed.contains("/"),
              !trimmed.contains("\\") else {
            throw KalamError.invalidPath("A file or folder name must not be empty or contain path separators.")
        }
    }
}
