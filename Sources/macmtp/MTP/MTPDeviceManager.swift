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
    @Published public private(set) var isPerformingMutation = false
    @Published public var errorMessage: String?


    private var backHistory: [String] = []
    private var forwardHistory: [String] = []


    private let bridge: any MTPBridge
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
    private var displayedDirectoryKey: MTPDirectoryRefreshKey?

    init(bridge: any MTPBridge = KalamBridge.shared) {
        self.bridge = bridge
    }


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
            USBWatcher.shared.registerActiveDevice(
                vendorID: goDevInfo.usbDeviceInfo?.IdVendor,
                productID: goDevInfo.usbDeviceInfo?.IdProduct,
                serialNumber: goDevInfo.usbDeviceInfo?.SerialNumber
            )
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
            let isDeviceNotFound = errLower.contains("no mtp device")
                || errLower.contains("no device found")
                || errLower.contains("mtp detect failed")
                || errLower.contains("busy")

            let isExpectedUserCondition = isNoStorageError || isDeviceNotFound
            if !isExpectedUserCondition {
                ErrorLogger.log(
                    error,
                    message: "MTP connection failed",
                    userInfo: [
                        "operation": "initialize",
                        "operation_phase": "connection",
                        "native_error_type": nativeErrorType(for: error),
                        "session_generation": Int64(generation)
                    ]
                )
            }

            if isNoStorageError {
                self.errorMessage = "No storage found on device.\n\nPlease unlock your Android phone screen and ensure its USB connection mode is set to \"File Transfer\" (MTP), then click Retry."
            } else if isDeviceNotFound {
                self.errorMessage = nil
            } else {
                self.errorMessage = "Failed to connect: \(error.localizedDescription)"
            }
            self.isConnected = false
            self.deviceInfo = nil
            self.storages = []
            self.selectedStorageId = nil
            self.mtpFiles = []
            self.displayedDirectoryKey = nil
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
        USBWatcher.shared.clearActiveDevice()
        self.isConnected = false
        self.deviceInfo = nil
        self.storages = []
        self.selectedStorageId = nil
        self.mtpFiles = []
        self.displayedDirectoryKey = nil
        self.currentMTPPath = "/"
        self.backHistory.removeAll()
        self.forwardHistory.removeAll()
        self.isLoading = false
    }

    func invalidateConnection(message: String) {
        connectionGeneration &+= 1
        refreshGeneration &+= 1
        let invalidatedGeneration = connectionGeneration
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
        displayedDirectoryKey = nil
        currentMTPPath = "/"
        backHistory.removeAll()
        forwardHistory.removeAll()
        isLoading = false
        errorMessage = message

        Task { @MainActor [weak self] in
            guard let self else { return }
            try? await bridge.dispose()
            guard self.connectionGeneration == invalidatedGeneration else { return }
            let scheduled = USBWatcher.shared.reconnectIfAvailable()
            ErrorLogger.logMessage(
                scheduled ? "MTP connection recovery scheduled" : "MTP connection recovery was not scheduled",
                level: scheduled ? .info : .warning,
                userInfo: [
                    "operation": "reconnect",
                    "operation_phase": "connection",
                    "reconnect_result": scheduled ? "scheduled" : "no_active_usb_identity",
                    "session_generation": Int64(invalidatedGeneration),
                ]
            )
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
            self.displayedDirectoryKey = request
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
                    "operation_phase": "refresh",
                    "is_root": request.path == "/",
                    "path_depth": request.path.split(separator: "/").count,
                    "device_connected": isConnected,
                    "retry_count": retryCount,
                    "refresh_coalesced": directoryCoordinator.activeRefreshWaiterCount > 0,
                    "refresh_waiter_count": directoryCoordinator.activeRefreshWaiterCount,
                    "native_error_type": nativeErrorType(for: error),
                    "session_generation": Int64(connectionGeneration),
                ]
            )
            if isMTPTransportFailure(error) {
                invalidateConnection(message: "MTP device disconnected or connection lost.")
            } else {
                if let snapshot = directoryCoordinator.snapshot(for: request) {
                    // A failed refresh may only restore the same storage/path/
                    // visibility snapshot; never reuse another directory.
                    mtpFiles = snapshot.files
                    displayedDirectoryKey = request
                }
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
        displayedDirectoryKey = nil
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
        displayedDirectoryKey = nil
        await refreshFiles()
    }


    public func createFolder(name: String, in targetPath: String? = nil) async throws {
        let normalizedName = try normalizedMTPChildName(name)
        await directoryCoordinator.beginMutation()
        isPerformingMutation = true
        defer {
            isPerformingMutation = false
            directoryCoordinator.endMutation()
        }

        guard isConnected, let storageId = selectedStorageId else {
            throw KalamError.deviceNotConnected
        }
        let parentPath = targetPath ?? currentMTPPath
        guard parentPath == currentMTPPath else {
            throw KalamError.invalidPath("The destination folder changed. Please retry.")
        }

        let pathSeparator = parentPath == "/" ? "" : "/"
        let fullPath = "\(parentPath)\(pathSeparator)\(normalizedName)"

        try await preflightDestination(
            fullPath: fullPath,
            name: normalizedName,
            storageId: storageId,
            operation: "make_directory"
        )

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
            publishConfirmedMutation(mutation, replacing: previousFiles)
        } catch {
            mtpFiles = previousFiles
            if isMTPDuplicateError(error) {
                throw KalamError.itemAlreadyExists(normalizedName)
            }
            reportMutationFailure(error, operation: "make_directory", phase: "mutation")
            throw error
        }
    }

    public func deleteFiles(paths: [String]) async throws {
        guard !paths.isEmpty else { return }
        await directoryCoordinator.beginMutation()
        isPerformingMutation = true
        defer {
            isPerformingMutation = false
            directoryCoordinator.endMutation()
        }
        guard isConnected, let storageId = selectedStorageId else {
            throw KalamError.deviceNotConnected
        }
        guard paths.allSatisfy({ ($0 as NSString).deletingLastPathComponent == currentMTPPath }) else {
            throw KalamError.invalidPath("The delete destination changed. Please retry.")
        }
        let previousFiles = mtpFiles
        let mutation = MTPDirectoryMutation.delete(paths: Set(paths))
        try await bridge.deleteFiles(storageId: storageId, paths: paths)
        publishConfirmedMutation(mutation, replacing: previousFiles)
    }

    public func renameFile(path: String, newName: String) async throws {
        let normalizedName = try normalizedMTPChildName(newName)
        await directoryCoordinator.beginMutation()
        isPerformingMutation = true
        defer {
            isPerformingMutation = false
            directoryCoordinator.endMutation()
        }
        guard isConnected, let storageId = selectedStorageId else {
            throw KalamError.deviceNotConnected
        }

        let oldName = (path as NSString).lastPathComponent
        guard normalizedName != oldName else { return }
        let parentPath = (path as NSString).deletingLastPathComponent
        guard parentPath == currentMTPPath else {
            throw KalamError.invalidPath("The rename destination changed. Please retry.")
        }
        let destinationPath = (parentPath == "/" ? "" : parentPath) + "/" + normalizedName
        try await preflightDestination(
            fullPath: destinationPath,
            name: normalizedName,
            storageId: storageId,
            operation: "rename_file",
            excludingPath: path
        )

        let previousFiles = mtpFiles
        do {
            _ = try await bridge.renameFile(storageId: storageId, path: path, newName: normalizedName)
        } catch {
            if isMTPDuplicateError(error) {
                throw KalamError.itemAlreadyExists(normalizedName)
            }
            reportMutationFailure(error, operation: "rename_file", phase: "mutation")
            throw error
        }
        let mutation = MTPDirectoryMutation.rename(oldPath: path, newPath: destinationPath)
        publishConfirmedMutation(mutation, replacing: previousFiles)
    }

    private func publishConfirmedMutation(_ mutation: MTPDirectoryMutation, replacing previousFiles: [FileNode]) {
        let updatedFiles = MTPDirectoryReconciliation.applying(mutation, to: previousFiles)
        mtpFiles = updatedFiles

        // Kalam returns a successful mutation response (and an object ID for
        // create/rename). A second immediate walk is not part of that contract;
        // some Android devices close the USB session when that walk follows a
        // mutation too quickly. Keep the confirmed result visible and let an
        // explicit refresh perform authoritative reconciliation later.
        if let request = currentDirectoryRefreshRequest() {
            displayedDirectoryKey = request
            directoryCoordinator.recordSuccessfulListing(updatedFiles, for: request)
        }
    }

    private func preflightDestination(
        fullPath: String,
        name: String,
        storageId: UInt32,
        operation: String,
        excludingPath: String? = nil
    ) async throws {
        let request = MTPDirectoryRefreshKey(
            storageId: storageId,
            path: currentMTPPath,
            showHidden: UserDefaults.standard.object(forKey: "showHiddenFilesMTP") as? Bool ?? false
        )

        if displayedDirectoryKey == request,
           let snapshot = directoryCoordinator.snapshot(for: request) {
            let exists = MTPDirectoryPreflight.destinationExists(
                in: snapshot,
                path: fullPath,
                excluding: excludingPath
            )
            if exists {
                throw KalamError.itemAlreadyExists(name)
            }
            return
        }

        do {
            let exists = try await bridge.checkFilesExist(storageId: storageId, paths: [fullPath]).first == true
            if exists {
                throw KalamError.itemAlreadyExists(name)
            }
        } catch {
            reportMutationFailure(error, operation: operation, phase: "preflight")
            throw error
        }
    }

    private func isMTPDuplicateError(_ error: Error) -> Bool {
        guard let kalamError = error as? KalamError else { return false }
        switch kalamError {
        case .itemAlreadyExists:
            return true
        case .nativeOperationFailed(_, let errorType, let message):
            let text = "\(errorType ?? "") \(message)".lowercased()
            return text.contains("already exists") || text.contains("duplicate") || text.contains("object exists")
        case .operationFailed(let message), .transferFailed(let message):
            let text = message.lowercased()
            return text.contains("already exists") || text.contains("duplicate") || text.contains("object exists")
        default:
            return false
        }
    }

    private func reportMutationFailure(_ error: Error, operation: String, phase: String) {
        ErrorLogger.log(
            error,
            message: "MTP mutation failed",
            userInfo: [
                "operation": operation,
                "operation_phase": phase,
                "native_error_type": nativeErrorType(for: error),
                "conflict_classification": isMTPDuplicateError(error) ? "duplicate_name" : "native_or_transport_failure",
                "reconciliation_result": "not_started"
            ]
        )
    }

    public func checkFilesExist(files: [String]) async throws -> [Bool] {
        guard isConnected, let storageId = selectedStorageId else {
            throw KalamError.deviceNotConnected
        }
        
        return try await bridge.checkFilesExist(storageId: storageId, paths: files)
    }

}
