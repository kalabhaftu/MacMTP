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
    @State private var showCancelTransferConfirmation = false
    @State private var transferToastMessage: String?
    @State private var transferToastGeneration = 0


    @State private var statusIsTransferring: Bool = false
    @State private var statusTransferProgress: Double = 0
    @State private var statusTransferFileName: String = ""

    @State private var activePane: ActivePane = .local


    @State private var localFiles: [FileNode] = []
    @State private var mtpFiles: [FileNode] = []


    @State private var mtpStorages: [MTPStorageInfo] = []
    @State private var mtpSelectedStorageId: UInt32? = nil
    @State private var mtpTotalBytes: Int64 = 0
    @State private var mtpFreeBytes: Int64 = 0


    @State private var showDeleteConfirmation: Bool = false
    @State private var pendingDeletePaths: [String] = []
    @State private var newFolderName: String = "New Folder"
    @State private var renameText: String = ""
    @State private var newFolderRequest: NewFolderDialogRequest?
    @State private var renameRequest: RenameDialogRequest?
    @State private var isSubmittingFileOperation = false
    @State private var dialogErrorMessage: String?
    @State private var operationErrorMessage: String?


    @State private var eventMonitor: Any? = nil

    @AppStorage("hasSeenPrivacyPrompt") private var hasSeenPrivacyPrompt: Bool = false
    @AppStorage("sendCrashReports") private var sendCrashReports: Bool = true
    @AppStorage("swapPanels") private var swapPanels: Bool = false
    @AppStorage("sidebarOnRight") private var sidebarOnRight: Bool = false
    @AppStorage("showHiddenFilesLocal") private var showHiddenFilesLocal: Bool = false
    @AppStorage("showHiddenFilesMTP") private var showHiddenFilesMTP: Bool = false
    @AppStorage("appFontScale") private var appFontScale: Double = 1.0
    @State private var showPrivacyPrompt: Bool = false

    private let screenshotMode: Bool

    init(screenshotMode: Bool = false) {
        self.screenshotMode = screenshotMode
        if screenshotMode {
            _currentLocalPath = State(initialValue: ScreenshotDemo.localPath)
            _currentMTPPath = State(initialValue: ScreenshotDemo.mtpPath)
            _selectedLocalItems = State(initialValue: Set(ScreenshotDemo.localFiles.prefix(2).map(\.path)))
            _selectedMTPItems = State(initialValue: Set(ScreenshotDemo.mtpFiles.prefix(3).map(\.path)))
            _isMTPConnected = State(initialValue: true)
            _connectedDeviceName = State(initialValue: ScreenshotDemo.deviceInfo.displayName)
            _selectedSidebarItem = State(initialValue: "home")
            _localFiles = State(initialValue: ScreenshotDemo.localFiles)
            _mtpFiles = State(initialValue: ScreenshotDemo.mtpFiles)
            _mtpStorages = State(initialValue: ScreenshotDemo.storages)
            _mtpSelectedStorageId = State(initialValue: ScreenshotDemo.storages.first?.storageId)
            _mtpTotalBytes = State(initialValue: Int64(ScreenshotDemo.storages.first?.totalCapacity ?? 0))
            _mtpFreeBytes = State(initialValue: Int64(ScreenshotDemo.storages.first?.freeSpace ?? 0))
            _hasSeenPrivacyPrompt = AppStorage(wrappedValue: true, "hasSeenPrivacyPrompt")
        }
    }

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
                if sidebarOnRight {
                    mainFilePanes
                    sidebarView
                } else {
                    sidebarView
                    mainFilePanes
                }
            }

            if showTransferProgress, let batch = FileTransferService.shared.activeBatch {
                TransferProgressView(
                    batch: batch,
                    onCancel: {
                        showCancelTransferConfirmation = true
                    },
                    onPause: {
                        if FileTransferService.shared.pauseTransfer() {
                            showTransferToast(
                                "Pause requested. The current file will finish, then the next file will wait."
                            )
                        }
                    },
                    onResume: {
                        FileTransferService.shared.resumeTransfer()
                    },
                    onDismiss: {
                        showTransferProgress = false
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
                localSelectedSize: fileSizeSummary(of: localFiles, showHidden: showHiddenFilesLocal, selectedPaths: selectedLocalItems),
                localDirSize: fileSizeSummary(of: localFiles, showHidden: showHiddenFilesLocal),
                mtpItemCount: showHiddenFilesMTP ? mtpFiles.count : mtpFiles.filter { !$0.name.hasPrefix(".") }.count,
                mtpSelectedCount: selectedMTPItems.count,
                mtpSelectedSize: fileSizeSummary(of: mtpFiles, showHidden: showHiddenFilesMTP, selectedPaths: selectedMTPItems),
                mtpDirSize: fileSizeSummary(of: mtpFiles, showHidden: showHiddenFilesMTP),
                isTransferring: statusIsTransferring,
                transferProgress: statusTransferProgress,
                transferFileName: statusTransferFileName,
                localTotalBytesOverride: screenshotMode ? ScreenshotDemo.localTotalBytes : nil,
                localFreeBytesOverride: screenshotMode ? ScreenshotDemo.localFreeBytes : nil,
                mtpTotalBytes: mtpTotalBytes,
                mtpFreeBytes: mtpFreeBytes
            )
        }
        .frame(minWidth: 960, minHeight: 600)
        .background(Color(NSColor.windowBackgroundColor))
        .overlay(alignment: .bottomTrailing) {
            if let transferToastMessage {
                TransferToastView(message: transferToastMessage)
                    .padding(.trailing, 18)
                    .padding(.bottom, 42)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: transferToastMessage)
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
        .alert("Cancel Transfer?", isPresented: $showCancelTransferConfirmation) {
            Button("Cancel Transfer", role: .destructive) {
                FileTransferService.shared.cancelTransfer()
                showTransferProgress = false
            }
            Button("Keep Transferring", role: .cancel) {}
        } message: {
            Text("The current transfer will stop. Files already completed will remain on the device.")
        }
        .sheet(item: $newFolderRequest) { request in
            FileOperationDialog(
                title: "New Folder",
                actionTitle: "Create",
                prompt: "Create a folder in \(request.parentPath)",
                initialText: "New Folder",
                text: $newFolderName,
                isSubmitting: $isSubmittingFileOperation,
                errorMessage: $dialogErrorMessage,
                onSubmit: performNewFolder,
                onCancel: cancelFileOperationDialog
            )
        }
        .sheet(item: $renameRequest) { request in
            FileOperationDialog(
                title: "Rename",
                actionTitle: "Rename",
                prompt: "Enter a new name for this item.",
                initialText: request.initialName,
                text: $renameText,
                isSubmitting: $isSubmittingFileOperation,
                errorMessage: $dialogErrorMessage,
                onSubmit: performRename,
                onCancel: cancelFileOperationDialog
            )
        }
        .alert("Privacy First", isPresented: $showPrivacyPrompt) {
            Button("I Agree") {
                sendCrashReports = true
                hasSeenPrivacyPrompt = true
                ErrorLogger.setReportingEnabled(true)
            }
            Button("No Thanks", role: .cancel) {
                sendCrashReports = false
                hasSeenPrivacyPrompt = true
                ErrorLogger.setReportingEnabled(false)
            }
        } message: {
            Text("Would you like to help improve macMTP by sending anonymous crash and error reports? Reports can include error details and app/system versions, but macMTP does not attach file paths or Android device identifiers.")
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
                    guard !screenshotMode else { return }
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
            guard !screenshotMode else { return }
            isMTPConnected = connected
            connectedDeviceName = MTPDeviceManager.shared.deviceInfo?.displayName ?? "No Device Connected"
        }
        .onReceive(MTPDeviceManager.shared.$mtpFiles) { newFiles in
            guard !screenshotMode else { return }
            mtpFiles = newFiles
            currentMTPPath = MTPDeviceManager.shared.currentMTPPath
        }
        .onReceive(MTPDeviceManager.shared.$storages) { storages in
            guard !screenshotMode else { return }
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
            guard !screenshotMode else { return }
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
        .onReceive(NotificationCenter.default.publisher(for: .menuCopyRequested)) { _ in
            handleCopy()
        }
        .onReceive(NotificationCenter.default.publisher(for: .menuPasteRequested)) { _ in
            handlePaste()
        }
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
        }
        .onReceive(FileTransferService.shared.$showConflictDialog) { show in
            showConflictDialog = show
            if show {
                conflictRememberForBatch = false
            }
        }
    }

    private func fileSizeSummary(
        of files: [FileNode],
        showHidden: Bool,
        selectedPaths: Set<String>? = nil
    ) -> FileSizeSummary {
        let visible = showHidden ? files : files.filter { !$0.name.hasPrefix(".") }
        return FileSizeSummary.directItems(in: visible, selectedPaths: selectedPaths)
    }

    private var sidebarView: some View {
        SidebarView(
            selectedItem: $selectedSidebarItem,
            currentLocalPath: $currentLocalPath,
            isMTPConnected: isMTPConnected,
            mtpDeviceName: connectedDeviceName,
            mtpStorages: screenshotMode ? mtpStorages : MTPDeviceManager.shared.storages,
            onMTPStorageSelected: { storageId in
                guard !screenshotMode else { return }
                Task {
                    await MTPDeviceManager.shared.selectStorage(storageId)
                }
            }
        )
        .frame(minWidth: 180, idealWidth: 220, maxWidth: 280)
        .layoutPriority(0)
    }

    private var mainFilePanes: some View {
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
            onActivate: { activePane = .local },
            onFilesDropped: { files, destination in
                handleFilesDropped(files: files, destination: destination, isLocal: true)
            },
            onFileOperation: { operation in
                handleFileOperation(operation, isLocal: true)
            },
            onRequestNewFolder: { path, isLocal in
                beginNewFolder(path: path, isLocal: isLocal)
            },
            onPaste: handlePaste
        )
        .usesProvidedFiles(screenshotMode)
        .frame(minWidth: 350, idealWidth: 420)
        .layoutPriority(1)
        .overlay(
            RoundedRectangle(cornerRadius: 0)
                .stroke(activePane == .local ? Color.accentColor.opacity(0.4) : Color.clear, lineWidth: 2)
        )
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
                            guard !screenshotMode else { return }
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
                onActivate: { activePane = .mtp },
                onFilesDropped: { files, destination in
                    handleFilesDropped(files: files, destination: destination, isLocal: false)
                },
                onFileOperation: { operation in
                    handleFileOperation(operation, isLocal: false)
                },
                onRequestNewFolder: { path, isLocal in
                    beginNewFolder(path: path, isLocal: isLocal)
                },
                onPaste: handlePaste
            )
            .usesProvidedFiles(screenshotMode)
        }
        .frame(minWidth: 350, idealWidth: 420)
        .layoutPriority(1)
        .overlay(
            RoundedRectangle(cornerRadius: 0)
                .stroke(activePane == .mtp ? Color.accentColor.opacity(0.4) : Color.clear, lineWidth: 2)
        )
    }

    private func installKeyboardMonitor() {
        guard eventMonitor == nil else { return }
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let hasCmd = event.modifierFlags.contains(.command)
            let hasShift = event.modifierFlags.contains(.shift)
            let modifiersOnly = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let isTextEditing = isTextInputActive(for: event)

            // Let the sheet's native field editor receive every key. Checking
            // the responder alone is unreliable while SwiftUI presents a sheet.
            guard !isTextEditing,
                  newFolderRequest == nil,
                  renameRequest == nil else { return event }

            if !hasCmd, modifiersOnly == [],
               let characters = event.charactersIgnoringModifiers?.lowercased(),
               let first = characters.first,
               first.unicodeScalars.allSatisfy({ CharacterSet.letters.contains($0) }) {
                let hasFiles: Bool
                switch self.activePane {
                case .local: hasFiles = !self.localFiles.isEmpty
                case .mtp: hasFiles = !self.mtpFiles.isEmpty
                }
                guard hasFiles else { return event }
                NotificationCenter.default.post(
                    name: .fileTypeaheadKeyPressed,
                    object: String(first)
                )
                return nil
            }

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

    private func isTextInputActive(for event: NSEvent) -> Bool {
        let window = event.window ?? NSApp.keyWindow
        guard let responder = window?.firstResponder else { return false }
        return responder is NSTextField || responder is NSTextView
    }

    private func showTransferToast(_ message: String) {
        transferToastGeneration &+= 1
        let generation = transferToastGeneration
        transferToastMessage = message

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard !Task.isCancelled, transferToastGeneration == generation else { return }
            transferToastMessage = nil
        }
    }


    func handleCopy() {
        switch activePane {
        case .local:
            let selectedNodes = localFiles.filter { selectedLocalItems.contains($0.path) }
            guard !selectedNodes.isEmpty else { return }
            ClipboardManager.shared.copyItems(items: selectedNodes, from: currentLocalPath, isLocal: true)
            showTransferToast(copyToastMessage(for: selectedNodes))
        case .mtp:
            let selectedNodes = mtpFiles.filter { selectedMTPItems.contains($0.path) }
            guard !selectedNodes.isEmpty else { return }
            ClipboardManager.shared.copyItems(items: selectedNodes, from: currentMTPPath, isLocal: false)
            showTransferToast(copyToastMessage(for: selectedNodes))
        }
    }

    private func copyToastMessage(for items: [FileNode]) -> String {
        if items.count == 1 {
            return items[0].isDirectory ? "Folder copied" : "File copied"
        }
        return "\(items.count) items copied"
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
            showTransferToast("MTP-to-MTP copying is not supported.")
        } else {
            let direction: TransferDirection = isDestLocal ? .mtpToLocal : .localToMTP
            guard let storageId = validSelectedMTPStorageID() else { return }
            let sources = ClipboardManager.shared.items
            let transferAccepted = FileTransferService.shared.initiateTransfer(
                sources: sources,
                destinationDir: destinationPath,
                direction: direction,
                storageId: storageId,
                isCut: ClipboardManager.shared.isCutOperation
            )
            if transferAccepted {
                ClipboardManager.shared.clear()
            } else if FileTransferService.shared.isTransferInFlight {
                showTransferToast("Finishing the cancelled transfer. Try Paste again shortly.")
            } else if FileTransferService.shared.activeBatch != nil {
                showTransferProgress = true
            }
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
        beginNewFolder(
            path: activePane == .local ? currentLocalPath : currentMTPPath,
            isLocal: activePane == .local
        )
    }

    private func beginNewFolder(path: String, isLocal: Bool) {
        NotificationCenter.default.post(name: .fileTypeaheadReset, object: nil)
        let parentPath = path.isEmpty ? "/" : path
        newFolderName = "New Folder"
        dialogErrorMessage = nil
        newFolderRequest = NewFolderDialogRequest(
            parentPath: parentPath,
            isLocal: isLocal
        )
    }

    private func beginRename(file: FileNode, isLocal: Bool) {
        NotificationCenter.default.post(name: .fileTypeaheadReset, object: nil)
        renameText = file.name
        dialogErrorMessage = nil
        renameRequest = RenameDialogRequest(
            file: file,
            isLocal: isLocal,
            initialName: file.name
        )
    }

    private func performRename() {
        guard !isSubmittingFileOperation, let request = renameRequest else { return }
        let file = request.file
        let trimmed = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isValidChildName(trimmed) else {
            dialogErrorMessage = "A file or folder name must not be empty or contain path separators."
            return
        }
        guard trimmed != file.name else {
            renameRequest = nil
            return
        }

        isSubmittingFileOperation = true
        dialogErrorMessage = nil
        if request.isLocal {
            let sourceURL = URL(fileURLWithPath: file.path)
            let destinationURL = sourceURL.deletingLastPathComponent().appendingPathComponent(trimmed)
            do {
                try FileManager.default.moveItem(at: sourceURL, to: destinationURL)
                NotificationCenter.default.post(name: .localDirectoryNeedsRefresh, object: nil)
                renameRequest = nil
            } catch {
                ErrorLogger.log(error, message: "Rename failed")
                dialogErrorMessage = error.localizedDescription
            }
            isSubmittingFileOperation = false
        } else {
            Task { @MainActor in
                defer { isSubmittingFileOperation = false }
                do {
                    try await MTPDeviceManager.shared.renameFile(path: file.path, newName: trimmed)
                    renameRequest = nil
                } catch {
                    ErrorLogger.log(
                        error,
                        message: "Rename failed",
                        userInfo: [
                            "operation": "rename_file",
                            "operation_phase": "mutation",
                            "native_error_type": nativeErrorType(for: error),
                            "conflict_classification": isDuplicateNameError(error) ? "duplicate_name" : "native_or_transport_failure"
                        ]
                    )
                    dialogErrorMessage = error.localizedDescription
                }
            }
        }
    }

    private func cancelFileOperationDialog() {
        isSubmittingFileOperation = false
        dialogErrorMessage = nil
        newFolderRequest = nil
        renameRequest = nil
        NotificationCenter.default.post(name: .fileTypeaheadReset, object: nil)
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
        NotificationCenter.default.post(name: .fileTypeaheadReset, object: nil)
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

        case .requestRename(let file):
            beginRename(file: file, isLocal: isLocal)

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
                            ErrorLogger.log(error, message: "Drop copy failed")
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
                guard let storageId = validSelectedMTPStorageID() else { return }
                let nodes = mtpSources.map { FileNode(name: $0.name, path: $0.path, isDirectory: $0.isDirectory, size: 0, modificationDate: Date()) }
                FileTransferService.shared.initiateTransfer(
                    sources: nodes,
                    destinationDir: destination,
                    direction: .mtpToLocal,
                    storageId: storageId
                )
            }
        } else {
            if !localSources.isEmpty {
                guard let storageId = validSelectedMTPStorageID() else { return }
                let nodes = localSources.map { FileNode(name: $0.name, path: $0.path, isDirectory: $0.isDirectory, size: 0, modificationDate: Date()) }
                FileTransferService.shared.initiateTransfer(
                    sources: nodes,
                    destinationDir: destination,
                    direction: .localToMTP,
                    storageId: storageId
                )
            }
        }
    }

    private func validSelectedMTPStorageID() -> UInt32? {
        guard MTPDeviceManager.shared.isConnected,
              let storageId = MTPDeviceManager.shared.selectedStorageId,
              storageId != 0 else {
            operationErrorMessage = "Connect your Android device and select a storage before starting a transfer."
            return nil
        }
        return storageId
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
                    ErrorLogger.log(error, message: "Delete failed")
                }
            }
            selectedLocalItems.removeAll()
            pendingDeletePaths.removeAll()
            handleRefresh()
        } else {
            Task {
                do {
                    try await MTPDeviceManager.shared.deleteFiles(paths: paths)
                    await MainActor.run {
                        selectedMTPItems.removeAll()
                        pendingDeletePaths.removeAll()
                    }
                } catch {
                    ErrorLogger.log(
                        error,
                        message: "MTP delete failed",
                        userInfo: [
                            "operation": "delete_files",
                            "operation_phase": "mutation",
                            "native_error_type": nativeErrorType(for: error),
                            "conflict_classification": "none"
                        ]
                    )
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
                ErrorLogger.log(error, message: "Paste operation failed")
                operationErrorMessage = error.localizedDescription
            }
        }
    }

    private func performNewFolder() {
        guard !isSubmittingFileOperation else { return }
        let trimmedName = newFolderName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isValidChildName(trimmedName) else {
            dialogErrorMessage = "A file or folder name must not be empty or contain path separators."
            return
        }

        guard let request = newFolderRequest else { return }
        let parentPath = request.parentPath
        isSubmittingFileOperation = true
        dialogErrorMessage = nil

        if request.isLocal {
            let folderURL = URL(fileURLWithPath: parentPath).appendingPathComponent(trimmedName)
            do {
                try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: false)
                NotificationCenter.default.post(name: .localDirectoryNeedsRefresh, object: nil)
                isSubmittingFileOperation = false
                newFolderRequest = nil
            } catch {
                ErrorLogger.log(error, message: "Create folder failed")
                dialogErrorMessage = error.localizedDescription
                isSubmittingFileOperation = false
            }
        } else {
            Task { @MainActor in
                defer { isSubmittingFileOperation = false }
                do {
                    try await MTPDeviceManager.shared.createFolder(name: trimmedName, in: parentPath)
                    newFolderRequest = nil
                } catch {
                    ErrorLogger.log(
                        error,
                        message: "Create MTP folder failed",
                        userInfo: [
                            "operation": "make_directory",
                            "operation_phase": "mutation",
                            "native_error_type": nativeErrorType(for: error),
                            "conflict_classification": isDuplicateNameError(error) ? "duplicate_name" : "native_or_transport_failure"
                        ]
                    )
                    dialogErrorMessage = error.localizedDescription
                }
            }
        }
    }

    private func isDuplicateNameError(_ error: Error) -> Bool {
        guard let kalamError = error as? KalamError else { return false }
        if case .itemAlreadyExists = kalamError { return true }
        return false
    }

    private func isValidChildName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." &&
            !name.contains("/") && !name.contains("\\")
    }
}
