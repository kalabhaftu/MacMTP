import SwiftUI


struct ContentView: View {

    enum ActivePane: Equatable {
        case local
        case mtp
    }


    @State private var currentLocalPath: String = FileManager.default.homeDirectoryForCurrentUser.path
    @State private var currentMTPPath: String = "/"
    @State private var selectedLocalItems: Set<String> = []
    @State private var selectedMTPItems: Set<String> = []


    @State private var isMTPConnected: Bool = false
    @State private var connectedDeviceName: String = "No Device Connected"


    @State private var selectedSidebarItem: String? = "home"


    @State private var showConflictDialog: Bool = false
    @State private var activeConflictResolution: ConflictResolution? = nil
    @State private var conflictingFiles: [ConflictingFilePair] = []
    @State private var conflictRememberForBatch: Bool = false
    @State private var pendingLocalPasteItems: [FileNode] = []
    @State private var pendingLocalPasteDestination: String = ""
    @State private var pendingLocalPasteIsCut: Bool = false


    @State private var showTransferProgress: Bool = false


    @State private var statusIsTransferring: Bool = false
    @State private var statusTransferProgress: Double = 0
    @State private var statusTransferFileName: String = ""

    @State private var selectedLocalSize: Int64 = 0
    @State private var selectedMTPSize: Int64 = 0
    @State private var localDirSize: Int64 = 0
    @State private var mtpDirSize: Int64 = 0


    @State private var activePane: ActivePane = .local


    @State private var localFiles: [FileNode] = []
    @State private var mtpFiles: [FileNode] = []


    @State private var mtpStorages: [MTPStorageInfo] = []
    @State private var mtpSelectedStorageId: UInt32? = nil
    @State private var mtpTotalBytes: Int64 = 0
    @State private var mtpFreeBytes: Int64 = 0


    @State private var showDeleteConfirmation: Bool = false
    @State private var pendingDeletePaths: [String] = []
    @State private var showNewFolderDialog: Bool = false
    @State private var newFolderName: String = "New Folder"
    @State private var operationErrorMessage: String?


    @State private var eventMonitor: Any? = nil

    @AppStorage("hasSeenPrivacyPrompt") private var hasSeenPrivacyPrompt: Bool = false
    @AppStorage("sendCrashReports") private var sendCrashReports: Bool = false
    @AppStorage("swapPanels") private var swapPanels: Bool = false
    @AppStorage("showHiddenFilesLocal") private var showHiddenFilesLocal: Bool = false
    @AppStorage("showHiddenFilesMTP") private var showHiddenFilesMTP: Bool = false
    @AppStorage("appFontScale") private var appFontScale: Double = 1.0
    @State private var showPrivacyPrompt: Bool = false


