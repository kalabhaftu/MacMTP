import Foundation
import SwiftUI
@preconcurrency import UserNotifications

extension Notification.Name {
    static let localDirectoryNeedsRefresh = Notification.Name("localDirectoryNeedsRefresh")
    static let fileTypeaheadKeyPressed = Notification.Name("fileTypeaheadKeyPressed")
    static let fileTypeaheadReset = Notification.Name("fileTypeaheadReset")
    static let menuNewFolderRequested = Notification.Name("menuNewFolderRequested")
    static let menuRefreshRequested = Notification.Name("menuRefreshRequested")
    static let menuCopyRequested = Notification.Name("menuCopyRequested")
    static let menuPasteRequested = Notification.Name("menuPasteRequested")
}

@MainActor
public final class FileTransferService: ObservableObject {
    
    
    public static let shared = FileTransferService()
    
    
    @Published public var activeBatch: TransferBatch?
    
    @Published public var showConflictDialog = false
    
    @Published public var conflictingFiles: [ConflictingFilePair] = []
    
    @Published public var totalFileCount: Int = 0
    
    
    private let bridge = KalamBridge.shared
    private var cancelRequested = false
    private var pauseRequested = false
    private var conflictContinuation: CheckedContinuation<(ConflictResolution, Bool), Never>?
    
    private var conflictProcessIndex: Int = 0
    
    private var isCutOperation: Bool = false
    
    private var cutSourcePaths: [String] = []
    
    private var verifiedDirectories = Set<String>()
    @Published private(set) var transferInFlight = false

    public var isTransferInFlight: Bool {
        transferInFlight
    }
    
    
    private init() {}
    
    
    @discardableResult
    public func pauseTransfer() -> Bool {
        guard activeBatch?.state == .transferring else { return false }
        pauseRequested = true
        activeBatch?.pause()
        return true
    }
    
    public func resumeTransfer() {
        guard activeBatch?.state == .paused else { return }
        pauseRequested = false
        activeBatch?.resume()
    }
    
    public func cancelTransfer() {
        cancelRequested = true
        if transferInFlight {
            bridge.cancelTransfer()
        }
        if let batch = activeBatch {
            batch.beginCancellation()
        }
        
        if let continuation = conflictContinuation {
            conflictContinuation = nil
            continuation.resume(returning: (.cancel, true))
            showConflictDialog = false
        }
        
        isCutOperation = false
        cutSourcePaths = []
    }
    
