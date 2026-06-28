import SwiftUI
import UniformTypeIdentifiers

// MARK: - Dropped File

/// whether it came from the local filesystem or an MTP device.
struct DroppedFile {
    let path: String
    let isLocal: Bool
    let name: String
    let isDirectory: Bool
}

final class ThreadSafeArray<T>: @unchecked Sendable {
    private var items: [T] = []
    private let lock = NSLock()

    func append(_ item: T) {
        lock.lock()
        items.append(item)
        lock.unlock()
    }

    var all: [T] {
        lock.lock()
        let copy = items
        lock.unlock()
        return copy
    }
}

// MARK: - File Explorer Loading State

enum FileExplorerLoadingState: Equatable {
    case idle
    case loading
    case loaded
    case empty
    case error(String)
}

// MARK: - Sort Column Identifier

enum FileSortColumn: String, CaseIterable {
    case name = "Name"
    case size = "Size"
    case type = "Type"
    case dateModified = "Date Modified"
}

enum FileSortDirection {
    case ascending
    case descending

    var toggled: FileSortDirection {
        self == .ascending ? .descending : .ascending
    }

    var iconName: String {
        self == .ascending ? "chevron.up" : "chevron.down"
    }
}

// MARK: - View Mode

enum FileViewMode: String, CaseIterable {
    case list = "List"
    case icons = "Icons"
    case largeIcons = "Large Icons"

    var iconName: String {
        switch self {
        case .list: return "list.bullet"
        case .icons: return "square.grid.2x2"
        case .largeIcons: return "square.grid.3x3"
        }
    }
}

// MARK: - File Explorer Pane

/// and MTP device file browsing. Features sortable columns, multi-selection,
struct FileExplorerPane: View {
    // MARK: - Properties

    var title: String

    @Binding var currentPath: String

    @Binding var selectedItems: Set<String>

    var isLocal: Bool

    var isDisabled: Bool = false

    @Binding var files: [FileNode]

    let isActivePane: Bool
    let clipboardManager: ClipboardManager
    var onFilesDropped: (([DroppedFile], String) -> Void)? = nil
    var onFileOperation: ((FileOperation) -> Void)? = nil
    var onPaste: (() -> Void)? = nil
    
    // MARK: - Staternal State

    @State private var loadingState: FileExplorerLoadingState = .idle
    @State private var displayedFiles: [FileNode] = []

    @State private var sortColumn: FileSortColumn = .name
    @State private var sortDirection: FileSortDirection = .ascending

    @State private var viewMode: FileViewMode = .icons

    @State private var pathHistory: [String] = []
    @State private var pathHistoryIndex: Int = -1

    @State private var filterText: String = ""
    @State private var isFilterVisible: Bool = false

    @State private var keySearchBuffer: String = ""
    @State private var lastKeyTime: Date = Date.distantPast

    @State private var isEditingPath: Bool = false
    @State private var editablePathText: String = ""

    @State private var showRenameDialog: Bool = false
    @State private var renameTargetFile: FileNode? = nil
    @State private var renameText: String = ""

    @State private var isCreatingNewFolder: Bool = false
    @State private var newFolderName: String = ""
    @State private var showProperties: Bool = false
    @State private var propertiesFile: FileNode?

    @State private var isDropTargeted: Bool = false

    @State private var sizeGen: UInt64 = 0

    @State private var contextMenuTargetID: String? = nil

    @State private var lastClickedItemID: String? = nil

    @State private var directorySizes: [String: Int64] = [:]

    // MARK: - Marquee Selection State

    @State private var dragRect: CGRect? = nil
    @State private var ignoreMarqueeDrag: Bool = false
    @State private var itemFrames: [String: CGRect] = [:]
    @State private var dragStartSelection: Set<String> = []

    // MARK: - File Operations Enum

    enum FileOperation {
        case delete(paths: [String])
        case rename(oldPath: String, newName: String)
        case newFolder(parentPath: String, name: String)
        case open(path: String)
    }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            // Navigation header
            navigationHeader

            // Filter bar (togglable)
            if isFilterVisible {
                filterBar
            }

            // Column headers (list mode only)
            if viewMode == .list {
                columnHeaders
                Divider()
            }

