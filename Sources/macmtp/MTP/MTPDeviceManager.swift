import Foundation
import SwiftUI

struct MTPDirectoryRefreshKey: Equatable, Sendable {
    let storageId: UInt32
    let path: String
    let showHidden: Bool
}

enum MTPRefreshRules {
    static func sharesRequest(active: MTPDirectoryRefreshKey?, requested: MTPDirectoryRefreshKey) -> Bool {
        active == requested
    }
}

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

    private var activeDirectoryRefreshRequest: MTPDirectoryRefreshKey?
    private var activeRefreshWaiterCount = 0
    private var directoryRefreshWaiters: [CheckedContinuation<Void, Never>] = []
    private var mutationInFlight = false
    private var mutationWaiters: [CheckedContinuation<Void, Never>] = []

    private init() {}


    public var canNavigateBack: Bool {
        !backHistory.isEmpty
    }

    public var canNavigateForward: Bool {
        !forwardHistory.isEmpty
    }


    public func connectDevice() async {
        guard !isLoading, !isConnected else { return }
        isLoading = true
        errorMessage = nil

        do {
            let goDevInfo = try await bridge.initialize()
            
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
            try? await bridge.dispose()

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

    func invalidateConnection(message: String) {
        refreshGeneration &+= 1
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
        await waitForMutation()
        await refreshFilesWithoutWaitingForMutation()
    }

    private func currentDirectoryRefreshRequest() -> MTPDirectoryRefreshKey? {
        guard isConnected, let storageId = selectedStorageId else { return nil }
        let showHidden = UserDefaults.standard.object(forKey: "showHiddenFilesMTP") as? Bool ?? false
        return MTPDirectoryRefreshKey(storageId: storageId, path: currentMTPPath, showHidden: showHidden)
    }

    private func waitForMutation() async {
        guard mutationInFlight else { return }
        await withCheckedContinuation { continuation in
            mutationWaiters.append(continuation)
        }
    }

    private func beginMutation() async {
        await waitForMutation()
        mutationInFlight = true
    }

    private func endMutation() {
        mutationInFlight = false
        let waiters = mutationWaiters
        mutationWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    private func finishDirectoryRefresh(_ request: MTPDirectoryRefreshKey) {
        activeDirectoryRefreshRequest = nil
        let waiters = directoryRefreshWaiters
        directoryRefreshWaiters.removeAll()
        waiters.forEach { $0.resume() }

        if !isConnected || currentDirectoryRefreshRequest() == request {
            isLoading = false
        }
    }

    private func refreshFilesWithoutWaitingForMutation() async {
        guard let request = currentDirectoryRefreshRequest() else { return }

        if let activeRequest = activeDirectoryRefreshRequest {
            activeRefreshWaiterCount += 1
            await withCheckedContinuation { continuation in
                directoryRefreshWaiters.append(continuation)
            }

            // A navigation or storage change while the shared request was in
            // flight needs its own request. Callers for the same directory
            // share the completed result.
            if !MTPRefreshRules.sharesRequest(active: activeRequest, requested: request)
                || currentDirectoryRefreshRequest() != request {
                await refreshFilesWithoutWaitingForMutation()
            }
            return
        }

        activeDirectoryRefreshRequest = request
        activeRefreshWaiterCount = 0
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
                  currentDirectoryRefreshRequest() == request else { return }

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
            guard generation == refreshGeneration,
                  currentDirectoryRefreshRequest() == request else { return }
            ErrorLogger.log(
                error,
                message: "Failed to list MTP directory",
                userInfo: [
                    "operation": "list_directory",
                    "is_root": request.path == "/",
                    "path_depth": request.path.split(separator: "/").count,
                    "device_connected": isConnected,
                    "retry_count": retryCount,
                    "refresh_coalesced": activeRefreshWaiterCount > 0,
                    "refresh_waiter_count": activeRefreshWaiterCount,
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


    public func createFolder(name: String, in targetPath: String? = nil) async throws {
        let normalizedName = try normalizedMTPChildName(name)
        await beginMutation()
        defer { endMutation() }

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

        do {
            try await bridge.makeDirectory(storageId: storageId, path: fullPath)
        } catch {
            let existsAfterFailure = (try? await bridge.checkFilesExist(storageId: storageId, paths: [fullPath]).first) == true
            if existsAfterFailure {
                throw KalamError.itemAlreadyExists(normalizedName)
            }
            throw error
        }

        await refreshFilesWithoutWaitingForMutation()
        if !mtpFiles.contains(where: { $0.path == fullPath && $0.isDirectory }) {
            try? await Task.sleep(nanoseconds: 150_000_000)
            await refreshFilesWithoutWaitingForMutation()
        }
        await refreshStorages()
    }

    public func deleteFiles(paths: [String]) async throws {
        guard !paths.isEmpty else { return }
        await beginMutation()
        defer { endMutation() }
        guard isConnected, let storageId = selectedStorageId else {
            throw KalamError.deviceNotConnected
        }
        try await bridge.deleteFiles(storageId: storageId, paths: paths)
        await refreshFilesWithoutWaitingForMutation()
        await refreshStorages()
    }

    public func renameFile(path: String, newName: String) async throws {
        let normalizedName = try normalizedMTPChildName(newName)
        await beginMutation()
        defer { endMutation() }
        guard isConnected, let storageId = selectedStorageId else {
            throw KalamError.deviceNotConnected
        }
        try await bridge.renameFile(storageId: storageId, path: path, newName: normalizedName)
        await refreshFilesWithoutWaitingForMutation()
    }

    public func checkFilesExist(files: [String]) async throws -> [Bool] {
        guard isConnected, let storageId = selectedStorageId else {
            throw KalamError.deviceNotConnected
        }
        
        return try await bridge.checkFilesExist(storageId: storageId, paths: files)
    }

}