    public func resolveConflicts(with resolution: ConflictResolution, rememberForBatch: Bool = true) {
        guard let continuation = conflictContinuation else { return }
        conflictContinuation = nil
        continuation.resume(returning: (resolution, rememberForBatch))
        showConflictDialog = false
    }
    
    
    @discardableResult
    public func initiateTransfer(
        sources: [FileNode],
        destinationDir: String,
        direction: TransferDirection,
        storageId: UInt32? = nil,
        isCut: Bool = false
    ) -> Bool {
        guard !transferInFlight, activeBatch?.state.isTerminal != false else {
            ErrorLogger.logMessage(
                "Rejected transfer request while another transfer is active.",
                level: .warning,
                userInfo: ["has_active_batch": activeBatch != nil]
            )
            return false
        }
        if direction == .localToMTP || direction == .mtpToLocal {
            guard let storageId, storageId != 0 else {
                ErrorLogger.logMessage(
                    "Rejected MTP transfer because no valid storage is selected.",
                    level: .warning
                )
                return false
            }
            guard MTPDeviceManager.shared.isConnected else {
                ErrorLogger.logMessage(
                    "Rejected MTP transfer because the device session is not connected.",
                    level: .warning,
                    userInfo: ["operation": "transfer", "connection_state": "disconnected"]
                )
                return false
            }
        }

        guard !sources.isEmpty else {
            return false
        }

        self.isCutOperation = isCut
        self.cutSourcePaths = isCut ? sources.map { $0.path } : []
        cancelRequested = false
        let pendingBatch = TransferBatch()
        pendingBatch.start()
        activeBatch = pendingBatch
        transferInFlight = true
        Task {
            defer { self.transferInFlight = false }
            do {
                try await performTransfer(
                    sources: sources,
                    destinationDir: destinationDir,
                    direction: direction,
                    storageId: storageId
                )
            } catch {
                if cancelRequested || isMTPTransferCancellation(error) {
                    activeBatch?.finishCancellation()
                    postTransferNotification(
                        title: "Transfer Cancelled",
                        body: "The transfer stopped before the native session was reused.",
                        isError: false
                    )
                    // Auto-dismiss cancelled transfer progress bar after 1.5 seconds.
                    let cancelledBatch = self.activeBatch
                    self.dismissBatchWhenTransferSettles(cancelledBatch, after: 1_500_000_000)
                } else {
                    ErrorLogger.log(error, message: "File transfer failed")
                    activeBatch?.state = .failed(error.localizedDescription)
                    if isMTPTransportFailure(error) {
                        MTPDeviceManager.shared.invalidateConnection(
                            message: "The MTP connection stopped responding. Reconnect your Android device and try again.",
                            reconnectAutomatically: shouldAutomaticallyReconnectMTP(error)
                        )
                    }
                    postTransferNotification(
                        title: "Transfer Failed",
                        body: error.localizedDescription,
                        isError: true
                    )
                    // Auto-dismiss failed transfer progress bar after 3 seconds.
                    let failedBatch = self.activeBatch
                    self.dismissBatchWhenTransferSettles(failedBatch, after: 3_000_000_000)
                }
                isCutOperation = false
                cutSourcePaths = []
            }
        }
        return true
    }
    
    
    public func postTransferNotification(title: String, body: String, isError: Bool = false) {
        Task { @MainActor in
            let center = UNUserNotificationCenter.current()
            let settings = await center.notificationSettings()
            guard settings.authorizationStatus != .denied else { return }

            if settings.authorizationStatus == .notDetermined {
                let granted = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
                guard granted else { return }
            }

            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = isError ? .default : nil
            let request = UNNotificationRequest(
                identifier: "transfer-\(UUID().uuidString)",
                content: content,
                trigger: nil
            )
            do {
                try await center.add(request)
            } catch let error as NSError where error.domain == UNErrorDomain && error.code == UNError.notificationsNotAllowed.rawValue {
                return
            } catch {
                ErrorLogger.logMessage("Notification posting failed: \(error.localizedDescription)", level: .info)
            }
        }
    }
    
    
    private func performTransfer(
        sources: [FileNode],
        destinationDir: String,
        direction: TransferDirection,
        storageId: UInt32?
    ) async throws {
        guard let batch = activeBatch else { throw KalamError.operationInProgress }

        let shouldDeleteSourcesAfterTransfer = isCutOperation
        let sourcePathsToDeleteAfterTransfer = cutSourcePaths

        pauseRequested = false
        verifiedDirectories.removeAll()
        showConflictDialog = false
        conflictingFiles = []
        totalFileCount = 0
        if let oldContinuation = conflictContinuation {
            conflictContinuation = nil
            oldContinuation.resume(returning: (.cancel, true))
        }
        
        guard let mStorageId = storageId, mStorageId != 0 else {
            throw KalamError.deviceNotConnected
        }
        guard MTPDeviceManager.shared.isConnected else {
            throw KalamError.deviceNotConnected
        }
        
        let expandedItems = try await expandSources(sources: sources, direction: direction, storageId: mStorageId)
        
        if cancelRequested {
            batch.finishCancellation()
            return
        }
        guard !expandedItems.isEmpty else {
            batch.complete()
            return
        }
        
        self.totalFileCount = expandedItems.filter { !$0.isDirectory }.count
        
        let fileItems = expandedItems.filter { !$0.isDirectory }
        let conflicts = try await scanForConflicts(
            items: fileItems,
            destinationDir: destinationDir,
            direction: direction,
            storageId: mStorageId
        )
        if cancelRequested {
            batch.finishCancellation()
            return
        }
        
        var chosenResolution: ConflictResolution = .askEach
        var rememberForBatch = true
        var resolvedConflicts: [String: ConflictResolution] = [:]
        
        if !conflicts.isEmpty {
            conflictProcessIndex = 0
            while conflictProcessIndex < conflicts.count {
                self.conflictingFiles = Array(conflicts[conflictProcessIndex...])
                self.showConflictDialog = true
                
                (chosenResolution, rememberForBatch) = await withCheckedContinuation { continuation in
                    self.conflictContinuation = continuation
                }
                
                if chosenResolution == .cancel {
                    if cancelRequested {
                        batch.finishCancellation()
                    } else {
                        self.activeBatch = nil
                    }
                    return
                }
                
                if rememberForBatch {
                    for i in conflictProcessIndex..<conflicts.count {
                        resolvedConflicts[conflicts[i].sourcePath] = chosenResolution
                    }
                    await MainActor.run {
                        self.showConflictDialog = false
                    }
                    break
                } else {
                    resolvedConflicts[conflicts[conflictProcessIndex].sourcePath] = chosenResolution
                    conflictProcessIndex += 1
                    try? await Task.sleep(nanoseconds: 300_000_000)
                }
            }
        }
        
        var transferQueue: [TransferItem] = []
        for item in fileItems {
            let relativePath = item.relativePath
            let destPath = (destinationDir as NSString).appendingPathComponent(relativePath)
            
            let sourceFull = item.absolutePath
            let fileName = (relativePath as NSString).lastPathComponent
            
            var status: TransferStatus = .queued
            
            if let fileResolution = resolvedConflicts[sourceFull] {
                switch fileResolution {
                case .skip:
                    status = .skipped
                case .skipIfSameSize:
                    if let conflict = conflicts.first(where: { $0.sourcePath == sourceFull }),
                       conflict.sourceSize == conflict.destinationSize {
                        status = .skipped
                    }
                case .overwriteIfDifferent:
                    if let conflict = conflicts.first(where: { $0.sourcePath == sourceFull }),
                       conflict.sourceSize == conflict.destinationSize {
                        status = .skipped
                    }
                case .overwrite:
                    status = .queued
                default:
                    status = .queued
                }
            }
            
            var transItem = TransferItem(
                sourcePath: sourceFull,
                destinationPath: destPath,
                fileName: fileName,
                fileSize: item.size,
                direction: direction,
                status: status
            )
            if status == .skipped {
                transItem.markSkipped()
            }
            transferQueue.append(transItem)
        }

        guard !cancelRequested else {
            batch.finishCancellation()
            return
        }
        
        batch.items = transferQueue
        guard !batch.isCancelling, !cancelRequested else {
            batch.finishCancellation()
            return
        }
        
        await runQueue(
            storageId: mStorageId,
            direction: direction,
            shouldDeleteSourcesAfterTransfer: shouldDeleteSourcesAfterTransfer,
            sourcePathsToDeleteAfterTransfer: sourcePathsToDeleteAfterTransfer
        )
    }
    
    
    private func runQueue(
        storageId: UInt32,
        direction: TransferDirection,
        shouldDeleteSourcesAfterTransfer: Bool,
        sourcePathsToDeleteAfterTransfer: [String]
    ) async {
        guard let batch = activeBatch else { return }
        
        var groups: [String: [Int]] = [:]
        var groupOrder: [String] = []
        for index in batch.items.indices {
            if batch.items[index].status == .skipped { continue }
            let destParent = (batch.items[index].destinationPath as NSString).deletingLastPathComponent
            if groups[destParent] == nil {
                groupOrder.append(destParent)
            }
            groups[destParent, default: []].append(index)
        }
        
        // Bound batches so native directory caches survive across files while
        // progress callbacks still observe cancellation during each file.
        let chunkSize = 16
        
        var terminalTransferError: Error?

        queueLoop: for destParent in groupOrder {
            guard let indices = groups[destParent] else { continue }
            if cancelRequested { break }
            
            do {
                try await ensureDirectoryExists(path: destParent, direction: direction, storageId: storageId)
            } catch {
                ErrorLogger.log(error, message: "FileTransferService: Failed to create parent directory")
                let formattedErr = formatTransferError(error)
                if !shouldPresentAsCancelledAfterRecoveryFailure(error, cancelRequested: cancelRequested)
                    && !isMTPTransferCancellation(error) {
                    for idx in indices {
                        var itm = batch.items[idx]
                        itm.markFailed(formattedErr)
                        batch.items[idx] = itm
                    }
                }
                if isMTPTransportFailure(error) {
                    terminalTransferError = error
                    break queueLoop
                }
                if cancelRequested || isMTPTransferCancellation(error) {
                    break queueLoop
                }
                continue
            }
            
            for chunkStart in stride(from: 0, to: indices.count, by: chunkSize) {
                if cancelRequested { break }
                
                while pauseRequested && !cancelRequested {
                    try? await Task.sleep(nanoseconds: 100_000_000)
                }
                
                if cancelRequested { break }
                
                let chunkIndices = Array(indices[chunkStart..<min(chunkStart + chunkSize, indices.count)])
                let sources = chunkIndices.map { batch.items[$0].sourcePath }
                
                for idx in chunkIndices {
                    var itm = batch.items[idx]
                    itm.status = .preprocessing
                    batch.items[idx] = itm
                }
                
                do {
                    final class ProgressThrottler: @unchecked Sendable {
                        private let lock = NSLock()
                        private var lastNano: UInt64 = 0
                        func shouldDispatch(isFinal: Bool) -> Bool {
                            lock.lock()
                            defer { lock.unlock() }
                            let now = DispatchTime.now().uptimeNanoseconds
                            if isFinal || (now &- lastNano) >= 66_000_000 {
                                lastNano = now
                                return true
                            }
                            return false
                        }
                    }
                    let throttler = ProgressThrottler()
                    let progressIndices = chunkIndices.reduce(into: [String: Int]()) { result, index in
                        result[batch.items[index].destinationPath] = index
                    }
                    let handleProgress: @Sendable (GoTransferProgressInfo) -> Void = { [weak self] progressInfo in
                        guard let self = self else { return }
                        // Native emits empty-path heartbeats while it is walking
                        // a large source. They feed the transfer watchdog but
                        // must not move a visible file to 0-byte progress.
                        guard !progressInfo.fullPath.isEmpty else { return }
                        let index = progressIndices[progressInfo.fullPath] ?? chunkIndices.first
                        guard let index else { return }
                        let sent = progressInfo.activeFileSize.sent
                        let total = progressInfo.activeFileSize.total
                        let speedMB = progressInfo.speed
                        let isFinal = total > 0 && sent >= total

                        guard throttler.shouldDispatch(isFinal: isFinal) else { return }

                        Task { @MainActor in
                            self.updateActiveItemProgress(index: index, sent: sent, total: total, speedMB: speedMB)
                        }
                    }

                    switch direction {
                    case .localToMTP:
                        try await bridge.uploadFiles(
                            storageId: storageId,
                            sources: sources,
                            destination: destParent,
                            onPreprocess: { _ in },
                            onProgress: handleProgress
                        )
                    case .mtpToLocal:
                        try await bridge.downloadFiles(
                            storageId: storageId,
                            sources: sources,
                            destination: destParent,
                            onPreprocess: { _ in },
                            onProgress: handleProgress
                        )
                    }
                    
                    for idx in chunkIndices {
                        var itm = batch.items[idx]
                        if itm.status != .completed {
                            itm.markCompleted()
                            batch.items[idx] = itm
                        }
                    }
                    
                } catch {
                    if isMTPTransferCancellation(error) {
                        break queueLoop
                    }

                    let isUnexpectedFailure = !error.localizedDescription.lowercased().contains("libusb_error_no_device")
                        && !error.localizedDescription.lowercased().contains("device not connected")
                    let shouldReport = shouldReportMTPTransportFailure(
                        error,
                        connectionIsActive: MTPDeviceManager.shared.isConnected
                    ) || isUnexpectedFailure

                    if shouldReport {
                        ErrorLogger.log(
                            error,
                            message: "FileTransferService: File copy failed for chunk",
                            userInfo: [
                                "operation": "transfer",
                                "total_files": batch.totalFileCount,
                                "completed_files": batch.completedFileCount,
                                "bytes_transferred": batch.totalBytesTransferred,
                                "connection_active": MTPDeviceManager.shared.isConnected,
                                "native_error_type": nativeErrorType(for: error)
                            ]
                        )
                    } else {
                        ErrorLogger.logMessage(
                            "MTP transfer stopped after the Android device disconnected",
                            level: .warning,
                            userInfo: [
                                "operation": "transfer",
                                "operation_phase": "transfer",
                                "connection_state": "disconnected",
                                "native_error_type": nativeErrorType(for: error)
                            ]
                        )
                    }
                    let cancellationRecoveryFailure = shouldPresentAsCancelledAfterRecoveryFailure(
                        error,
                        cancelRequested: cancelRequested
                    )
                    if !cancellationRecoveryFailure {
                        for idx in chunkIndices {
                            var itm = batch.items[idx]
                            if itm.status != .completed && itm.bytesTransferred < itm.fileSize {
                                itm.markFailed(error.localizedDescription)
                                batch.items[idx] = itm
                            }
                        }
                    }
                    if isMTPTransportFailure(error) {
                        terminalTransferError = error
                        break queueLoop
                    }
                }
            }
        }

        if let terminalTransferError {
            let message = formatTransferError(terminalTransferError)
            let reconnectAutomatically = shouldAutomaticallyReconnectMTP(terminalTransferError)
            let cancellationRecoveryFailure = shouldPresentAsCancelledAfterRecoveryFailure(
                terminalTransferError,
                cancelRequested: cancelRequested
            )
            if !cancellationRecoveryFailure {
                for index in batch.items.indices where !batch.items[index].status.isTerminal {
                    var item = batch.items[index]
                    item.markFailed(message)
                    batch.items[index] = item
                }
            }
            MTPDeviceManager.shared.invalidateConnection(
                message: reconnectAutomatically
                    ? "Transfer cancellation interrupted the MTP session. Reconnecting…"
                    : "The MTP connection stopped responding. Reconnect your Android device and try again.",
                reconnectAutomatically: reconnectAutomatically
            )
        }
        
        if let terminalTransferError {
            let title = batch.completedFileCount == 0 ? "Transfer Failed" : "Transfer Aborted"
            let errorDetail = formatTransferError(terminalTransferError)
            if shouldPresentAsCancelledAfterRecoveryFailure(terminalTransferError, cancelRequested: cancelRequested) {
                batch.finishCancellation()
                postTransferNotification(
                    title: "Transfer Cancelled",
                    body: "\(batch.completedFileCount) of \(batch.totalFileCount) files copied. Session recovery failed; reconnecting.",
                    isError: true
                )
            } else {
                batch.complete()
                postTransferNotification(
                    title: title,
                    body: "\(batch.completedFileCount) of \(batch.totalFileCount) files copied. \(errorDetail)",
                    isError: true
                )
            }
        } else if cancelRequested {
            batch.finishCancellation()
            let completed = batch.totalBytesTransferred > 0
                ? " (\(FormatUtils.formatBytes(batch.totalBytesTransferred)) transferred)"
                : ""
            postTransferNotification(
                title: "Transfer Cancelled",
                body: "\(batch.completedFileCount) of \(batch.totalFileCount) files copied\(completed)",
                isError: false
            )
        } else {
            let failedCount = batch.failedFileCount
            batch.complete()
            
            if shouldDeleteSourcesAfterTransfer && !sourcePathsToDeleteAfterTransfer.isEmpty {
                let failedItems = batch.items.filter { $0.status == .failed }
                if failedItems.isEmpty {
                    do {
                        if direction == .mtpToLocal {
                            try await bridge.deleteFiles(
                                storageId: storageId,
                                paths: sourcePathsToDeleteAfterTransfer
                            )
                        } else {
                            let fileManager = FileManager.default
                            for path in sourcePathsToDeleteAfterTransfer {
                                do {
                                    try fileManager.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: nil)
                                } catch {
                                    ErrorLogger.log(error, message: "FileTransferService: Failed to trash cut source")
                                }
                            }
                        }
                    } catch {
                        ErrorLogger.log(error, message: "FileTransferService: Failed to delete source files after cut")
                    }
                }
            }
            isCutOperation = false
            cutSourcePaths = []
            
            if failedCount > 0 {
                postTransferNotification(
                    title: "Transfer Completed with Errors",
                    body: "\(batch.completedFileCount) files copied, \(failedCount) failed",
                    isError: true
                )
            } else {
                let totalBytes = FormatUtils.formatBytes(batch.totalBytesTransferred)
                postTransferNotification(
                    title: "Transfer Complete",
                    body: "\(batch.totalFileCount) files (\(totalBytes)) copied successfully",
                    isError: false
                )
            }
            await MainActor.run {
                NotificationCenter.default.post(name: .localDirectoryNeedsRefresh, object: nil)
                Task {
                    await MTPDeviceManager.shared.refreshFiles()
                    await MTPDeviceManager.shared.refreshStorages()
                }
            }
        }
        