            // Main content area
            contentArea
        }
        .background(Color(NSColor.controlBackgroundColor))
        .onAppear {
            if !isDisabled {
                navigateTo(path: currentPath)
            }
        }
        .onChange(of: currentPath) { _, newPath in
            let currentHistoricalPath = pathHistory.indices.contains(pathHistoryIndex) ? pathHistory[pathHistoryIndex] : nil
            if !isDisabled && currentHistoricalPath != newPath {
                navigateTo(path: newPath)
            }
        }
        .onChange(of: files) { _, newFiles in
            applyFilterAndSort(using: newFiles)
        }
        .onChange(of: isDisabled) { _, disabled in
            if !disabled {
                loadDirectory()
            }
        }
        .onReceive(MTPDeviceManager.shared.$mtpFiles) { newFiles in
            guard !isLocal else { return }
            applyFilterAndSort(using: newFiles)
            if newFiles.isEmpty {
                if let err = MTPDeviceManager.shared.errorMessage {
                    loadingState = .error(err)
                } else {
                    loadingState = .empty
                }
            } else {
                loadingState = .loaded
            }
            sizeGen &+= 1
            calculateDirectorySizesAsync()
        }
        .onChange(of: showHiddenFilesLocal) { _, _ in
            if isLocal { applyFilterAndSort() }
        }
        .onChange(of: showHiddenFilesMTP) { _, _ in
            if !isLocal { applyFilterAndSort() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .localDirectoryNeedsRefresh)) { _ in
            if isLocal {
                loadDirectory()
            }
        }
        .onChange(of: filterText) { _, _ in
            applyFilterAndSort()
        }
        .onChange(of: sortColumn) { _, _ in
            applyFilterAndSort()
        }
        .onChange(of: sortDirection) { _, _ in
            applyFilterAndSort()
        }
        .background(
            KeyboardLetterNav(
                onKeyPress: { key in handleKeyPress(key) },
                isActive: isDisabled ? false : isActivePane
            )
        )
        .onChange(of: isActivePane) { _, active in
            if active { lastKeyTime = Date.distantPast }
        }
        .sheet(isPresented: $showProperties) {
            if let file = propertiesFile {
                FilePropertiesView(file: file, isLocal: isLocal)
            }
        }
        .alert("Rename", isPresented: $showRenameDialog) {
            TextField("New name", text: $renameText)
            Button("Cancel", role: .cancel) { }
            Button("Rename") {
                if let file = renameTargetFile {
                    commitRename(file: file)
                }
            }
        } message: {
            Text("Enter a new name for this item.")
        }
    }

    // MARK: - Navigation Header

    private var navigationHeader: some View {
        HStack(spacing: 6) {
            // Back button
            Button(action: navigateBack) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .disabled(pathHistoryIndex <= 0)
            .help("Go back")

            // Forward button
            Button(action: navigateForward) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .disabled(pathHistoryIndex >= pathHistory.count - 1)
            .help("Go forward")

            // Up button
            Button(action: navigateUp) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .disabled(currentPath == "/" || currentPath.isEmpty)
            .help("Go to parent folder")

            // Path bar
            if isEditingPath {
                TextField("Path", text: $editablePathText, onCommit: {
                    isEditingPath = false
                    navigateTo(path: editablePathText)
                })
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12))
                .onExitCommand {
                    isEditingPath = false
                }
            } else {
                pathBreadcrumbs
                    .onTapGesture(count: 2) {
                        editablePathText = currentPath
                        isEditingPath = true
                    }
            }

            Spacer(minLength: 4)

            // View mode toggle
            Button(action: {
                let modes = FileViewMode.allCases
                let idx = modes.firstIndex(of: viewMode) ?? 0
                viewMode = modes[(idx + 1) % modes.count]
            }) {
                Image(systemName: viewMode.iconName)
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .help("View mode: \(viewMode.rawValue)")

            // Filter toggle
            Button(action: {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isFilterVisible.toggle()
                    if !isFilterVisible { filterText = "" }
                }
            }) {
                Image(systemName: isFilterVisible ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                    .font(.system(size: 14))
                    .foregroundColor(isFilterVisible ? .accentColor : .secondary)
            }
            .buttonStyle(.plain)
            .help("Filter files")

            // Item count
            Text(itemCountText)
                .font(.caption2)
                .foregroundColor(.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color(NSColor.windowBackgroundColor))
    }

    private var pathBreadcrumbs: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                let components = pathComponents
                ForEach(Array(components.enumerated()), id: \.offset) { index, component in
                    if index > 0 {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 8))
                            .foregroundColor(.secondary)
                    }

                    Button(action: {
                        let targetPath = buildPath(upTo: index, from: components)
                        navigateTo(path: targetPath)
                    }) {
                        HStack(spacing: 3) {
                            if index == 0 {
                                Image(systemName: isLocal ? "laptopcomputer" : "ipad.and.iphone")
                                    .font(.system(size: 10))
                            }
                            Text(component.isEmpty ? "/" : component)
                                .font(.system(size: 11))
                                .lineLimit(1)
                        }
                        .padding(.horizontal, 4)
                        .padding(.vertical, 2)
                        .background(
                            RoundedRectangle(cornerRadius: 4)
                                .fill(Color(NSColor.controlBackgroundColor).opacity(0.5))
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var pathComponents: [String] {
        let path = currentPath
        if path == "/" { return ["/"] }
        var parts = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        parts.insert("/", at: 0)
        return parts
    }

    private func buildPath(upTo index: Int, from components: [String]) -> String {
        if index == 0 { return "/" }
        let subComponents = components[1...index]
        return "/" + subComponents.joined(separator: "/")
    }

    private var itemCountText: String {
        let total = displayedFiles.count
        let selected = selectedItems.count
        if selected > 0 {
            return "\(total) items (\(selected) selected)"
        }
        return "\(total) items"
    }

    // MARK: - Filter Bar

    private var filterBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.caption)
                .foregroundColor(.secondary)

            TextField("Filter by name or extension (e.g. .mp4)", text: $filterText)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11))

            if !filterText.isEmpty {
                Button(action: { filterText = "" }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Color(NSColor.controlBackgroundColor).opacity(0.7))
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    // MARK: - Column Headers

    private var columnHeaders: some View {
        HStack(spacing: 0) {
            columnHeader(title: "Name", column: .name, minWidth: 180)
            Divider().frame(height: 16)
            columnHeader(title: "Size", column: .size, minWidth: 70)
            Divider().frame(height: 16)
            columnHeader(title: "Type", column: .type, minWidth: 60)
            Divider().frame(height: 16)
            columnHeader(title: "Date Modified", column: .dateModified, minWidth: 120)
        }
        .frame(height: 24)
        .background(Color(NSColor.windowBackgroundColor).opacity(0.8))
    }

    private func columnHeader(title: String, column: FileSortColumn, minWidth: CGFloat) -> some View {
        Button(action: {
            if sortColumn == column {
                sortDirection = sortDirection.toggled
            } else {
                sortColumn = column
                sortDirection = .ascending
            }
        }) {
            HStack(spacing: 4) {
                Text(title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.secondary)

                if sortColumn == column {
                    Image(systemName: sortDirection.iconName)
                        .font(.system(size: 8, weight: .bold))
                        .foregroundColor(.accentColor)
                }

                Spacer()
            }
            .padding(.horizontal, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(minWidth: minWidth)
        .frame(maxWidth: column == .name ? .infinity : minWidth + 20)
    }

    // MARK: - Content Area

    @ViewBuilder
    private var contentArea: some View {
        if isDisabled {
            disabledStateView
        } else {
            switch loadingState {
            case .loading:
                loadingStateView
            case .error(let message):
                errorStateView(message: message)
            case .empty:
                emptyStateView
            default:
                if viewMode == .list {
                    listView
                } else {
                    iconGridView
                }
            }
        }
    }

    private var listView: some View {
        List(displayedFiles, selection: $selectedItems) { file in
            fileRow(for: file)
                .contextMenu { contextMenuItems(for: file) }
                .listRowSeparator(.visible)
                .onTapGesture(count: 2) {
                    handleDoubleClick(file: file)
                }
                .onTapGesture(count: 1) {
                    handleSingleClick(file: file)
                }
        }
        .listStyle(.inset)
        .contextMenu { emptySpaceContextMenuItems }
        .overlay(
            RoundedRectangle(cornerRadius: 0)
                .stroke(isDropTargeted ? Color.accentColor : Color.clear, lineWidth: 2)
        )
        .onDrop(of: [.fileURL, .utf8PlainText], isTargeted: $isDropTargeted) { providers in
            handleDrop(providers: providers)
        }
    }

    private var iconGridView: some View {
        let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: viewMode == .largeIcons ? 4 : 7)
        return GeometryReader { scrollGeo in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    LazyVGrid(columns: columns, spacing: 8) {
                        ForEach(displayedFiles) { file in
                            gridItemWithPreference(for: file)
                        }
                    }
                    Spacer()
                }
                .padding(12)
                .frame(minWidth: scrollGeo.size.width, minHeight: scrollGeo.size.height, alignment: .topLeading)
                .background(Color.white.opacity(0.001))
            }
            .coordinateSpace(name: "explorerSpace")
            .onPreferenceChange(ItemFramePreferenceKey.self) { frames in
                itemFrames = frames
            }
            .gesture(
                DragGesture(minimumDistance: 5)
                    .onChanged { value in
                        if dragRect == nil {
                            let start = value.startLocation
                            let hitItem = itemFrames.values.contains { $0.insetBy(dx: -4, dy: -4).contains(start) }
                            if hitItem {
                                ignoreMarqueeDrag = true
                                return
                            }
                            ignoreMarqueeDrag = false
                            
                            let modifiers = NSEvent.modifierFlags
                            if modifiers.contains(.shift) || modifiers.contains(.command) {
                                dragStartSelection = selectedItems
                            } else {
                                dragStartSelection = []
                                selectedItems.removeAll()
                            }
                        }
                        
                        if ignoreMarqueeDrag { return }
                        
                        let start = value.startLocation
                        let current = value.location
                        
                        let rect = CGRect(
                            x: min(start.x, current.x),
                            y: min(start.y, current.y),
                            width: abs(current.x - start.x),
                            height: abs(current.y - start.y)
                        )
                        self.dragRect = rect
                        
                        var newSelection = dragStartSelection
                        for (path, frame) in itemFrames {
                            if rect.intersects(frame) {
                                newSelection.insert(path)
                            }
                        }
                        selectedItems = newSelection
                    }
                    .onEnded { _ in
                        dragRect = nil
                        ignoreMarqueeDrag = false
                    }
            )
            .overlay(
                Group {
                    if let rect = dragRect, !ignoreMarqueeDrag {
                        Rectangle()
                            .fill(Color.accentColor.opacity(0.2))
                            .stroke(Color.accentColor, lineWidth: 1)
                            .frame(width: rect.width, height: rect.height)
                            .position(x: rect.midX, y: rect.midY)
                    }
                }
            )
        }
        .background(Color(NSColor.controlBackgroundColor))
        .contextMenu { emptySpaceContextMenuItems }
        .overlay(
            RoundedRectangle(cornerRadius: 0)
                .stroke(isDropTargeted ? Color.accentColor : Color.clear, lineWidth: 2)
        )
        .onTapGesture { selectedItems.removeAll() }
        .onDrop(of: [.fileURL, .utf8PlainText], isTargeted: $isDropTargeted) { providers in
            handleDrop(providers: providers)
        }
    }

    private func gridItemWithPreference(for file: FileNode) -> some View {
        let isSelected = selectedItems.contains(file.path)
        let iconSize: CGFloat = viewMode == .largeIcons ? 48 : 28

        return VStack(spacing: 4) {
            Image(systemName: file.iconName)
                .font(.system(size: iconSize))
                .foregroundColor(file.iconColor)
                .symbolRenderingMode(.hierarchical)

            Text(file.name)
                .font(viewMode == .largeIcons ? .caption : .caption2)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .truncationMode(.tail)
                .frame(maxWidth: viewMode == .largeIcons ? 80 : 60)

            if viewMode == .largeIcons {
                Text(fileSizeDisplay(for: file))
                    .font(.system(size: 8))
                    .foregroundColor(.secondary)
                    .monospacedDigit()
            }
        }
        .frame(
            width: viewMode == .largeIcons ? 90 : 70,
            height: viewMode == .largeIcons ? 110 : 70
        )
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isSelected ? Color.accentColor.opacity(0.15) : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(isSelected ? Color.accentColor.opacity(0.5) : Color.clear, lineWidth: 1.5)
        )
        .background(
            GeometryReader { geo in
                Color.clear.preference(
                    key: ItemFramePreferenceKey.self,
                    value: [file.path: geo.frame(in: .named("explorerSpace"))]
                )
            }
        )
        .onTapGesture(count: 2) {
            handleDoubleClick(file: file)
        }
        .onTapGesture(count: 1) {
            handleSingleClick(file: file)
        }
        .onDrag { dragProvider(for: file) }
        .onDrop(of: file.isDirectory ? [.fileURL, .utf8PlainText] : [], isTargeted: nil) { providers in
            handleDrop(providers: providers, targetDirectory: file.path)
        }
        .contextMenu { contextMenuItems(for: file) }
    }

    // MARK: - File Row

    private func fileRow(for file: FileNode) -> some View {
        HStack(spacing: 0) {
            // Name column
            HStack(spacing: 8) {
                Image(systemName: file.iconName)
                    .font(.system(size: 14))
                    .foregroundColor(file.iconColor)
                    .frame(width: 20)

                Text(file.name)
                    .font(.system(size: 12))
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer()
            }
            .frame(minWidth: 180, maxWidth: .infinity)

            // Size column
            Text(fileSizeDisplay(for: file))
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .monospacedDigit()
                .frame(minWidth: 70, maxWidth: 90, alignment: .trailing)
                .padding(.horizontal, 8)

            // Type column
            Text(file.isDirectory ? "Folder" : file.extensionName)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .frame(minWidth: 60, maxWidth: 80, alignment: .leading)
                .padding(.horizontal, 8)

            // Date column
            Text(formatDate(file.modificationDate))
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .frame(minWidth: 120, maxWidth: 140, alignment: .leading)
                .padding(.horizontal, 8)
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onDrag { dragProvider(for: file) }
        .onDrop(of: file.isDirectory ? [.fileURL, .utf8PlainText] : [], isTargeted: nil) { providers in
            handleDrop(providers: providers, targetDirectory: file.path)
        }
    }

    // MARK: - Context Menu

    @ViewBuilder
    private func contextMenuItems(for file: FileNode) -> some View {
        Button(action: { handleDoubleClick(file: file) }) {
            Label("Open", systemImage: "arrow.up.forward.square")
        }

        Divider()

        Button(action: {
            let items: [FileNode]
            if selectedItems.isEmpty {
                items = [file]
            } else {
                items = displayedFiles.filter { selectedItems.contains($0.path) }
            }
            ClipboardManager.shared.copyItems(items: items, from: currentPath, isLocal: isLocal)
        }) {
            Label("Copy", systemImage: "doc.on.doc")
        }

        Button(action: {
            let items: [FileNode]
            if selectedItems.isEmpty {
                items = [file]
            } else {
                items = displayedFiles.filter { selectedItems.contains($0.path) }
            }
            ClipboardManager.shared.cutItems(items: items, from: currentPath, isLocal: isLocal)
        }) {
            Label("Cut", systemImage: "scissors")
        }

        Button(action: {
            onPaste?()
        }) {
            Label("Paste", systemImage: "doc.on.clipboard")
        }
        .disabled(!ClipboardManager.shared.hasContent)

        Divider()

        Button(action: {
            onFileOperation?(.delete(paths: Array(selectedItems.isEmpty ? [file.path] : selectedItems)))
        }) {
            Label("Delete", systemImage: "trash")
        }

        Button(action: {
            renameTargetFile = file
            renameText = file.name
            showRenameDialog = true
        }) {
            Label("Rename", systemImage: "pencil")
        }

        Divider()

        Button(action: {
            isCreatingNewFolder = true
            newFolderName = "New Folder"
        }) {
            Label("New Folder", systemImage: "folder.badge.plus")
        }

        Button(action: {
            selectedItems = Set(displayedFiles.map { $0.path })
        }) {
            Label("Select All", systemImage: "checkmark.circle")
        }

        Divider()

        Button(action: {
            propertiesFile = selectedItems.isEmpty ? file : (displayedFiles.first { selectedItems.contains($0.path) } ?? file)
            showProperties = true
        }) {
            Label("Properties", systemImage: "info.circle")
        }
    }
    
    @ViewBuilder
    private var emptySpaceContextMenuItems: some View {
        Button(action: {
            onPaste?()
        }) {
            Label("Paste", systemImage: "doc.on.clipboard")
        }
        .disabled(!ClipboardManager.shared.hasContent)
        
        Divider()
        
        Button(action: {
            isCreatingNewFolder = true
            newFolderName = "New Folder"
        }) {
            Label("New Folder", systemImage: "folder.badge.plus")
        }
    }

    // MARK: - State Views

    private var disabledStateView: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: isLocal ? "externaldrive.badge.xmark" : "cable.connector.horizontal")
                .font(.system(size: 48))
                .foregroundColor(.secondary)
                .symbolRenderingMode(.hierarchical)

            Text(isLocal ? "Local drive not accessible" : "Connect an Android device to view files")
                .font(.headline)
                .foregroundColor(.secondary)

            Text(isLocal ? "Check that the selected volume is mounted." : "Plug in your Android device via USB and enable file transfer (MTP) mode.")
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 280)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(NSColor.underPageBackgroundColor))
    }

    private var loadingStateView: some View {
        VStack(spacing: 12) {
            Spacer()
            ProgressView()
                .scaleEffect(1.2)
            Text("Loading directory…")
                .font(.subheadline)
                .foregroundColor(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(NSColor.controlBackgroundColor))
    }

    private func errorStateView(message: String) -> some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 40))
                .foregroundColor(.orange)
                .symbolRenderingMode(.multicolor)

            Text("Error Loading Directory")
                .font(.headline)
                .foregroundColor(.primary)

            Text(message)
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 300)

            Button(action: { loadDirectory() }) {
                Label("Retry", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(NSColor.controlBackgroundColor))
    }

    private var emptyStateView: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "folder")
                .font(.system(size: 44))
                .foregroundColor(.secondary)
                .symbolRenderingMode(.hierarchical)

            Text("This folder is empty")
                .font(.headline)
                .foregroundColor(.secondary)

            if !filterText.isEmpty {
                Text("No files match the filter \"\(filterText)\"")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Button(action: { filterText = "" }) {
                    Label("Clear Filter", systemImage: "xmark.circle")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(NSColor.controlBackgroundColor))
    }



    // MARK: - Navigation

    private func navigateTo(path: String) {
        let cleanPath = path.isEmpty ? "/" : path

        if isLocal {
            // Update history
            if pathHistoryIndex < pathHistory.count - 1 {
                pathHistory.removeSubrange((pathHistoryIndex + 1)...)
            }
            pathHistory.append(cleanPath)
            pathHistoryIndex = pathHistory.count - 1

            currentPath = cleanPath
            selectedItems.removeAll()
            loadDirectory()
    } else {
        if pathHistoryIndex < pathHistory.count - 1 {
            pathHistory.removeSubrange((pathHistoryIndex + 1)...)
        }
        pathHistory.append(cleanPath)
        pathHistoryIndex = pathHistory.count - 1
        currentPath = cleanPath
        selectedItems.removeAll()
        loadingState = .loading
        Task {
            await MTPDeviceManager.shared.navigateTo(path: cleanPath)
        }
    }
    }

    private func navigateBack() {
        if isLocal {
            guard pathHistoryIndex > 0 else { return }
            pathHistoryIndex -= 1
            currentPath = pathHistory[pathHistoryIndex]
            selectedItems.removeAll()
            loadDirectory()
        } else {
            Task {
                await MTPDeviceManager.shared.navigateBack()
            }
        }
    }

    private func navigateForward() {
        if isLocal {
            guard pathHistoryIndex >= 0 && pathHistoryIndex < pathHistory.count - 1 else { return }
            pathHistoryIndex += 1
            currentPath = pathHistory[pathHistoryIndex]
            selectedItems.removeAll()
            loadDirectory()
        } else {
            Task {
                await MTPDeviceManager.shared.navigateForward()
            }
        }
    }

    private func navigateUp() {
        if isLocal {
            let url  = URL(fileURLWithPath: currentPath)
            let parentPath = url.deletingLastPathComponent().path
            if parentPath != currentPath {
                navigateTo(path: parentPath)
            }
        } else {
            Task {
                await MTPDeviceManager.shared.navigateUp()
            }
        }
    }

    // MARK: - Directory Loading

    private func loadDirectory() {
        if isLocal {
            loadingState = .loading
            let path = currentPath
            sizeGen &+= 1
            let gen = sizeGen
            DispatchQueue.global(qos: .userInitiated).async {
                let result = self.listLocalDirectory(path: path)
                DispatchQueue.main.async {
                    guard self.sizeGen == gen else { return }
                    if case .failure(let error) = result {
                        self.loadingState = .error(error.localizedDescription)
                    } else if case .success(let items) = result {
                        self.directorySizes.removeAll()
                        self.files = items
                        self.applyFilterAndSort()
                        self.loadingState = self.files.isEmpty ? .empty : .loaded
                        self.calculateDirectorySizesAsync()
                    }
                }
            }
        } else {
            loadingState = .loading
        }
    }

    nonisolated private func listLocalDirectory(path: String) -> Result<[FileNode], Error> {
        let url = URL(fileURLWithPath: path)
        var items: [FileNode] = []

        do {
            let contents = try FileManager.default.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey],
                options: []
            )

            for itemUrl in contents {
                let resourceValues = try itemUrl.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey])
                let isDir = resourceValues.isDirectory ?? false
                let size = Int64(resourceValues.fileSize ?? 0)
                let date = resourceValues.contentModificationDate ?? Date()

                items.append(
                    FileNode(
                        name: itemUrl.lastPathComponent,
                        path: itemUrl.path,
                        isDirectory: isDir,
                        size: isDir ? 0 : size,
                        modificationDate: date
                    )
                )
            }

            return .success(items)
        } catch {
            return .failure(error)
        }
    }

    private func calculateDirectorySizesAsync() {
        let gen = sizeGen
        let currentFiles = files
        let local = isLocal
        let storageId = MTPDeviceManager.shared.selectedStorageId
        Task {
            for i in currentFiles.indices where currentFiles[i].isDirectory {
                let isStale = await MainActor.run { self.sizeGen != gen }
                if isStale { break }

                let size = await FileNode.calculateDirectorySize(
                    path: currentFiles[i].path,
                    isLocal: local,
                    storageId: storageId
                )
                if let size = size {
                    await MainActor.run {
                        guard self.sizeGen == gen else { return }
                        self.directorySizes[currentFiles[i].path] = size
                    }
                }
            }
        }
    }

    // MARK: - Filtering & Sorting

    @AppStorage("showHiddenFilesLocal") private var showHiddenFilesLocal: Bool = false
    @AppStorage("showHiddenFilesMTP") private var showHiddenFilesMTP: Bool = false

    private func applyFilterAndSort(using input: [FileNode]? = nil) {
        var result = input ?? files

        // Filter hidden files
        let showHidden = isLocal ? showHiddenFilesLocal : showHiddenFilesMTP
        if !showHidden {
            result = result.filter { !$0.name.hasPrefix(".") }
        }

        // Apply search filter
        if !filterText.isEmpty {
            let query = filterText.lowercased()
            if query.hasPrefix(".") {
                // Extension filter mode
                let ext = String(query.dropFirst())
                result = result.filter {
                    $0.extensionName.lowercased() == ext || $0.isDirectory
                }
            } else {
                result = result.filter {
                    $0.name.lowercased().contains(query)
                }
            }
        }

        // Apply sort — directories always first
        result.sort { a, b in
            if a.isDirectory != b.isDirectory {
                return a.isDirectory
            }
            return compareFiles(a, b)
        }

        displayedFiles = result

        if displayedFiles.isEmpty && !files.isEmpty && !filterText.isEmpty {
            loadingState = .empty
        } else if displayedFiles.isEmpty && files.isEmpty {
            loadingState = .empty
        } else {
            loadingState = .loaded
        }
    }

    private func compareFiles(_ a: FileNode, _ b: FileNode) -> Bool {
        let ascending: Bool
        switch sortColumn {
        case .name:
            ascending = a.name.localizedStandardCompare(b.name) == .orderedAscending
        case .size:
            ascending = a.size < b.size
        case .type:
            ascending = a.extensionName.localizedStandardCompare(b.extensionName) == .orderedAscending
        case .dateModified:
            ascending = a.modificationDate < b.modificationDate
        }
        return sortDirection == .ascending ? ascending : !ascending
    }

    // MARK: - Click Handlers

    private func handleDoubleClick(file: FileNode) {
        if file.isDirectory {
            navigateTo(path: file.path)
        } else if isLocal {
            NSWorkspace.shared.open(URL(fileURLWithPath: file.path))
        }
    }

    private func handleSingleClick(file: FileNode) {
        let flags = NSEvent.modifierFlags
        if flags.contains(.command) {
            handleCommandClick(file: file)
        } else if flags.contains(.shift) {
            handleShiftClick(file: file)
        } else {
            selectedItems = [file.path]
            lastClickedItemID = file.path
        }
    }

    // Removed updateSelectionForMarquee

    private func dragProvider(for file: FileNode) -> NSItemProvider {
        let items: [FileNode]
        if selectedItems.contains(file.path) {
            items = displayedFiles.filter { selectedItems.contains($0.path) }
        } else {
            selectedItems = [file.path]
            lastClickedItemID = file.path
            items = [file]
        }
        
        let provider = NSItemProvider()
        
        if isLocal {
            // For Finder compatibility when dragging multiple files
            let paths = items.map { $0.path }
            if let data = try? PropertyListSerialization.data(fromPropertyList: paths, format: .xml, options: 0) {
                provider.registerDataRepresentation(forTypeIdentifier: "NSFilenamesPboardType", visibility: .all) { completion in
                    completion(data, nil)
                    return nil
                }
            }
            
            // Still register the primary object for single-file drag scenarios
            if let firstLocal = items.first {
                let url = URL(fileURLWithPath: firstLocal.path)
                provider.registerObject(url as NSURL, visibility: .all)
            }
        }
        
        provider.registerDataRepresentation(for: .utf8PlainText, visibility: .all) { completion in
            let payloads = items.map { "\(isLocal ? "local" : "mtp"):\($0.isDirectory ? "dir" : "file"):\($0.path)" }.joined(separator: "\n")
            let data = payloads.data(using: .utf8)
            completion(data, nil)
            return nil
        }
        provider.suggestedName = items.first?.name ?? file.name
        return provider
    }

    private func handleCommandClick(file: FileNode) {
        if selectedItems.contains(file.path) {
            selectedItems.remove(file.path)
        } else {
            selectedItems.insert(file.path)
        }
        lastClickedItemID = file.path
    }

    private func handleShiftClick(file: FileNode) {
        guard let lastID = lastClickedItemID,
              let lastIndex = displayedFiles.firstIndex(where: { $0.path == lastID }),
              let currentIndex = displayedFiles.firstIndex(where: { $0.path == file.path })
        else {
            selectedItems = [file.path]
            lastClickedItemID = file.path
            return
        }

        let range = min(lastIndex, currentIndex)...max(lastIndex, currentIndex)
        for i in range {
            selectedItems.insert(displayedFiles[i].path)
        }
    }

    // MARK: - Keyboard Letter Navigation

    private func handleKeyPress(_ key: String) {
        guard !key.isEmpty, !displayedFiles.isEmpty else { return }

        let now = Date()
        let timeDiff = now.timeIntervalSince(lastKeyTime)
        lastKeyTime = now

        if timeDiff < 1.0 {
            keySearchBuffer += key.lowercased()
        } else {
            keySearchBuffer = key.lowercased()
        }

        let matches = displayedFiles.filter { $0.name.lowercased().hasPrefix(keySearchBuffer) }
        guard !matches.isEmpty else { return }

        let selectedMatch = matches.first { selectedItems.contains($0.path) }

        if let current = selectedMatch, let currentIndex = matches.firstIndex(of: current) {
            let nextIndex = (currentIndex + 1) % matches.count
            let next = matches[nextIndex]
            selectedItems = [next.path]
            lastClickedItemID = next.path
        } else {
            let first = matches[0]
            selectedItems = [first.path]
            lastClickedItemID = first.path
        }
    }

    // MARK: - Rename

    private func commitRename(file: FileNode) {
        let trimmed = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != file.name else {
            return
        }

        if isLocal {
            let sourceURL = URL(fileURLWithPath: file.path)
            let destURL = sourceURL.deletingLastPathComponent().appendingPathComponent(trimmed)
            do {
                try FileManager.default.moveItem(at: sourceURL, to: destURL)
                loadDirectory()
            } catch {
                print("Rename failed: \(error)")
            }
        } else {
            onFileOperation?(.rename(oldPath: file.path, newName: trimmed))
        }
    }

    // MARK: - Drag & Drop

    private func handleDrop(providers: [NSItemProvider], targetDirectory: String? = nil) -> Bool {
        let collectedFiles = ThreadSafeArray<DroppedFile>()
        let group = DispatchGroup()
        let dropDestination = targetDirectory ?? currentPath

        for provider in providers {
            let suggestedName = provider.suggestedName ?? ""
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                group.enter()
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    if let url {
                        var isDir: ObjCBool = false
                        let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
                        let isDirectory = exists && isDir.boolValue
                        let name = suggestedName.isEmpty ? url.lastPathComponent : suggestedName
                        collectedFiles.append(DroppedFile(path: url.path, isLocal: true, name: name, isDirectory: isDirectory))
                    }
                    group.leave()
                }
            } else if provider.hasItemConformingToTypeIdentifier(UTType.utf8PlainText.identifier) {
                group.enter()
                let _ = provider.loadDataRepresentation(for: .utf8PlainText) { data, _ in
                    if let data, let str = String(data: data, encoding: .utf8) {
                        let lines = str.split(separator: "\n", omittingEmptySubsequences: true)
                        for line in lines {
                            let parts = line.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
                            if parts.count == 3 {
                                let prefix = String(parts[0])
                                let type = String(parts[1])
                                let path = String(parts[2])
                                let isMTP = prefix == "mtp"
                                let isDirectory = type == "dir"
                                let name = (path as NSString).lastPathComponent
                                collectedFiles.append(DroppedFile(path: path, isLocal: !isMTP, name: name, isDirectory: isDirectory))
                            }
                        }
                    }
                    group.leave()
                }
            }
        }

        group.notify(queue: .main) {
            let files = collectedFiles.all
            if !files.isEmpty {
                onFilesDropped?(files, dropDestination)
            }
        }

        return true
    }

    // MARK: - Formatting Utilities

    private func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useAll]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }

    private func fileSizeDisplay(for file: FileNode) -> String {
        if file.isDirectory {
            if let size = directorySizes[file.path] {
                return formatBytes(size)
            }
            if let calculatedSize = file.calculatedSize {
                return formatBytes(calculatedSize)
            }
            return "—"
        }
        return formatBytes(file.size)
    }

    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}

