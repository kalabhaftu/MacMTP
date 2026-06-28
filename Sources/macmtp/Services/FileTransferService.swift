import Foundation
import SwiftUI
import Combine
import UserNotifications

extension Notification.Name {
    static let localDirectoryNeedsRefresh = Notification.Name("localDirectoryNeedsRefresh")
}

@MainActor
public final class FileTransferService: ObservableObject {
    
    // MARK: - Singleton
    
    public static let shared = FileTransferService()
    
    // MARK: - Published Properties
    
    @Published public var activeBatch: TransferBatch?
    
    @Published public var showConflictDialog = false
    
    @Published public var conflictingFiles: [ConflictingFilePair] = []
    
    @Published public var totalFileCount: Int = 0
    
    // MARK: - Private Properties
    
    private let bridge = KalamBridge.shared
    private var cancelRequested = false
    private var pauseRequested = false
    private var conflictContinuation: CheckedContinuation<(ConflictResolution, Bool), Never>?
    
    private var conflictProcessIndex: Int = 0
    
    private var isCutOperation: Bool = false
    
    private var cutSourcePaths: [String] = []
    
    // used to calculate overall progress.
    private var completedBytesAccumulated: Int64 = 0
    
    // speed tracking
    private var speedSamples: [(time: Date, bytes: Int64)] = []
    private let maxSpeedSamples = 10
    
    private var verifiedDirectories = Set<String>()
    
    // MARK: - Initializer
    
    private init() {}
    
    // MARK: - Public Control Methods
    
    public func pauseTransfer() {
        guard activeBatch?.state == .transferring else { return }
        pauseRequested = true
        activeBatch?.pause()
        print("FileTransferService: Pause requested")
    }
    
    public func resumeTransfer() {
        guard activeBatch?.state == .paused else { return }
        pauseRequested = false
        activeBatch?.resume()
        print("FileTransferService: Resume requested")
    }
    
    public func cancelTransfer() {
        cancelRequested = true
        activeBatch?.cancel()
        print("FileTransferService: Cancel requested")
        
        // If waiting in conflict dialog, cancel it
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
        self.conflictContinuation = nil
        continuation.resume(returning: (resolution, rememberForBatch))
        showConflictDialog = false
    }
    
    // MARK: - Core Transfer Operation
    
    /// - Parameters:
    ///   - destinationDir: The destination directory.
    ///   - storageId: The MTP storage ID (required if direction is MTP-related).
    public func initiateTransfer(
        sources: [FileNode],
        destinationDir: String,
        direction: TransferDirection,
        storageId: UInt32? = nil,
        isCut: Bool = false
    ) {
        print("[Transfer] initiateTransfer called: direction=\(direction) sources=\(sources.count) dest=\(destinationDir) storageId=\(storageId ?? 0) isCut=\(isCut)")
        self.isCutOperation = isCut
        self.cutSourcePaths = isCut ? sources.map { $0.path } : []
        Task {
            do {
                print("[Transfer] Starting performTransfer...")
                try await performTransfer(
                    sources: sources,
                    destinationDir: destinationDir,
                    direction: direction,
                    storageId: storageId
                )
                print("[Transfer] performTransfer completed successfully")
            } catch {
                print("[Transfer] Transfer failed with error: \(error.localizedDescription)")
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
    
    // MARK: - Notifications
    
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
                print("Failed to post notification: \(error)")
            }
        }
    }
    
    // MARK: - Private Transfer Logic
    
