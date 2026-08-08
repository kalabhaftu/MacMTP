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
    private var connectionGeneration: UInt64 = 0
    private let directoryCoordinator = MTPDirectoryCoordinator()

    private init() {}


    public var canNavigateBack: Bool {
        !backHistory.isEmpty
    }

    public var canNavigateForward: Bool {
        !forwardHistory.isEmpty
    }


    public func connectDevice() async {
        guard !isLoading, !isConnected else { return }
        connectionGeneration &+= 1
        let generation = connectionGeneration
        isLoading = true
        errorMessage = nil

        do {
            let goDevInfo = try await bridge.initialize()
            guard generation == connectionGeneration else { return }
            
            let goStorages = try await bridge.fetchStorages()
            guard generation == connectionGeneration else { return }
            guard !goStorages.isEmpty else {
                throw KalamError.operationFailed("No storage found on the connected MTP device")
            }
            
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
            // Initialization can succeed before storage enumeration fails. Release
            // the native handle so a retry does not inherit a stale session.
            if generation == connectionGeneration {
                try? await bridge.dispose()
            }
            guard generation == connectionGeneration else { return }

            let errLower = error.localizedDescription.lowercased()
            let isNoStorageError = errLower.contains("no storage found")
            let isDeviceNotFound = errLower.contains("no mtp device connected") || errLower.contains("no device found") || errLower.contains("busy")

            let isExpectedUserCondition = isNoStorageError || isDeviceNotFound
            if !isExpectedUserCondition {
                ErrorLogger.log(error, message: "MTP connection failed")
            }

            if isNoStorageError {
                self.errorMessage = "No storage found on device.\n\nPlease unlock your Android phone screen and ensure its USB connection mode is set to \"File Transfer\" (MTP), then click Retry."
            } else {
                self.errorMessage = "Failed to connect: \(error.localizedDescription)"
            }
            self.isConnected = false
            self.deviceInfo = nil
            self.storages = []
            self.selectedStorageId = nil
            self.mtpFiles = []
        }

        if generation == connectionGeneration {
            isLoading = false
        }
    }

    public func disconnectDevice() async {
        connectionGeneration &+= 1
        directoryCoordinator.invalidateSnapshot()
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

    func invalidateConnection(message: String) {
        connectionGeneration &+= 1
        refreshGeneration &+= 1
        directoryCoordinator.invalidateSnapshot()

        if FileTransferService.shared.activeBatch?.isActive == true {
            FileTransferService.shared.cancelTransfer()
            FileTransferService.shared.postTransferNotification(
                title: "Transfer Interrupted",
                body: "Device disconnected during file transfer",
                isError: true
            )
        }

        isConnected = false
        deviceInfo = nil
        storages = []
        selectedStorageId = nil
        mtpFiles = []
        currentMTPPath = "/"
        backHistory.removeAll()
        forwardHistory.removeAll()
        isLoading = false
        errorMessage = message

        Task {
            try? await bridge.dispose()
        }
    }

    public func refreshStorages() async {
        guard isConnected else { return }
        do {
            let goStorages = try await bridge.fetchStorages()
            guard !goStorages.isEmpty else {
                throw KalamError.operationFailed("No storage found on the connected MTP device")
            }
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
            if isMTPTransportFailure(error) {
                invalidateConnection(message: "The MTP connection was lost. Reconnect your Android device and try again.")
            }
        }
    }


    public func refreshFiles() async {
        await directoryCoordinator.waitForMutation()
        await refreshFilesWithoutWaitingForMutation()
    }

    private func currentDirectoryRefreshRequest() -> MTPDirectoryRefreshKey? {
        guard isConnected, let storageId = selectedStorageId else { return nil }
        let showHidden = UserDefaults.standard.object(forKey: "showHiddenFilesMTP") as? Bool ?? false
        return MTPDirectoryRefreshKey(storageId: storageId, path: currentMTPPath, showHidden: showHidden)
    }

    private func finishDirectoryRefresh(_ request: MTPDirectoryRefreshKey) {
        directoryCoordinator.finishRefresh(for: request)
        if !isConnected || currentDirectoryRefreshRequest() == request {
            isLoading = false
        }
    }

    @discardableResult
    private func refreshFilesWithoutWaitingForMutation() async -> Bool {
        guard let request = currentDirectoryRefreshRequest() else { return false }

        if let activeRequest = directoryCoordinator.activeRefreshRequest {
            await directoryCoordinator.waitForActiveRefresh()

            // A navigation or storage change while the shared request was in
            // flight needs its own request. Callers for the same directory
            // share the completed result.
            if !MTPRefreshRules.sharesRequest(active: activeRequest, requested: request)
                || currentDirectoryRefreshRequest() != request {
                return await refreshFilesWithoutWaitingForMutation()
            }
            return directoryCoordinator.refreshSucceeded(for: request)
        }

        guard directoryCoordinator.beginRefresh(for: request) else {
            return await refreshFilesWithoutWaitingForMutation()
        }
        isLoading = true
        errorMessage = nil
        refreshGeneration &+= 1
        let generation = refreshGeneration
        var retryCount = 0

        defer {
            finishDirectoryRefresh(request)
        }

        do {
            // Keep browsing shallow. Some Android MTP implementations reject a
            // recursive root walk with InvalidObjectHandle, despite remaining connected.
            var goFiles: [GoFileInfo]?
            var lastError: Error?
            for attempt in 0..<2 {
                do {
                    goFiles = try await bridge.listDirectory(
                        storageId: request.storageId,
                        path: request.path,
                        recursive: false,
                        skipHidden: !request.showHidden
                    )
                    break
                } catch {
                    lastError = error
                    guard attempt == 0, shouldRetryMTPDirectory(error) else { break }
                    retryCount = 1
                    try await Task.sleep(nanoseconds: 150_000_000)
                }
            }
            guard let goFiles else {
                throw lastError ?? KalamError.nativeOperationFailed(
                    operation: "list_directory",
                    errorType: nil,
                    message: "The directory request failed without an error response."
                )
            }

            guard generation == refreshGeneration,
                  currentDirectoryRefreshRequest() == request else { return false }

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
            directoryCoordinator.recordSuccessfulListing(mapped, for: request)
            return true

        } catch {
            guard generation == refreshGeneration,
                  currentDirectoryRefreshRequest() == request else { return false }
            directoryCoordinator.recordFailedRefresh(for: request)
            ErrorLogger.log(
                error,
                message: "Failed to list MTP directory",
                userInfo: [
                    "operation": "list_directory",
                    "is_root": request.path == "/",
                    "path_depth": request.path.split(separator: "/").count,
                    "device_connected": isConnected,
                    "retry_count": retryCount,
                    "refresh_coalesced": directoryCoordinator.activeRefreshWaiterCount > 0,
                    "refresh_waiter_count": directoryCoordinator.activeRefreshWaiterCount,
                    "native_error_type": nativeErrorType(for: error),
                ]
            )
            if isMTPTransportFailure(error) {
                invalidateConnection(message: "MTP device disconnected or connection lost.")
            } else {
                let detail = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
                self.errorMessage = detail.isEmpty
                    ? "Failed to list directory. Try again."
                    : "Failed to list directory: \(detail)"
            }
            // Preserve the last valid listing. The error state is displayed by
            // the pane without pretending that a failed request returned empty.
            return false
        }
    }

    public func navigateTo(path: String) async {
        guard isConnected else { return }
        if path == currentMTPPath { return }
        
        backHistory.append(currentMTPPath)
        forwardHistory.removeAll()
        
        currentMTPPath = path
        mtpFiles = []
        directoryCoordinator.invalidateSnapshot()
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
        mtpFiles = []
        directoryCoordinator.invalidateSnapshot()
        await refreshFiles()
    }


    public func createFolder(name: String, in targetPath: String? = nil) async throws {
        let normalizedName = try normalizedMTPChildName(name)
        await directoryCoordinator.beginMutation()
        defer { directoryCoordinator.endMutation() }

        guard isConnected, let storageId = selectedStorageId else {
            throw KalamError.deviceNotConnected
        }
        let parentPath = targetPath ?? currentMTPPath
        guard parentPath == currentMTPPath else {
            throw KalamError.invalidPath("The destination folder changed. Please retry.")
        }

        let pathSeparator = parentPath == "/" ? "" : "/"
        let fullPath = "\(parentPath)\(pathSeparator)\(normalizedName)"

        let alreadyExists = try await bridge.checkFilesExist(storageId: storageId, paths: [fullPath]).first == true
        if alreadyExists {
            throw KalamError.itemAlreadyExists(normalizedName)
        }

        let previousFiles = mtpFiles
        let parentPathForNode = parentPath == "/" ? "/" : parentPath
        let pathForNode = fullPath
        do {
            let objectId = try await bridge.makeDirectory(storageId: storageId, path: fullPath)
            let optimisticNode = FileNode(
                name: normalizedName,
                path: pathForNode,
                parentPath: parentPathForNode,
                isDirectory: true,
                modificationDate: Date(),
                objectId: objectId ?? 0
            )
            let mutation = MTPDirectoryMutation.create(optimisticNode)
            mtpFiles = MTPDirectoryReconciliation.applying(mutation, to: previousFiles)

            guard try await reconcile(mutation, storageId: storageId) else {
                mtpFiles = previousFiles
                throw KalamError.operationNotReconciled("folder creation")
            }

            _ = await refreshFilesWithoutWaitingForMutation()
            applyReconciledMutationIfListingLags(mutation)
        } catch {
            let existsAfterFailure = (try? await bridge.checkFilesExist(storageId: storageId, paths: [fullPath]).first) == true
            if existsAfterFailure {
                throw KalamError.itemAlreadyExists(normalizedName)
            }
            throw error
        }
        await refreshStorages()
    }

    public func deleteFiles(paths: [String]) async throws {
        guard !paths.isEmpty else { return }
        await directoryCoordinator.beginMutation()
        defer { directoryCoordinator.endMutation() }
        guard isConnected, let storageId = selectedStorageId else {
            throw KalamError.deviceNotConnected
        }
        let previousFiles = mtpFiles
        let mutation = MTPDirectoryMutation.delete(paths: Set(paths))
        try await bridge.deleteFiles(storageId: storageId, paths: paths)
        mtpFiles = MTPDirectoryReconciliation.applying(mutation, to: previousFiles)
        guard try await reconcile(mutation, storageId: storageId) else {
            mtpFiles = previousFiles
            throw KalamError.operationNotReconciled("deletion")
        }
        _ = await refreshFilesWithoutWaitingForMutation()
        applyReconciledMutationIfListingLags(mutation)
        await refreshStorages()
    }

    public func renameFile(path: String, newName: String) async throws {
        let normalizedName = try normalizedMTPChildName(newName)
        await directoryCoordinator.beginMutation()
        defer { directoryCoordinator.endMutation() }
        guard isConnected, let storageId = selectedStorageId else {
            throw KalamError.deviceNotConnected
        }

        let oldName = (path as NSString).lastPathComponent
        guard normalizedName != oldName else { return }
        let parentPath = (path as NSString).deletingLastPathComponent
        let destinationPath = (parentPath == "/" ? "" : parentPath) + "/" + normalizedName
        if try await bridge.checkFilesExist(storageId: storageId, paths: [destinationPath]).first == true {
            throw KalamError.itemAlreadyExists(normalizedName)
        }

        let previousFiles = mtpFiles
        _ = try await bridge.renameFile(storageId: storageId, path: path, newName: normalizedName)
        let mutation = MTPDirectoryMutation.rename(oldPath: path, newPath: destinationPath)
        mtpFiles = MTPDirectoryReconciliation.applying(mutation, to: previousFiles)
        guard try await reconcile(mutation, storageId: storageId) else {
            mtpFiles = previousFiles
            throw KalamError.operationNotReconciled("renaming")
        }
        _ = await refreshFilesWithoutWaitingForMutation()
        applyReconciledMutationIfListingLags(mutation)
    }

    private func applyReconciledMutationIfListingLags(_ mutation: MTPDirectoryMutation) {
        guard !MTPDirectoryReconciliation.isSatisfied(mutation, by: mtpFiles) else { return }
        ErrorLogger.logMessage(
            "MTP directory listing lagged a confirmed mutation",
            level: .warning,
            userInfo: [
                "operation": mutation.operationName,
                "reconciliation_result": "confirmed_but_listing_lagged"
            ]
        )
        mtpFiles = MTPDirectoryReconciliation.applying(mutation, to: mtpFiles)
    }

    private func reconcile(_ mutation: MTPDirectoryMutation, storageId: UInt32) async throws -> Bool {
        let paths: [String]
        switch mutation {
        case .create(let file):
            paths = [file.path]
        case .rename(let oldPath, let newPath):
            paths = [oldPath, newPath]
        case .delete(let deletedPaths):
            paths = deletedPaths.sorted()
        }

        let delays: [UInt64] = [0, 150_000_000, 300_000_000, 600_000_000]
        for (attempt, delay) in delays.enumerated() {
            if delay > 0 {
                try await Task.sleep(nanoseconds: delay)
            }

            let exists = try await bridge.checkFilesExist(storageId: storageId, paths: paths)
            let satisfied: Bool
            switch mutation {
            case .create:
                satisfied = exists == [true]
            case .rename:
                satisfied = exists == [false, true]
            case .delete:
                satisfied = exists.allSatisfy { !$0 }
            }
            if satisfied {
                ErrorLogger.logMessage(
                    "MTP mutation reconciled",
                    level: .info,
                    userInfo: [
                        "operation": mutation.operationName,
                        "reconciliation_attempt": attempt,
                        "reconciliation_result": "confirmed"
                    ]
                )
                return true
            }
        }

        ErrorLogger.logMessage(
            "MTP mutation was not visible after bounded reconciliation",
            level: .warning,
            userInfo: [
                "operation": mutation.operationName,
                "reconciliation_result": "not_confirmed"
            ]
        )
        return false
    }

    public func checkFilesExist(files: [String]) async throws -> [Bool] {
        guard isConnected, let storageId = selectedStorageId else {
            throw KalamError.deviceNotConnected
        }
        
        return try await bridge.checkFilesExist(storageId: storageId, paths: files)
    }

}