    var body: some View {
        VStack(spacing: 0) {
            ToolbarView(
                isMTPConnected: isMTPConnected,
                deviceName: connectedDeviceName,
                onRefresh: handleRefresh,
                onCopy: handleCopy,
                onCut: handleCut,
                onPaste: handlePaste,
                onDelete: handleDelete,
                onNewFolder: handleNewFolder,
                onSelectAll: handleSelectAll,
                hasClipboardContent: ClipboardManager.shared.hasContent,
                selectedCount: activePane == .local ? selectedLocalItems.count : selectedMTPItems.count
            )

            HSplitView {
                SidebarView(
                    selectedItem: $selectedSidebarItem,
                    currentLocalPath: $currentLocalPath,
                    isMTPConnected: isMTPConnected,
                    mtpDeviceName: connectedDeviceName,
                    mtpStorages: MTPDeviceManager.shared.storages,
                    onMTPStorageSelected: { storageId in
                        Task {
                            await MTPDeviceManager.shared.selectStorage(storageId)
                        }
                    }
                )
                .frame(minWidth: 180, idealWidth: 220, maxWidth: 280)
                .layoutPriority(0)

                HSplitView {
                    if swapPanels {
                        mtpPane
                        localPane
                    } else {
                        localPane
                        mtpPane
                    }
                }
            }

            if showTransferProgress, let batch = FileTransferService.shared.activeBatch {
                TransferProgressView(
                    batch: batch,
                    onCancel: {
                        FileTransferService.shared.cancelTransfer()
                        showTransferProgress = false
                    },
                    onPause: {
                        FileTransferService.shared.pauseTransfer()
                    },
                    onResume: {
                        FileTransferService.shared.resumeTransfer()
                    }
                )
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            StatusView(
                localPath: currentLocalPath,
                mtpPath: currentMTPPath,
                isMTPConnected: isMTPConnected,
                localItemCount: showHiddenFilesLocal ? localFiles.count : localFiles.filter { !$0.name.hasPrefix(".") }.count,
                localSelectedCount: selectedLocalItems.count,
                localSelectedSize: selectedLocalSize,
                localDirSize: localDirSize,
                mtpItemCount: showHiddenFilesMTP ? mtpFiles.count : mtpFiles.filter { !$0.name.hasPrefix(".") }.count,
                mtpSelectedCount: selectedMTPItems.count,
                mtpSelectedSize: selectedMTPSize,
                mtpDirSize: mtpDirSize,
                isTransferring: statusIsTransferring,
                transferProgress: statusTransferProgress,
                transferFileName: statusTransferFileName,
                mtpTotalBytes: mtpTotalBytes,
                mtpFreeBytes: mtpFreeBytes
            )
        }
        .frame(minWidth: 960, minHeight: 600)
        .background(Color(NSColor.windowBackgroundColor))
        .sheet(isPresented: $showConflictDialog) {
            ConflictDialogView(
                conflictingFiles: conflictingFiles.isEmpty ? FileTransferService.shared.conflictingFiles : conflictingFiles,
                totalFileCount: conflictingFiles.isEmpty ? FileTransferService.shared.totalFileCount : pendingLocalPasteItems.count,
                resolution: $activeConflictResolution,
                rememberForBatch: $conflictRememberForBatch
            )
        }
        .alert("Delete Files", isPresented: $showDeleteConfirmation) {
            Button("Delete", role: .destructive) {
                performDelete(paths: pendingDeletePaths)
            }
            Button("Cancel", role: .cancel) {
                pendingDeletePaths.removeAll()
            }
        } message: {
            Text("Are you sure you want to delete \(pendingDeletePaths.count) item\(pendingDeletePaths.count == 1 ? "" : "s")? This cannot be undone.")
        }
        .alert("New Folder", isPresented: $showNewFolderDialog) {
            TextField("Folder name", text: $newFolderName)
            Button("Create") {
                performNewFolder()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Enter a name for the new folder:")
        }
        .alert("Privacy First", isPresented: $showPrivacyPrompt) {
            Button("I Agree") {
                sendCrashReports = true
                hasSeenPrivacyPrompt = true
                ErrorLogger.startIfEnabled()
            }
            Button("No Thanks", role: .cancel) {
                sendCrashReports = false
                hasSeenPrivacyPrompt = true
            }
        } message: {
            Text("Would you like to help improve macMTP by sending anonymous crash reports and error logs? We genuinely do not collect any personal data.")
        }
        .alert(
            "Operation Failed",
            isPresented: Binding(
                get: { operationErrorMessage != nil },
                set: { if !$0 { operationErrorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) {
                operationErrorMessage = nil
            }
        } message: {
            Text(operationErrorMessage ?? "The operation could not be completed.")
        }
        .onAppear {
            installKeyboardMonitor()
            if !hasSeenPrivacyPrompt {
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    showPrivacyPrompt = true
                }
            }
        }
        .onDisappear {
            removeKeyboardMonitor()
        }
        .onChange(of: activeConflictResolution) { _, resolution in
            if let resolution = resolution {
                if !pendingLocalPasteItems.isEmpty {
                    if resolution != .cancel {
                        performLocalPaste(
                            items: pendingLocalPasteItems,
                            destination: pendingLocalPasteDestination,
                            isCut: pendingLocalPasteIsCut,
                            conflictResolution: resolution
                        )
                        ClipboardManager.shared.clear()
                        handleRefresh()
                    }
                    pendingLocalPasteItems = []
                    pendingLocalPasteDestination = ""
                    pendingLocalPasteIsCut = false
                    conflictingFiles = []
                    showConflictDialog = false
                } else {
                    FileTransferService.shared.resolveConflicts(with: resolution, rememberForBatch: conflictRememberForBatch)
                }
                activeConflictResolution = nil
            }
        }
        .onReceive(MTPDeviceManager.shared.$isConnected) { connected in
            isMTPConnected = connected
            connectedDeviceName = MTPDeviceManager.shared.deviceInfo?.displayName ?? "No Device Connected"
        }
        .onReceive(MTPDeviceManager.shared.$mtpFiles) { newFiles in
            mtpFiles = newFiles
            currentMTPPath = MTPDeviceManager.shared.currentMTPPath
        }
        .onReceive(MTPDeviceManager.shared.$storages) { storages in
            mtpStorages = storages
            if let first = storages.first {
                mtpTotalBytes = Int64(first.totalCapacity)
                mtpFreeBytes = Int64(first.freeSpace)
            } else {
                mtpTotalBytes = 0
                mtpFreeBytes = 0
            }
        }
        .onReceive(MTPDeviceManager.shared.$selectedStorageId) { storageId in
            mtpSelectedStorageId = storageId
            if let storageId = storageId, let selected = mtpStorages.first(where: { $0.storageId == storageId }) {
                mtpTotalBytes = Int64(selected.totalCapacity)
                mtpFreeBytes = Int64(selected.freeSpace)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .menuNewFolderRequested)) { _ in
            handleNewFolder()
        }
        .onReceive(NotificationCenter.default.publisher(for: .menuRefreshRequested)) { _ in
            handleRefresh()
        }
        // Observe FileTransferService for showing transfer progress and status bar
        .onReceive(FileTransferService.shared.$activeBatch) { batch in
            showTransferProgress = batch != nil
            statusIsTransferring = batch?.isActive ?? false
            statusTransferProgress = batch?.overallProgress ?? 0
            statusTransferFileName = batch?.currentItem?.fileName ?? ""
        }
        .onReceive(Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()) { _ in
            if let batch = FileTransferService.shared.activeBatch {
                statusIsTransferring = batch.isActive
                statusTransferProgress = batch.overallProgress
                statusTransferFileName = batch.currentItem?.fileName ?? ""
            }
            selectedLocalSize = localFiles.filter { selectedLocalItems.contains($0.path) }
                .reduce(0) { $0 + ($1.calculatedSize ?? $1.size) }
            selectedMTPSize = mtpFiles.filter { selectedMTPItems.contains($0.path) }
                .reduce(0) { $0 + ($1.calculatedSize ?? $1.size) }
            localDirSize = localFiles.reduce(0) { $0 + ($1.calculatedSize ?? $1.size) }
            mtpDirSize = mtpFiles.reduce(0) { $0 + ($1.calculatedSize ?? $1.size) }
        }
        .onReceive(FileTransferService.shared.$showConflictDialog) { show in
            showConflictDialog = show
            if show {
                conflictRememberForBatch = false
            }
        }
    }

    @ViewBuilder
    private var localPane: some View {
        FileExplorerPane(
            title: "Local Files",
            currentPath: $currentLocalPath,
            selectedItems: $selectedLocalItems,
            isLocal: true,
            isDisabled: false,
            files: $localFiles,
            isActivePane: activePane == .local,
            clipboardManager: ClipboardManager.shared,
            onFilesDropped: { files, destination in
                handleFilesDropped(files: files, destination: destination, isLocal: true)
            },
            onFileOperation: { operation in
                handleFileOperation(operation, isLocal: true)
            },
            onPaste: handlePaste
        )
        .frame(minWidth: 350, idealWidth: 420)
        .layoutPriority(1)
        .simultaneousGesture(
            TapGesture().onEnded { activePane = .local },
            including: .all
        )
        .overlay(
            RoundedRectangle(cornerRadius: 0)
                .stroke(activePane == .local ? Color.accentColor.opacity(0.4) : Color.clear, lineWidth: 2)
        )
        .onChange(of: selectedLocalItems) { _, _ in activePane = .local }
    }

    @ViewBuilder
    private var mtpPane: some View {
        VStack(spacing: 0) {
            if isMTPConnected && mtpStorages.count > 1 {
                StorageSelectorView(
                    storages: mtpStorages,
                    selectedStorageId: mtpSelectedStorageId,
                    onSelect: { storageId in
                        Task {
                            await MTPDeviceManager.shared.selectStorage(storageId)
                        }
                    }
                )
            }
            
            FileExplorerPane(
                title: isMTPConnected ? connectedDeviceName : "MTP Device",
                currentPath: $currentMTPPath,
                selectedItems: $selectedMTPItems,
                isLocal: false,
                isDisabled: !isMTPConnected,
                files: $mtpFiles,
                isActivePane: activePane == .mtp,
                clipboardManager: ClipboardManager.shared,
                onFilesDropped: { files, destination in
                    handleFilesDropped(files: files, destination: destination, isLocal: false)
                },
                onFileOperation: { operation in
                    handleFileOperation(operation, isLocal: false)
                },
                onPaste: handlePaste
            )
        }
        .frame(minWidth: 350, idealWidth: 420)
        .layoutPriority(1)
        .simultaneousGesture(
            TapGesture().onEnded { activePane = .mtp },
            including: .all
        )
        .overlay(
            RoundedRectangle(cornerRadius: 0)
                .stroke(activePane == .mtp ? Color.accentColor.opacity(0.4) : Color.clear, lineWidth: 2)
        )
        .onChange(of: selectedMTPItems) { _, _ in activePane = .mtp }
    }

    private func installKeyboardMonitor() {
        guard eventMonitor == nil else { return }
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let hasCmd = event.modifierFlags.contains(.command)
            let hasShift = event.modifierFlags.contains(.shift)
            let modifiersOnly = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

            if event.keyCode == 53 {
                switch self.activePane {
                case .local: self.selectedLocalItems.removeAll()
                case .mtp: self.selectedMTPItems.removeAll()
                }
                return nil
            }

            if event.keyCode == 36 && !hasCmd && modifiersOnly == [] {
                self.handleEnter()
                return nil
            }

            if event.keyCode == 126 && hasCmd && !hasShift {
                self.handleNavigateUp()
                return nil
            }

            guard hasCmd else { return event }

            let key = event.charactersIgnoringModifiers?.lowercased() ?? ""

            switch key {
            case "c":
                self.handleCopy()
                return nil
            case "x":
                self.handleCut()
                return nil
            case "v":
                self.handlePaste()
                return nil
            case "a":
                self.handleSelectAll()
                return nil
            case "n":
                self.handleNewFolder()
                return nil
            case "r":
                self.handleRefresh()
                return nil
            default:
                break
            }

            if event.keyCode == 51 && hasCmd {
                self.handleDelete()
                return nil
            }

            return event
        }
    }

    private func removeKeyboardMonitor() {
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }
    }


    func handleCopy() {
        switch activePane {
        case .local:
            let selectedNodes = localFiles.filter { selectedLocalItems.contains($0.path) }
            guard !selectedNodes.isEmpty else { return }
            ClipboardManager.shared.copyItems(items: selectedNodes, from: currentLocalPath, isLocal: true)
        case .mtp:
            let selectedNodes = mtpFiles.filter { selectedMTPItems.contains($0.path) }
            guard !selectedNodes.isEmpty else { return }
            ClipboardManager.shared.copyItems(items: selectedNodes, from: currentMTPPath, isLocal: false)
        }
    }

    func handleCut() {
        switch activePane {
        case .local:
            let selectedNodes = localFiles.filter { selectedLocalItems.contains($0.path) }
            guard !selectedNodes.isEmpty else { return }
            ClipboardManager.shared.cutItems(items: selectedNodes, from: currentLocalPath, isLocal: true)
        case .mtp:
            let selectedNodes = mtpFiles.filter { selectedMTPItems.contains($0.path) }
            guard !selectedNodes.isEmpty else { return }
            ClipboardManager.shared.cutItems(items: selectedNodes, from: currentMTPPath, isLocal: false)
        }
    }

    func handlePaste() {
        if !ClipboardManager.shared.hasContent {
            let pasteboard = NSPasteboard.general
            if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL] {
                let items = urls.map { FileNode(name: $0.lastPathComponent, path: $0.path, isDirectory: $0.hasDirectoryPath, size: 0, modificationDate: Date()) }
                if !items.isEmpty {
                    ClipboardManager.shared.copyItems(items: items, from: "Finder", isLocal: true)
                } else {
                    return
                }
            } else {
                return
            }
        }

        let destinationPath: String
        let isDestLocal: Bool

        switch activePane {
        case .local:
            destinationPath = currentLocalPath
            isDestLocal = true
        case .mtp:
            destinationPath = currentMTPPath
            isDestLocal = false
        }

        if ClipboardManager.shared.sourceIsLocal && isDestLocal {
            let conflicts = detectLocalConflicts(
                sourcePaths: ClipboardManager.shared.items.map { $0.path },
                destination: destinationPath
            )

            if !conflicts.isEmpty {
                conflictingFiles = conflicts
                pendingLocalPasteItems = ClipboardManager.shared.items
                pendingLocalPasteDestination = destinationPath
                pendingLocalPasteIsCut = ClipboardManager.shared.isCutOperation
                showConflictDialog = true
                return
            }
        }

        if ClipboardManager.shared.sourceIsLocal && isDestLocal {
            performLocalPaste(items: ClipboardManager.shared.items, destination: destinationPath, isCut: ClipboardManager.shared.isCutOperation)
            ClipboardManager.shared.clear()
            handleRefresh()
        } else if !ClipboardManager.shared.sourceIsLocal && !isDestLocal {
            if destinationPath == ClipboardManager.shared.sourcePath {
                ClipboardManager.shared.clear()
            }
        } else {
            let direction: TransferDirection = isDestLocal ? .mtpToLocal : .localToMTP
            let storageId = MTPDeviceManager.shared.selectedStorageId ?? 0
            let sources = ClipboardManager.shared.items
            FileTransferService.shared.initiateTransfer(
                sources: sources,
                destinationDir: destinationPath,
                direction: direction,
                storageId: storageId,
                isCut: ClipboardManager.shared.isCutOperation
            )
            ClipboardManager.shared.clear()
        }
    }