    private func performTransfer(
        sources: [FileNode],
        destinationDir: String,
        direction: TransferDirection,
        storageId: UInt32?
    ) async throws {
        // Only reject if there's an actively transferring batch
        if let batch = activeBatch, !batch.state.isTerminal {
            print("[Transfer] Concurrent transfer rejected — another transfer is in progress")
            throw KalamError.operationInProgress
        }

        // Reset all state
        cancelRequested = false
        pauseRequested = false
        completedBytesAccumulated = 0
        speedSamples.removeAll()
        verifiedDirectories.removeAll()
        showConflictDialog = false
        conflictingFiles = []
        totalFileCount = 0
        // Clear any stale conflict continuation
        if let oldContinuation = conflictContinuation {
            conflictContinuation = nil
            oldContinuation.resume(returning: (.cancel, true))
        }
        isCutOperation = false
        cutSourcePaths = []
        
        if (direction == .localToMTP || direction == .mtpToLocal) && storageId == nil {
            throw NSError(domain: "FileTransferService", code: 1, userInfo: [NSLocalizedDescriptionKey: "Storage ID is required for MTP transfers"])
        }
        
        let mStorageId = storageId ?? 0
        
        // 1. Pre-scan: Expand directories to get all files & folders
        print("FileTransferService: Pre-scanning sources...")
        let expandedItems = try await expandSources(sources: sources, direction: direction, storageId: mStorageId)
        
        guard !expandedItems.isEmpty else {
            print("FileTransferService: No files found to transfer")
            return
        }
        
        // Set total file count for conflict summary (files only; directories created by ensureDirectoryExists)
        self.totalFileCount = expandedItems.filter { !$0.isDirectory }.count
        
        // 2. Conflict Scan: Compare source and destination files
        let fileItems = expandedItems.filter { !$0.isDirectory }
        print("FileTransferService: Scanning for conflicts over \(fileItems.count) files...")
        let conflicts = try await scanForConflicts(
            items: fileItems,
            destinationDir: destinationDir,
            direction: direction,
            storageId: mStorageId
        )
        
        // 3. Resolve conflicts if any exist
        var chosenResolution: ConflictResolution = .askEach
        var rememberForBatch = true
        var resolvedConflicts: [String: ConflictResolution] = [:]
        
        if !conflicts.isEmpty {
            conflictProcessIndex = 0
            while conflictProcessIndex < conflicts.count {
                self.conflictingFiles = Array(conflicts[conflictProcessIndex...])
                self.showConflictDialog = true
                
                // Await user input from the conflict sheet
                (chosenResolution, rememberForBatch) = await withCheckedContinuation { continuation in
                    self.conflictContinuation = continuation
                }
                
                if chosenResolution == .cancel {
                    print("FileTransferService: Transfer cancelled by user in conflict dialog")
                    self.activeBatch = nil
                    return
                }
                
                // Apply resolution to current and possibly remaining conflicts
                if rememberForBatch {
                    for i in conflictProcessIndex..<conflicts.count {
                        resolvedConflicts[conflicts[i].sourcePath] = chosenResolution
                    }
                    break
                } else {
                    resolvedConflicts[conflicts[conflictProcessIndex].sourcePath] = chosenResolution
                    conflictProcessIndex += 1
                    // Give the sheet time to dismiss before re-presenting
                    try? await Task.sleep(nanoseconds: 300_000_000)
                }
            }
        }
        
        // 4. Build final transfer items queue (files only; directories created by ensureDirectoryExists)
        var transferQueue: [TransferItem] = []
        for item in fileItems {
            let relativePath = item.relativePath
            let destPath = (destinationDir as NSString).appendingPathComponent(relativePath)
            
            let sourceFull = item.absolutePath
            let fileName = (relativePath as NSString).lastPathComponent
            
            var status: TransferStatus = .queued
            
            // Apply conflict resolution choices
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
            
            let transItem = TransferItem(
                sourcePath: sourceFull,
                destinationPath: destPath,
                fileName: fileName,
                fileSize: item.size,
                direction: direction,
                status: status
            )
            transferQueue.append(transItem)
        }
        
        // 5. Create the active batch
        let batch = TransferBatch()
        batch.items = transferQueue
        self.activeBatch = batch
        
        print("FileTransferService: Starting batch transfer of \(batch.items.count) items...")
        batch.start()
        
        // Start transferring files
        await runQueue(storageId: mStorageId, direction: direction)
    }
    
    // MARK: - Queue Executer
    