        let completedBatch = batch
        dismissBatchWhenTransferSettles(completedBatch, after: 3_000_000_000)
    }

    private func dismissBatchWhenTransferSettles(_ batch: TransferBatch?, after delay: UInt64) {
        guard let batch else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: delay)
            while self.transferInFlight {
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            if self.activeBatch === batch {
                self.activeBatch = nil
            }
        }
    }
    
    
    private func updateActiveItemProgress(index: Int, sent: Int64, total: Int64, speedMB: Double) {
        guard let batch = activeBatch, batch.items.indices.contains(index) else { return }
        
        batch.currentItemIndex = index
        var item = batch.items[index]
        if total > 0 {
            item.fileSize = total
        }
        let boundedSent = max(0, min(sent, item.fileSize))
        item.bytesTransferred = min(item.fileSize, max(item.bytesTransferred, boundedSent))
        // go-mtpx exposes decimal MB/s; the model stores bytes/s.
        item.speed = speedMB.isFinite ? max(0, speedMB * 1_000_000) : 0

        if item.speed > 0 {
            let remainingBytes = Double(max(0, item.fileSize - item.bytesTransferred))
            item.estimatedTimeRemaining = remainingBytes / item.speed
        }
        
        if item.bytesTransferred >= item.fileSize && item.fileSize > 0 {
            item.markCompleted()
        } else {
            item.markTransferring()
        }
        
        batch.items[index] = item
        
        batch.recordSpeedSample(bytesTransferredNow: batch.totalBytesTransferred)
    }
    
    
    private struct ScannedItem: Sendable {
        let absolutePath: String
        let relativePath: String
        let isDirectory: Bool
        let size: Int64
        let modificationDate: Date
    }

    nonisolated private static func getRelativePath(path: String, baseParent: String) -> String {
        let prefix = baseParent.hasSuffix("/") ? baseParent : baseParent + "/"
        if path.hasPrefix(prefix) {
            return String(path.dropFirst(prefix.count))
        } else if path == baseParent {
            return (path as NSString).lastPathComponent
        } else {
            return path
        }
    }

    private func expandSources(sources: [FileNode], direction: TransferDirection, storageId: UInt32) async throws -> [ScannedItem] {
        var expanded: [ScannedItem] = []

        for source in sources {
            let parentDir = source.parentPath.isEmpty
                ? (source.path as NSString).deletingLastPathComponent
                : source.parentPath

            if direction == .localToMTP {
                let localItems = try await Task.detached(priority: .userInitiated) {
                    try Self.collectLocalItems(path: source.path, baseParent: parentDir)
                }.value
                expanded.append(contentsOf: localItems)
            } else {
                try await expandMTPPath(
                    path: source.path,
                    baseParent: parentDir,
                    storageId: storageId,
                    into: &expanded
                )
            }
        }

        return expanded
    }

    nonisolated private static func collectLocalItems(path: String, baseParent: String) throws -> [ScannedItem] {
        let fileManager = FileManager.default
        var isDir: ObjCBool = false
        guard fileManager.fileExists(atPath: path, isDirectory: &isDir) else { return [] }

        let relativePath = getRelativePath(path: path, baseParent: baseParent)
        let rootURL = URL(fileURLWithPath: path)
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey]
        let values = try? rootURL.resourceValues(forKeys: Set(keys))
        let modDate = values?.contentModificationDate ?? Date()

        if isDir.boolValue {
            var items = [ScannedItem(absolutePath: path, relativePath: relativePath, isDirectory: true, size: 0, modificationDate: modDate)]

            if let enumerator = fileManager.enumerator(
                at: rootURL,
                includingPropertiesForKeys: keys,
                options: [.skipsPackageDescendants, .skipsHiddenFiles],
                errorHandler: { _, _ in true }
            ) {
                for case let fileURL as URL in enumerator {
                    if enumerator.level > PathValidation.maxDirectoryDepth {
                        enumerator.skipDescendants()
                        continue
                    }
                    if fileURL.path.count > PathValidation.maxPathLength {
                        continue
                    }
                    if fileURL.lastPathComponent.hasPrefix(".") {
                        continue
                    }
                    let subRel = getRelativePath(path: fileURL.path, baseParent: baseParent)
                    if PathValidation.hasPathCycleOrExcessiveDepth(relativePath: subRel) {
                        enumerator.skipDescendants()
                        continue
                    }

                    guard let res = try? fileURL.resourceValues(forKeys: Set(keys)) else { continue }
                    let isDirectory = res.isDirectory ?? false
                    let size = Int64(res.fileSize ?? 0)
                    let fileDate = res.contentModificationDate ?? Date()

                    items.append(ScannedItem(
                        absolutePath: fileURL.path,
                        relativePath: subRel,
                        isDirectory: isDirectory,
                        size: isDirectory ? 0 : size,
                        modificationDate: fileDate
                    ))
                }
            }
            return items
        } else {
            let size = Int64(values?.fileSize ?? 0)
            return [ScannedItem(absolutePath: path, relativePath: relativePath, isDirectory: false, size: size, modificationDate: modDate)]
        }
    }
    
    private func expandMTPPath(path: String, baseParent: String, storageId: UInt32, into list: inout [ScannedItem]) async throws {
        let relativePath = Self.getRelativePath(path: path, baseParent: baseParent)
        let parentDir = (path as NSString).deletingLastPathComponent
        
        let parentContents: [GoFileInfo]
        do {
            parentContents = try await bridge.walk(storageId: storageId, path: parentDir, recursive: false, skipHidden: false)
        } catch {
            ErrorLogger.log(error, message: "bridge.walk(parentDir) failed")
            throw error
        }
        
        guard let selfNode = parentContents.first(where: { $0.path == path }) else {
            list.append(ScannedItem(absolutePath: path, relativePath: relativePath, isDirectory: false, size: 0, modificationDate: Date()))
            return
        }
        
        let date = parseGoDate(selfNode.dateAdded)
        
        if selfNode.isFolder {
            list.append(ScannedItem(absolutePath: path, relativePath: relativePath, isDirectory: true, size: 0, modificationDate: date))
            do {
                let children = try await bridge.walk(storageId: storageId, path: path, recursive: true, skipHidden: false)
                for child in children {
                    let childRel = Self.getRelativePath(path: child.path, baseParent: baseParent)
                    if child.path.count > PathValidation.maxPathLength || PathValidation.hasPathCycleOrExcessiveDepth(relativePath: childRel) {
                        continue
                    }
                    let childDate = parseGoDate(child.dateAdded)
                    list.append(ScannedItem(absolutePath: child.path, relativePath: childRel, isDirectory: child.isFolder, size: child.size, modificationDate: childDate))
                }
            } catch {
                ErrorLogger.log(error, message: "recursive walk failed")
                throw error
            }
        } else {
            list.append(ScannedItem(absolutePath: path, relativePath: relativePath, isDirectory: false, size: selfNode.size, modificationDate: date))
        }
    }
    
    
    private func scanForConflicts(
        items: [ScannedItem],
        destinationDir: String,
        direction: TransferDirection,
        storageId: UInt32
    ) async throws -> [ConflictingFilePair] {
        var conflicts: [ConflictingFilePair] = []
        
        let destinationPaths = items.map { item -> String in
            (destinationDir as NSString).appendingPathComponent(item.relativePath)
        }
        
        if direction == .localToMTP {
            let existences = try await bridge.checkFilesExist(storageId: storageId, paths: destinationPaths)
            
            var parentDirsToWalk = Set<String>()
            for (index, exists) in existences.enumerated() where exists {
                let destPath = destinationPaths[index]
                let destParent = (destPath as NSString).deletingLastPathComponent
                parentDirsToWalk.insert(destParent)
            }
            
            var mtpFilesMetadata = [String: GoFileInfo]()
            for parent in parentDirsToWalk {
                do {
                    let contents = try await bridge.walk(
                        storageId: storageId,
                        path: parent,
                        recursive: false,
                        skipHidden: false
                    )
                    for node in contents {
                        mtpFilesMetadata[node.path] = node
                    }
                } catch {
                    ErrorLogger.log(error, message: "FileTransferService: Failed to read conflict metadata")
                }
            }
            
            for (index, exists) in existences.enumerated() where exists {
                let srcItem = items[index]
                let destPath = destinationPaths[index]
                
                let destSize = mtpFilesMetadata[destPath]?.size ?? 0
                let destDateStr = mtpFilesMetadata[destPath]?.dateAdded ?? ""
                let destDate = parseGoDate(destDateStr)
                
                conflicts.append(
                    ConflictingFilePair(
                        fileName: (destPath as NSString).lastPathComponent,
                        sourcePath: srcItem.absolutePath,
                        sourceSize: srcItem.size,
                        sourceDate: srcItem.modificationDate,
                        destinationPath: destPath,
                        destinationSize: destSize,
                        destinationDate: destDate
                    )
                )
            }
        } else {
            let conflictPairs = await Task.detached(priority: .userInitiated) {
                var localConflicts: [ConflictingFilePair] = []
                let fileManager = FileManager.default
                let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
                for (index, destPath) in destinationPaths.enumerated() {
                    var isDir: ObjCBool = false
                    if fileManager.fileExists(atPath: destPath, isDirectory: &isDir) {
                        let srcItem = items[index]
                        let url = URL(fileURLWithPath: destPath)
                        let values = try? url.resourceValues(forKeys: Set(keys))
                        let destSize = Int64(values?.fileSize ?? 0)
                        let destDate = values?.contentModificationDate ?? Date()

                        localConflicts.append(
                            ConflictingFilePair(
                                fileName: (destPath as NSString).lastPathComponent,
                                sourcePath: srcItem.absolutePath,
                                sourceSize: srcItem.size,
                                sourceDate: srcItem.modificationDate,
                                destinationPath: destPath,
                                destinationSize: destSize,
                                destinationDate: destDate
                            )
                        )
                    }
                }
                return localConflicts
            }.value
            conflicts.append(contentsOf: conflictPairs)
        }
        
        return conflicts
    }
    
    
    private func ensureDirectoryExists(path: String, direction: TransferDirection, storageId: UInt32, depth: Int = 0) async throws {
        if depth > PathValidation.maxDirectoryDepth {
            throw KalamError.invalidPath("Directory nesting exceeds maximum allowed depth: \(path)")
        }
        if path.count > PathValidation.maxPathLength {
            throw KalamError.invalidPath("Directory path exceeds maximum allowed length: \(path)")
        }
        if verifiedDirectories.contains(path) { return }
        
        if direction == .localToMTP {
            let existResult = try await bridge.checkFilesExist(storageId: storageId, paths: [path])
            if let exists = existResult.first, exists {
                verifiedDirectories.insert(path)
                return
            }
            
            let parent = (path as NSString).deletingLastPathComponent
            if parent != "/" && !parent.isEmpty && parent != path {
                try await ensureDirectoryExists(path: parent, direction: direction, storageId: storageId, depth: depth + 1)
            }
            
            _ = try await bridge.makeDirectory(storageId: storageId, path: path)
            verifiedDirectories.insert(path)
        } else {
            let fileManager = FileManager.default
            var isDir: ObjCBool = false
            if !fileManager.fileExists(atPath: path, isDirectory: &isDir) {
                try fileManager.createDirectory(atPath: path, withIntermediateDirectories: true)
            }
            verifiedDirectories.insert(path)
        }
    }
    
    
    private func parseGoDate(_ dateStr: String) -> Date {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS'Z'"
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.date(from: dateStr) ?? Date()
    }

    private func formatTransferError(_ error: Error) -> String {
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain && nsError.code == 513 {
            return "Permission denied: Destination directory is read-only or not writable."
        }
        return error.localizedDescription
    }

}