    func handleDelete() {
        switch activePane {
        case .local:
            let paths = Array(selectedLocalItems)
            guard !paths.isEmpty else { return }
            pendingDeletePaths = paths
            showDeleteConfirmation = true
        case .mtp:
            let paths = Array(selectedMTPItems)
            guard !paths.isEmpty else { return }
            pendingDeletePaths = paths
            showDeleteConfirmation = true
        }
    }

    func handleNewFolder() {
        newFolderName = "New Folder"
        showNewFolderDialog = true
    }

    func handleEnter() {
        switch activePane {
        case .local:
            guard let first = selectedLocalItems.first,
                  let node = localFiles.first(where: { $0.path == first })
            else { return }
            if node.isDirectory {
                currentLocalPath = node.path
            } else {
                NSWorkspace.shared.open(URL(fileURLWithPath: node.path))
            }
        case .mtp:
            guard let first = selectedMTPItems.first,
                  let node = mtpFiles.first(where: { $0.path == first }),
                  node.isDirectory
            else { return }
            currentMTPPath = node.path
            Task { await MTPDeviceManager.shared.navigateTo(path: node.path) }
        }
    }

    func handleNavigateUp() {
        switch activePane {
        case .local:
            let parent = URL(fileURLWithPath: currentLocalPath).deletingLastPathComponent().path
            if parent != currentLocalPath { currentLocalPath = parent }
        case .mtp:
            let parent = URL(fileURLWithPath: currentMTPPath).deletingLastPathComponent().path
            guard parent != currentMTPPath else { return }
            currentMTPPath = parent
            Task { await MTPDeviceManager.shared.navigateTo(path: parent) }
        }
    }