    private func runQueue(storageId: UInt32, direction: TransferDirection) async {
        guard let batch = activeBatch else { return }
        
        // Group items by their destination parent directory
        var groups: [String: [Int]] = [:] // destParent -> array of indices
        for index in batch.items.indices {
            if batch.items[index].status == .skipped { continue }
            let destParent = (batch.items[index].destinationPath as NSString).deletingLastPathComponent
            groups[destParent, default: []].append(index)
        }
        
        let chunkSize = 50 // Balance between bulk performance and cancellation responsiveness
        
        for (destParent, indices) in groups {
            if cancelRequested { break }
            
            do {
                // Ensure destination parent directory exists
                try await ensureDirectoryExists(path: destParent, direction: direction, storageId: storageId)
            } catch {
                print("FileTransferService: Failed to create parent directory \(destParent): \(error.localizedDescription)")
                // Mark all items in this group as failed
                for idx in indices {
                    var itm = batch.items[idx]
                    itm.markFailed(error.localizedDescription)
                    batch.items[idx] = itm
                }
                continue // Skip this group
            }
            
            for chunkStart in stride(from: 0, to: indices.count, by: chunkSize) {
                if cancelRequested { break }
                
                // Check for pause
                while pauseRequested && !cancelRequested {
                    try? await Task.sleep(nanoseconds: 100_000_000)
                }
                
                if cancelRequested { break }
                
                let chunkIndices = Array(indices[chunkStart..<min(chunkStart + chunkSize, indices.count)])
                let sources = chunkIndices.map { batch.items[$0].sourcePath }
                
                // Mark items as preprocessing
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
                    
                    // Mark all chunk items complete
                    for idx in chunkIndices {
                        var itm = batch.items[idx]
                        if itm.status != .completed {
                            itm.markCompleted()
                            batch.items[idx] = itm
                            completedBytesAccumulated += itm.fileSize
                        }
                    }
                    
                } catch {
                    print("FileTransferService: File copy failed for chunk in \(destParent). Error: \(error.localizedDescription)")
                    // Mark items that didn't complete as failed
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
        
        // End of batch
        if cancelRequested {
            print("FileTransferService: Batch transfer ended due to cancellation")
            batch.cancel()
            let completed = completedBytesAccumulated > 0 ? " (\(FormatUtils.formatBytes(completedBytesAccumulated)) transferred)" : ""
            postTransferNotification(
                title: "Transfer Cancelled",
                body: "\(batch.completedFileCount) of \(batch.totalFileCount) files copied\(completed)",
                isError: false
            )
        } else {
            let failedCount = batch.failedFileCount
            print("FileTransferService: Batch transfer completed with \(failedCount) failures")
            batch.complete()
            
            // Handle cut operation: delete successfully transferred source files
            if isCutOperation && !cutSourcePaths.isEmpty {
                let failedItems = batch.items.filter { $0.status == .failed }
                if failedItems.isEmpty {
                    print("FileTransferService: Cut operation - deleting \(cutSourcePaths.count) source paths")
                    do {
                        if direction == .mtpToLocal {
                            try await bridge.deleteFiles(
                                storageId: storageId,
                                paths: cutSourcePaths
                            )
                        } else {
                            let fileManager = FileManager.default
                            for path in cutSourcePaths {
                                try? fileManager.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: nil)
                            }
                        }
                        print("FileTransferService: Source files deleted for cut operation")
                    } catch {
                        print("FileTransferService: Failed to delete source files after cut: \(error)")
                    }
                } else {
                    print("FileTransferService: Cut operation aborted for deletion due to failed items")
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
            // Refresh directory listings to show newly copied files
            await MainActor.run {
                switch direction {
                case .localToMTP:
                    Task { await MTPDeviceManager.shared.refreshFiles() }
                case .mtpToLocal:
                    NotificationCenter.default.post(name: .localDirectoryNeedsRefresh, object: nil)
                }
            }
        }
        
        // Clean up batch after a delay — only clear if same batch is still set
        let completedBatch = batch
        Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            if self.activeBatch === completedBatch {
                self.activeBatch = nil
            }
        }
    }
    
    // MARK: - Progress Updates
    
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
        
        // Update batch-level speed tracking
        batch.recordSpeedSample(bytesTransferredNow: batch.totalBytesTransferred)
    }
    
    // MARK: - Helper Types
    
    private struct ScannedItem {
        let absolutePath: String
        let relativePath: String // Relative to the drag selection parent
        let isDirectory: Bool
        let size: Int64
        let modificationDate: Date
    }
    
    // MARK: - Expanding Sources
    
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
        print("[expandSources] direction=\(direction) sources=\(sources.count)")
        
        for (i, source) in sources.enumerated() {
            let parentDir = source.parentPath.isEmpty
                ? (source.path as NSString).deletingLastPathComponent
                : source.parentPath
            print("[expandSources] [\(i)] path=\(source.path) parentDir=\(parentDir) isDir=\(source.isDirectory)")
            
            if direction == .localToMTP {
                try expandLocalPath(
                    path: source.path,
                    baseParent: parentDir,
                    into: &expanded
                )
            } else {
                print("[expandSources] Calling expandMTPPath...")
                try await expandMTPPath(
                    path: source.path,
                    baseParent: parentDir,
                    storageId: storageId,
                    into: &expanded
                )
                print("[expandSources] expandMTPPath returned, total expanded=\(expanded.count)")
            }
        }
        
        print("[expandSources] Done, total expanded items=\(expanded.count)")
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
            // Add directory entry (size 0)
            list.append(ScannedItem(absolutePath: path, relativePath: relativePath, isDirectory: true, size: 0, modificationDate: date))
            
            // Recurse children
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
        print("[expandMTPPath] path=\(path) baseParent=\(baseParent) relativePath=\(relativePath)")

        let parentDir = (path as NSString).deletingLastPathComponent
        print("[expandMTPPath] parentDir=\(parentDir)")
        
        let parentContents: [GoFileInfo]
        do {
            parentContents = try await bridge.walk(storageId: storageId, path: parentDir, recursive: false, skipHidden: false)
            print("[expandMTPPath] parentContents count=\(parentContents.count)")
        } catch {
            print("[expandMTPPath] bridge.walk(parentDir) failed: \(error)")
            throw error
        }
        
        guard let selfNode = parentContents.first(where: { $0.path == path }) else {
            print("[expandMTPPath] selfNode NOT FOUND in parent contents, paths in parent:")
            for node in parentContents {
                print("[expandMTPPath]   node.path=\(node.path) isFolder=\(node.isFolder)")
            }
            // Fallback: assume it's a file
            list.append(ScannedItem(absolutePath: path, relativePath: relativePath, isDirectory: false, size: 0, modificationDate: Date()))
            return
        }
        print("[expandMTPPath] selfNode found: path=\(selfNode.path) isFolder=\(selfNode.isFolder)")
        
        let date = parseGoDate(selfNode.dateAdded)
        
        if selfNode.isFolder {
            list.append(ScannedItem(absolutePath: path, relativePath: relativePath, isDirectory: true, size: 0, modificationDate: date))
            do {
                let children = try await bridge.walk(storageId: storageId, path: path, recursive: true, skipHidden: false)
                print("[expandMTPPath] recursive walk returned \(children.count) children")
                for child in children {
                    let childRel = getRelativePath(path: child.path, baseParent: baseParent)
                    let childDate = parseGoDate(child.dateAdded)
                    list.append(ScannedItem(absolutePath: child.path, relativePath: childRel, isDirectory: child.isFolder, size: child.size, modificationDate: childDate))
                }
            } catch {
                print("[expandMTPPath] recursive walk failed: \(error)")
                throw error
            }
        } else {
            list.append(ScannedItem(absolutePath: path, relativePath: relativePath, isDirectory: false, size: selfNode.size, modificationDate: date))
        }
    }
    