// MARK: - Keyboard Letter Navigation (NSViewRepresentable)

    struct KeyboardLetterNav: NSViewRepresentable {
    var onKeyPress: (String) -> Void
    var isActive: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(onKeyPress: onKeyPress)
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        context.coordinator.installMonitor()
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.onKeyPress = onKeyPress
        context.coordinator.isActive = isActive
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.removeMonitor()
    }

    class Coordinator: NSObject {
        var onKeyPress: (String) -> Void
        var isActive: Bool = false
        private var monitor: Any?

        init(onKeyPress: @escaping (String) -> Void) {
            self.onKeyPress = onKeyPress
        }

        func installMonitor() {
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self = self, self.isActive else { return event }
                let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                guard modifiers == [] else { return event }
                guard let chars = event.charactersIgnoringModifiers?.lowercased(), !chars.isEmpty else { return event }
                guard chars.rangeOfCharacter(from: .letters) != nil else { return event }
                self.onKeyPress(chars)
                return event
            }
        }

        func removeMonitor() {
            if let m = monitor {
                NSEvent.removeMonitor(m)
                monitor = nil
            }
        }

        deinit {
            removeMonitor()
        }
    }
}

// MARK: - File Properties View

struct FilePropertiesView: View {
    let file: FileNode
    let isLocal: Bool
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: file.iconName)
                    .font(.system(size: 32))
                    .foregroundColor(file.iconColor)
                VStack(alignment: .leading, spacing: 4) {
                    Text(file.name)
                        .font(.title3)
                        .fontWeight(.semibold)
                        .lineLimit(1)
                    Text(isLocal ? "Local file" : "MTP device file")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
            }
            .padding()

            Divider()

            Group {
                propertyRow(label: "Kind", value: file.isDirectory ? "Folder" : "Document")
                propertyRow(label: "Size", value: file.formattedSize)
                propertyRow(label: "Modified", value: file.formattedDate)
                propertyRow(label: "Path", value: file.path)
                if !file.parentPath.isEmpty {
                    propertyRow(label: "Parent", value: file.parentPath)
                }
                if !file.extensionName.isEmpty {
                    propertyRow(label: "Extension", value: file.extensionName)
                }
            }

            Divider()

            HStack {
                Spacer()
                Button("Close") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .frame(width: 380)
        .background(Color(NSColor.windowBackgroundColor))
    }

    private func propertyRow(label: String, value: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(label)
                .font(.caption)
                .foregroundColor(.secondary)
                .frame(width: 70, alignment: .trailing)
            Text(value)
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
                .lineLimit(2)
            Spacer()
        }
        .padding(.horizontal)
        .padding(.vertical, 6)
    }
}

// MARK: - Item Frame Preference Key

struct ItemFramePreferenceKey: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]
    
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue()) { current, _ in current }
    }
}