    func handleRefresh() {
        switch activePane {
        case .local:
            NotificationCenter.default.post(name: .localDirectoryNeedsRefresh, object: nil)
        case .mtp:
            Task {
                await MTPDeviceManager.shared.refreshFiles()
            }
        }
    }

    func handleSelectAll() {
        switch activePane {
        case .local:
            selectedLocalItems = Set(localFiles.filter {
                showHiddenFilesLocal || !$0.name.hasPrefix(".")
            }.map(\.path))
        case .mtp:
            selectedMTPItems = Set(mtpFiles.filter {
                showHiddenFilesMTP || !$0.name.hasPrefix(".")
            }.map(\.path))
        }
    }


    private func handleFileOperation(_ operation: FileExplorerPane.FileOperation, isLocal: Bool) {
        switch operation {
        case .delete(let paths):
            pendingDeletePaths = paths
            showDeleteConfirmation = true

        case .rename(let oldPath, let newName):
            if isLocal {
                guard isValidChildName(newName) else {
                    operationErrorMessage = "A file or folder name must not be empty or contain path separators."
                    return
                }
                let sourceURL = URL(fileURLWithPath: oldPath)
                let destURL = sourceURL.deletingLastPathComponent().appendingPathComponent(newName)
                do {
                    try FileManager.default.moveItem(at: sourceURL, to: destURL)
                    handleRefresh()
                } catch {
                    ErrorLogger.log(error, message: "Rename failed")
                }
            } else {
                Task {
                    do {
                        try await MTPDeviceManager.shared.renameFile(path: oldPath, newName: newName)
                    } catch {
                        ErrorLogger.log(error, message: "Rename failed")
                        operationErrorMessage = error.localizedDescription
                    }
                }
            }

        case .newFolder(let parent, let name):
            if isLocal {
                guard isValidChildName(name) else {
                    operationErrorMessage = "A file or folder name must not be empty or contain path separators."
                    return
                }
                let folderURL = URL(fileURLWithPath: parent).appendingPathComponent(name)
                do {
                    try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: false)
                    handleRefresh()
                } catch {
                    ErrorLogger.log(error, message: "Create folder failed")
                    operationErrorMessage = error.localizedDescription
                }
            } else {
                Task {
                    do {
                        guard parent == MTPDeviceManager.shared.currentMTPPath else {
                            throw KalamError.invalidPath("The destination folder changed. Please retry.")
                        }
                        try await MTPDeviceManager.shared.createFolder(name: name)
                    } catch {
                        ErrorLogger.log(error, message: "Create MTP folder failed")
                        operationErrorMessage = error.localizedDescription
                    }
                }
            }

        case .open(let path):
            if isLocal {
                NSWorkspace.shared.open(URL(fileURLWithPath: path))
            }
        }
    }

    private func handleFilesDropped(files: [DroppedFile], destination: String, isLocal: Bool) {
        let localSources = files.filter { $0.isLocal }
        let mtpSources = files.filter { !$0.isLocal }

        if isLocal {
            if !localSources.isEmpty {
                DispatchQueue.global(qos: .userInitiated).async {
                    var didCopy = false
                    for file in localSources {
                        let url = URL(fileURLWithPath: file.path)
                        let destURL = URL(fileURLWithPath: destination).appendingPathComponent(file.name)
                        if url == destURL || url.deletingLastPathComponent().path == URL(fileURLWithPath: destination).path {
                            continue
                        }
                        do {
                            try FileManager.default.copyItem(at: url, to: destURL)
                            didCopy = true
                        } catch {
                            ErrorLogger.log(error, message: "Drop copy failed for \(file.name)")
                        }
                    }
                    if didCopy {
                        DispatchQueue.main.async {
                            self.handleRefresh()
                        }
                    }
                }
            }
            if !mtpSources.isEmpty {
                let nodes = mtpSources.map { FileNode(name: $0.name, path: $0.path, isDirectory: $0.isDirectory, size: 0, modificationDate: Date()) }
                FileTransferService.shared.initiateTransfer(
                    sources: nodes,
                    destinationDir: destination,
                    direction: .mtpToLocal,
                    storageId: MTPDeviceManager.shared.selectedStorageId ?? 0
                )
            }
        } else {
            if !localSources.isEmpty {
                let nodes = localSources.map { FileNode(name: $0.name, path: $0.path, isDirectory: $0.isDirectory, size: 0, modificationDate: Date()) }
                FileTransferService.shared.initiateTransfer(
                    sources: nodes,
                    destinationDir: destination,
                    direction: .localToMTP,
                    storageId: MTPDeviceManager.shared.selectedStorageId ?? 0
                )
            }
        }
    }


    private func detectLocalConflicts(sourcePaths: [String], destination: String) -> [ConflictingFilePair] {
        var conflicts: [ConflictingFilePair] = []
        let fileManager = FileManager.default

        for sourcePath in sourcePaths {
            let sourceURL = URL(fileURLWithPath: sourcePath)
            let fileName = sourceURL.lastPathComponent
            let destPath = URL(fileURLWithPath: destination).appendingPathComponent(fileName).path

            if fileManager.fileExists(atPath: destPath) {
                do {
                    let sourceAttrs = try fileManager.attributesOfItem(atPath: sourcePath)
                    let destAttrs = try fileManager.attributesOfItem(atPath: destPath)

                    let sourceSize = (sourceAttrs[.size] as? Int64) ?? 0
                    let sourceDate = (sourceAttrs[.modificationDate] as? Date) ?? Date()
                    let destSize = (destAttrs[.size] as? Int64) ?? 0
                    let destDate = (destAttrs[.modificationDate] as? Date) ?? Date()

                    conflicts.append(ConflictingFilePair(
                        fileName: fileName,
                        sourcePath: sourcePath,
                        sourceSize: sourceSize,
                        sourceDate: sourceDate,
                        destinationPath: destPath,
                        destinationSize: destSize,
                        destinationDate: destDate
                    ))
                } catch {
        conflicts.append(ConflictingFilePair(
                        fileName: fileName,
                        sourcePath: sourcePath,
                        sourceSize: 0,
                        sourceDate: Date(),
                        destinationPath: destPath,
                        destinationSize: 0,
                        destinationDate: Date()
                    ))
                }
            }
        }

        return conflicts
    }


    private func performDelete(paths: [String]) {
        let fileManager = FileManager.default

        if activePane == .local {
            for path in paths {
                do {
                    try fileManager.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: nil)
                } catch {
                    ErrorLogger.log(error, message: "Delete failed for \(path)")
                }
            }
            selectedLocalItems.removeAll()
            pendingDeletePaths.removeAll()
            handleRefresh()
        } else {
            Task {
                do {
                    try await KalamBridge.shared.deleteFiles(
                        storageId: MTPDeviceManager.shared.selectedStorageId ?? 0,
                        paths: paths
                    )
                    await MainActor.run {
                        selectedMTPItems.removeAll()
                        pendingDeletePaths.removeAll()
                    }
                    await MTPDeviceManager.shared.refreshFiles()
                } catch {
                    ErrorLogger.log(error, message: "MTP delete failed")
                    operationErrorMessage = error.localizedDescription
                    await MainActor.run {
                        pendingDeletePaths.removeAll()
                    }
                }
            }
        }
    }

    private func performLocalPaste(
        items: [FileNode],
        destination: String,
        isCut: Bool,
        conflictResolution: ConflictResolution? = nil
    ) {
        let fileManager = FileManager.default
        let destURL = URL(fileURLWithPath: destination)
        for item in items {
            let sourceURL = URL(fileURLWithPath: item.path)
            let targetURL = destURL.appendingPathComponent(item.name)
            if sourceURL == targetURL || sourceURL.deletingLastPathComponent() == destURL {
                continue
            }
            do {
                if fileManager.fileExists(atPath: targetURL.path) {
                    switch conflictResolution {
                    case .skip, .skipIfSameSize:
                        continue
                    case .overwriteIfDifferent:
                        let sourceSize = ((try? fileManager.attributesOfItem(atPath: sourceURL.path)[.size]) as? Int64) ?? 0
                        let targetSize = ((try? fileManager.attributesOfItem(atPath: targetURL.path)[.size]) as? Int64) ?? 0
                        if sourceSize == targetSize { continue }
                        try fileManager.trashItem(at: targetURL, resultingItemURL: nil)
                    case .overwrite:
                        try fileManager.trashItem(at: targetURL, resultingItemURL: nil)
                    case .cancel:
                        return
                    case .askEach, .none:
                        break
                    }
                }
                if isCut {
                    try fileManager.moveItem(at: sourceURL, to: targetURL)
                } else {
                    try fileManager.copyItem(at: sourceURL, to: targetURL)
                }
            } catch {
                ErrorLogger.log(error, message: "Paste operation failed for \(item.name)")
                operationErrorMessage = error.localizedDescription
            }
        }
    }

    private func performNewFolder() {
        let trimmedName = newFolderName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isValidChildName(trimmedName) else {
            operationErrorMessage = "A file or folder name must not be empty or contain path separators."
            return
        }

        let parentPath: String
        switch activePane {
        case .local: parentPath = currentLocalPath
        case .mtp: parentPath = currentMTPPath
        }

        let folderURL = URL(fileURLWithPath: parentPath).appendingPathComponent(trimmedName)

        if activePane == .local {
            do {
                try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: false)
                handleRefresh()
            } catch {
                ErrorLogger.log(error, message: "Create folder failed")
            }
        } else {
            Task {
                do {
                    try await MTPDeviceManager.shared.createFolder(name: trimmedName)
                } catch {
                    ErrorLogger.log(error, message: "Create MTP folder failed")
                    operationErrorMessage = error.localizedDescription
                }
            }
        }
    }

    private func isValidChildName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." &&
            !name.contains("/") && !name.contains("\\")
    }
}