    // MARK: - Conflict Scanning
    
    private func scanForConflicts(
        items: [ScannedItem],
        destinationDir: String,
        direction: TransferDirection,
        storageId: UInt32
    ) async throws -> [ConflictingFilePair] {
        var conflicts: [ConflictingFilePair] = []
        
        // Build destination paths we need to check
        let destinationPaths = items.map { item -> String in
            (destinationDir as NSString).appendingPathComponent(item.relativePath)
        }
        
        if direction == .localToMTP {
            // MTP Destination checking: check if paths exist
            let existences = try await bridge.checkFilesExist(storageId: storageId, paths: destinationPaths)
            
            // To get metadata (size/date) for conflicting files on MTP, we list the destination parent directory.
            // Rather than listing for each file, we group by parent directories and walk them.
            var parentDirsToWalk = Set<String>()
            for (index, exists) in existences.enumerated() where exists {
                let destPath = destinationPaths[index]
                let destParent = (destPath as NSString).deletingLastPathComponent
                parentDirsToWalk.insert(destParent)
            }
            
            var mtpFilesMetadata = [String: GoFileInfo]()
            for parent in parentDirsToWalk {
                if let contents = try? await bridge.walk(storageId: storageId, path: parent, recursive: false, skipHidden: false) {
                    for node in contents {
                        mtpFilesMetadata[node.path] = node
                    }
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
            // Local Destination checking
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
    
    // MARK: - Directory Helpers
    
    private func ensureDirectoryExists(path: String, direction: TransferDirection, storageId: UInt32) async throws {
        if verifiedDirectories.contains(path) { return }
        
        if direction == .localToMTP {
            // Ensure MTP directory path exists
            let existResult = try await bridge.checkFilesExist(storageId: storageId, paths: [path])
            if let exists = existResult.first, exists {
                verifiedDirectories.insert(path)
                return
            }
            
            // Recurse to ensure parent exists
            let parent = (path as NSString).deletingLastPathComponent
            if parent != "/" && !parent.isEmpty {
                try await ensureDirectoryExists(path: parent, direction: direction, storageId: storageId)
            }
            
            // Create this directory
            try await bridge.makeDirectory(storageId: storageId, path: path)
            verifiedDirectories.insert(path)
        } else {
            // Local directory creation
            let fileManager = FileManager.default
            var isDir: ObjCBool = false
            if !fileManager.fileExists(atPath: path, isDirectory: &isDir) {
                try fileManager.createDirectory(atPath: path, withIntermediateDirectories: true)
            }
            verifiedDirectories.insert(path)
        }
    }
    
    // MARK: - Date Parser
    
    private func parseGoDate(_ dateStr: String) -> Date {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS'Z'"
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.date(from: dateStr) ?? Date()
    }
}
