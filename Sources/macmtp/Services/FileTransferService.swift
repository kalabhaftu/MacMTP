import Foundation
import SwiftUI
import UserNotifications

extension Notification.Name {
    static let localDirectoryNeedsRefresh = Notification.Name("localDirectoryNeedsRefresh")
    static let menuNewFolderRequested = Notification.Name("menuNewFolderRequested")
    static let menuRefreshRequested = Notification.Name("menuRefreshRequested")
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
    private var transferInFlight = false
    
    
    private init() {}
    
    
    public func pauseTransfer() {
        guard activeBatch?.state == .transferring else { return }
        pauseRequested = true
        activeBatch?.pause()
    }
    
    public func resumeTransfer() {
        guard activeBatch?.state == .paused else { return }
        pauseRequested = false
        activeBatch?.resume()
    }
    
    public func cancelTransfer() {
        cancelRequested = true
        activeBatch?.cancel()
        
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
    
    
    public func initiateTransfer(
        sources: [FileNode],
        destinationDir: String,
        direction: TransferDirection,
        storageId: UInt32? = nil,
        isCut: Bool = false
    ) {
        guard !transferInFlight else {
            ErrorLogger.logMessage("Ignored transfer request while another transfer is active.")
            return
        }

        self.isCutOperation = isCut
        self.cutSourcePaths = isCut ? sources.map { $0.path } : []
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
                ErrorLogger.log(error, message: "File transfer failed")
                activeBatch?.cancel()
                postTransferNotification(
                    title: "Transfer Failed",
                    body: error.localizedDescription,
                    isError: true
                )
                isCutOperation = false
                cutSourcePaths = []
            }
        }
    }
    
    
    public func postTransferNotification(title: String, body: String, isError: Bool = false) {
        Task { @MainActor in
            do {
                let center = UNUserNotificationCenter.current()
                let granted = try await center.requestAuthorization(options: [.alert, .sound])
                guard granted else { return }
                let content = UNMutableNotificationContent()
                content.title = title
                content.body = body
                content.sound = isError ? .default : nil
                let request = UNNotificationRequest(
                    identifier: "transfer-\(UUID().uuidString)",
                    content: content,
                    trigger: nil
                )
                try await center.add(request)
            } catch {
                ErrorLogger.log(error, message: "Failed to post notification")
            }
        }
    }
    
    
    private func performTransfer(
        sources: [FileNode],
        destinationDir: String,
        direction: TransferDirection,
        storageId: UInt32?
    ) async throws {
        if let batch = activeBatch, !batch.state.isTerminal {
            throw KalamError.operationInProgress
        }

        let shouldDeleteSourcesAfterTransfer = isCutOperation
        let sourcePathsToDeleteAfterTransfer = cutSourcePaths

        cancelRequested = false
        pauseRequested = false
        verifiedDirectories.removeAll()
        showConflictDialog = false
        conflictingFiles = []
        totalFileCount = 0
    if let oldContinuation = conflictContinuation {
            conflictContinuation = nil
            oldContinuation.resume(returning: (.cancel, true))
        }
        
        if (direction == .localToMTP || direction == .mtpToLocal) && storageId == nil {
            throw NSError(domain: "FileTransferService", code: 1, userInfo: [NSLocalizedDescriptionKey: "Storage ID is required for MTP transfers"])
        }
        
        let mStorageId = storageId ?? 0
        
        let expandedItems = try await expandSources(sources: sources, direction: direction, storageId: mStorageId)
        
        if cancelRequested { return }
        guard !expandedItems.isEmpty else {
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
        if cancelRequested { return }
        
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
                    self.activeBatch = nil
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
        
        let batch = TransferBatch()
        batch.items = transferQueue
        self.activeBatch = batch
        
        batch.start()
        
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
        
        var groups: [String: [Int]] = [:] // destParent -> array of indices
        var groupOrder: [String] = []
        for index in batch.items.indices {
            if batch.items[index].status == .skipped { continue }
            let destParent = (batch.items[index].destinationPath as NSString).deletingLastPathComponent
            if groups[destParent] == nil {
                groupOrder.append(destParent)
            }
            groups[destParent, default: []].append(index)
        }
        
        let chunkSize = 50 // Balance between bulk performance and cancellation responsiveness
        
        for destParent in groupOrder {
            guard let indices = groups[destParent] else { continue }
            if cancelRequested { break }
            
            do {
                try await ensureDirectoryExists(path: destParent, direction: direction, storageId: storageId)
            } catch {
                ErrorLogger.log(error, message: "FileTransferService: Failed to create parent directory \(destParent)")
                for idx in indices {
                    var itm = batch.items[idx]
                    itm.markFailed(error.localizedDescription)
                    batch.items[idx] = itm
                }
                continue // Skip this group
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
                    switch direction {
                    case .localToMTP:
                        try await bridge.uploadFiles(
                            storageId: storageId,
                            sources: sources,
                            destination: destParent,
                            onPreprocess: { _ in },
                            onProgress: { [weak self] progressInfo in
                                guard let self = self else { return }
                                let sent = progressInfo.activeFileSize.sent
                                let speedMB = progressInfo.speed
                                Task { @MainActor in
                                    self.updateActiveItemProgress(sourcePath: progressInfo.fullPath, sent: sent, speedMB: speedMB)
                                }
                            }
                        )
                    case .mtpToLocal:
                        try await bridge.downloadFiles(
                            storageId: storageId,
                            sources: sources,
                            destination: destParent,
                            onPreprocess: { _ in },
                            onProgress: { [weak self] progressInfo in
                                guard let self = self else { return }
                                let sent = progressInfo.activeFileSize.sent
                                let speedMB = progressInfo.speed
                                Task { @MainActor in
                                    self.updateActiveItemProgress(sourcePath: progressInfo.fullPath, sent: sent, speedMB: speedMB)
                                }
                            }
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
                    ErrorLogger.log(error, message: "FileTransferService: File copy failed for chunk in \(destParent)")
                    for idx in chunkIndices {
                        var itm = batch.items[idx]
                        if itm.status != .completed && itm.bytesTransferred < itm.fileSize {
                            itm.markFailed(error.localizedDescription)
                            batch.items[idx] = itm
                        }
                    }
                }
            }
        }
        
        if cancelRequested {
            batch.cancel()
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
                                    ErrorLogger.log(error, message: "FileTransferService: Failed to trash cut source \(path)")
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
        Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            if self.activeBatch === completedBatch {
                self.activeBatch = nil
            }
        }
    }
    
    
    private func updateActiveItemProgress(sourcePath: String, sent: Int64, speedMB: Double) {
        guard let batch = activeBatch,
              let index = batch.items.firstIndex(where: { $0.sourcePath == sourcePath }) else { return }
        
        batch.currentItemIndex = index
        var item = batch.items[index]
        item.bytesTransferred = min(sent, item.fileSize)
        item.speed = speedMB * 1024 * 1024 // Convert MB/s to Bytes/s
        
        if item.speed > 0 {
            let remainingBytes = Double(item.fileSize - item.bytesTransferred)
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
    
    
    private struct ScannedItem {
        let absolutePath: String
        let relativePath: String // Relative to the drag selection parent
        let isDirectory: Bool
        let size: Int64
        let modificationDate: Date
    }
    
    
    private func getRelativePath(path: String, baseParent: String) -> String {
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
                try expandLocalPath(
                    path: source.path,
                    baseParent: parentDir,
                    into: &expanded
                )
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
    
    private func expandLocalPath(path: String, baseParent: String, depth: Int = 0, into list: inout [ScannedItem]) throws {
        guard depth < 100 else {
            throw KalamError.operationFailed("Directory structure is too deep")
        }
        
        let fileManager = FileManager.default
        var isDir: ObjCBool = false
        
        guard fileManager.fileExists(atPath: path, isDirectory: &isDir) else { return }
        
        let relativePath = getRelativePath(path: path, baseParent: baseParent)
        
        let attributes = try fileManager.attributesOfItem(atPath: path)
        let size = (attributes[.size] as? Int64) ?? 0
        let date = (attributes[.modificationDate] as? Date) ?? Date()
        
        if isDir.boolValue {
            list.append(ScannedItem(absolutePath: path, relativePath: relativePath, isDirectory: true, size: 0, modificationDate: date))
            
            let contents = try fileManager.contentsOfDirectory(atPath: path)
            for child in contents {
                let childPath = (path as NSString).appendingPathComponent(child)
                try expandLocalPath(path: childPath, baseParent: baseParent, depth: depth + 1, into: &list)
            }
        } else {
            list.append(ScannedItem(absolutePath: path, relativePath: relativePath, isDirectory: false, size: size, modificationDate: date))
        }
    }
    
    private func expandMTPPath(path: String, baseParent: String, storageId: UInt32, into list: inout [ScannedItem]) async throws {
        let relativePath = getRelativePath(path: path, baseParent: baseParent)
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
                    let childRel = getRelativePath(path: child.path, baseParent: baseParent)
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
                    ErrorLogger.log(error, message: "FileTransferService: Failed to read conflict metadata for \(parent)")
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
            let fileManager = FileManager.default
            for (index, destPath) in destinationPaths.enumerated() {
                var isDir: ObjCBool = false
                if fileManager.fileExists(atPath: destPath, isDirectory: &isDir) {
                    let srcItem = items[index]
                    
                    let attributes = (try? fileManager.attributesOfItem(atPath: destPath)) ?? [:]
                    let destSize = (attributes[.size] as? Int64) ?? 0
                    let destDate = (attributes[.modificationDate] as? Date) ?? Date()
                    
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
            }
        }
        
        return conflicts
    }
    
    
    private func ensureDirectoryExists(path: String, direction: TransferDirection, storageId: UInt32) async throws {
        if verifiedDirectories.contains(path) { return }
        
        if direction == .localToMTP {
            let existResult = try await bridge.checkFilesExist(storageId: storageId, paths: [path])
            if let exists = existResult.first, exists {
                verifiedDirectories.insert(path)
                return
            }
            
            let parent = (path as NSString).deletingLastPathComponent
            if parent != "/" && !parent.isEmpty {
                try await ensureDirectoryExists(path: parent, direction: direction, storageId: storageId)
            }
            
            try await bridge.makeDirectory(storageId: storageId, path: path)
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
}
