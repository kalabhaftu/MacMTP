import SwiftUI
import UniformTypeIdentifiers


struct DroppedFile {
    let path: String
    let isLocal: Bool
    let name: String
    let isDirectory: Bool

    static func extract(from pasteboard: NSPasteboard) -> [DroppedFile] {
        var collected: [DroppedFile] = []
        var seenPaths = Set<String>()

        // 1. Check internal string format: "local:file:/path" or "mtp:dir:/path"
        if let text = pasteboard.string(forType: NSPasteboard.PasteboardType(UTType.utf8PlainText.identifier)) ?? pasteboard.string(forType: .string) {
            let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
            var foundInternal = false
            for line in lines {
                let parts = line.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
                guard parts.count == 3 else { continue }
                let prefix = String(parts[0])
                guard prefix == "local" || prefix == "mtp" else { continue }
                let isMTP = prefix == "mtp"
                let isDirectory = parts[1] == "dir"
                let path = String(parts[2])
                let name = (path as NSString).lastPathComponent
                if !seenPaths.contains(path) {
                    seenPaths.insert(path)
                    collected.append(DroppedFile(path: path, isLocal: !isMTP, name: name, isDirectory: isDirectory))
                }
                foundInternal = true
            }
            if foundInternal {
                return collected
            }
        }

        // 2. Check NSFilenamesPboardType
        if let filenames = pasteboard.propertyList(forType: NSPasteboard.PasteboardType("NSFilenamesPboardType")) as? [String] {
            for path in filenames {
                guard !seenPaths.contains(path) else { continue }
                seenPaths.insert(path)
                var isDir: ObjCBool = false
                let exists = FileManager.default.fileExists(atPath: path, isDirectory: &isDir)
                guard exists else { continue }
                let name = (path as NSString).lastPathComponent
                collected.append(DroppedFile(path: path, isLocal: true, name: name, isDirectory: isDir.boolValue))
            }
            if !collected.isEmpty {
                return collected
            }
        }

        // 3. Check file URLs
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [
            .urlReadingFileURLsOnly: true
        ]) as? [URL] {
            for url in urls {
                let path = url.path
                guard !seenPaths.contains(path) else { continue }
                seenPaths.insert(path)
                var isDir: ObjCBool = false
                let exists = FileManager.default.fileExists(atPath: path, isDirectory: &isDir)
                guard exists else { continue }
                collected.append(DroppedFile(path: path, isLocal: true, name: url.lastPathComponent, isDirectory: isDir.boolValue))
            }
        }

        return collected
    }
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


enum FileExplorerLoadingState: Equatable {
    case idle
    case loading
    case loaded
    case empty
    case error(String)
}


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


struct FileExplorerPane: View {
    @AppStorage("appFontScale") private var appFontScale: Double = 1.0

    var title: String

    @Binding var currentPath: String

    @Binding var selectedItems: Set<String>

    var isLocal: Bool

    var isDisabled: Bool = false

    @Binding var files: [FileNode]

    let isActivePane: Bool
    let clipboardManager: ClipboardManager
    var onActivate: (() -> Void)? = nil
    var onConnect: (() -> Void)? = nil
    var onFilesDropped: (([DroppedFile], String) -> Void)? = nil
    var onFileOperation: ((FileOperation) -> Void)? = nil
    var onRequestNewFolder: ((String, Bool) -> Void)? = nil
    var onPaste: (() -> Void)? = nil
    var usesProvidedFiles: Bool = false
    

    @State private var loadingState: FileExplorerLoadingState = .idle
    @State private var nonBlockingErrorMessage: String?
    @State private var displayedFiles: [FileNode] = []
    @State private var ungroupedFiles: [FileNode] = []
    @State private var displayedGroups: [FileGroup] = []

    @State private var sortColumn: FileSortColumn = .name
    @State private var sortDirection: FileSortDirection = .ascending
    @State private var grouping: FileGrouping = .none
    @State private var extensionFilter: String?

    @State private var viewMode: FileViewMode = .icons

    @State private var pathHistory: [String] = []
    @State private var pathHistoryIndex: Int = -1

    @State private var filterText: String = ""
    @State private var isFilterVisible: Bool = false
    @FocusState private var isFilterFocused: Bool

    @State private var keySearchBuffer: String = ""
    @State private var lastKeyTime: Date = Date.distantPast

    @State private var isEditingPath: Bool = false
    @State private var editablePathText: String = ""

    @State private var propertiesFile: FileNode?

    @State private var isDropTargeted: Bool = false

    @State private var loadGeneration: UInt64 = 0


    enum FileOperation {
        case delete(paths: [String])
        case requestRename(file: FileNode)
        case open(path: String)
    }


    var body: some View {
        VStack(spacing: 0) {
            navigationHeader

            if organizationIsActive {
                organizationSummary
            }

            if isFilterVisible {
                filterBar
            }

            if viewMode == .list {
                columnHeaders
                Divider()
            }

            contentArea
        }
        .background(Color(NSColor.controlBackgroundColor))
        .contentShape(Rectangle())
        .simultaneousGesture(TapGesture().onEnded {
            guard !isDisabled else { return }
            onActivate?()
        })
        .overlay(alignment: .top) {
            if !isLocal, !files.isEmpty, let message = nonBlockingErrorMessage {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.yellow)
                    Text(message)
                        .font(.caption)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button {
                        Task { await MTPDeviceManager.shared.refreshFiles() }
                    } label: {
                        Label("Retry", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(.regularMaterial)
                .overlay(alignment: .bottom) { Divider() }
            }
        }
        .onAppear {
            if usesProvidedFiles {
                seedProvidedFiles()
            } else if !isDisabled {
                navigateTo(path: currentPath)
            }
        }
        .onChange(of: currentPath) { _, newPath in
            guard !usesProvidedFiles else { return }
            let currentHistoricalPath = pathHistory.indices.contains(pathHistoryIndex) ? pathHistory[pathHistoryIndex] : nil
            if !isDisabled && currentHistoricalPath != newPath {
                navigateTo(path: newPath)
            }
        }
        .onChange(of: files) { _, newFiles in
            resetTypeahead()
            applyFilterAndSort(using: newFiles)
        }
        .onChange(of: isDisabled) { _, disabled in
            guard !usesProvidedFiles else { return }
            if !disabled {
                loadDirectory()
            }
        }
        .onReceive(MTPDeviceManager.shared.$isLoading) { loading in
            guard !usesProvidedFiles, !isLocal else { return }
            if loading {
                loadingState = .loading
            } else {
                if let err = MTPDeviceManager.shared.errorMessage {
                    loadingState = .error(err)
                } else if files.isEmpty && displayedFiles.isEmpty {
                    loadingState = .empty
                } else {
                    loadingState = .loaded
                }
            }
        }
        .onReceive(MTPDeviceManager.shared.$mtpFiles) { newFiles in
            guard !usesProvidedFiles, !isLocal else { return }
            resetTypeahead()
            applyFilterAndSort(using: newFiles)
            if MTPDeviceManager.shared.isLoading {
                loadingState = .loading
            } else if newFiles.isEmpty {
                if let err = MTPDeviceManager.shared.errorMessage {
                    loadingState = .error(err)
                } else {
                    loadingState = .empty
                }
            } else {
                loadingState = .loaded
            }
        }
        .onReceive(MTPDeviceManager.shared.$errorMessage) { error in
            guard !usesProvidedFiles, !isLocal else { return }
            nonBlockingErrorMessage = error
            if error != nil, !files.isEmpty {
                loadingState = .loaded
            }
        }
        .onChange(of: showHiddenFilesLocal) { _, _ in
            if isLocal { applyFilterAndSort() }
        }
        .onChange(of: showHiddenFilesMTP) { _, _ in
            if !isLocal {
                applyFilterAndSort()
                guard !usesProvidedFiles else { return }
                Task {
                    await MTPDeviceManager.shared.refreshFiles()
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .localDirectoryNeedsRefresh)) { _ in
            if isLocal && !usesProvidedFiles {
                loadDirectory()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .fileTypeaheadKeyPressed)) { notification in
            guard isActivePane, !isDisabled,
                  let key = notification.object as? String else { return }
            handleKeyPress(key)
        }
        .onReceive(NotificationCenter.default.publisher(for: .fileTypeaheadReset)) { _ in
            resetTypeahead()
        }
        .onChange(of: browserOrganization) { _, _ in
            applyFilterAndSort()
        }
        .onChange(of: viewMode) { _, _ in
            applyFilterAndSort()
        }
        .onChange(of: isActivePane) { _, active in
            if active { resetTypeahead() }
        }
        .sheet(item: $propertiesFile) { file in
            FilePropertiesView(file: file, isLocal: isLocal)
        }
    }


    private var navigationHeader: some View {
        HStack(spacing: 6) {
            Button(action: navigateBack) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 12 * appFontScale, weight: .semibold))
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .disabled(pathHistoryIndex <= 0)
            .help("Go back")

            Button(action: navigateForward) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 12 * appFontScale, weight: .semibold))
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .disabled(pathHistoryIndex >= pathHistory.count - 1)
            .help("Go forward")

            Button(action: navigateUp) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 12 * appFontScale, weight: .semibold))
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .disabled(currentPath == "/" || currentPath.isEmpty)
            .help("Go to parent folder")

            if isEditingPath {
                TextField("Path", text: $editablePathText, onCommit: {
                    isEditingPath = false
                    navigateTo(path: editablePathText)
                })
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12 * appFontScale))
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

            Button(action: {
                let modes = FileViewMode.allCases
                let idx = modes.firstIndex(of: viewMode) ?? 0
                viewMode = modes[(idx + 1) % modes.count]
            }) {
                Image(systemName: viewMode.iconName)
                    .font(.system(size: 13 * appFontScale))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .help("View mode: \(viewMode.rawValue)")

            Button(action: {
                if isFilterVisible {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        isFilterVisible = false
                        filterText = ""
                    }
                    isFilterFocused = false
                } else {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        isFilterVisible = true
                    }
                    DispatchQueue.main.async {
                        isFilterFocused = true
                    }
                }
            }) {
                Image(systemName: isFilterVisible ? "magnifyingglass.circle.fill" : "magnifyingglass")
                    .font(.system(size: 14 * appFontScale))
                    .foregroundColor(isFilterVisible ? .accentColor : .secondary)
            }
            .buttonStyle(.plain)
            .help("Search files")

            organizationMenu

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
                            .font(.system(size: 8 * appFontScale))
                            .foregroundColor(.secondary)
                    }

                    Button(action: {
                        let targetPath = buildPath(upTo: index, from: components)
                        navigateTo(path: targetPath)
                    }) {
                        HStack(spacing: 3) {
                            if index == 0 {
                                Image(systemName: isLocal ? "laptopcomputer" : "ipad.and.iphone")
                                    .font(.system(size: 10 * appFontScale))
                            }
                            Text(component.isEmpty ? "/" : component)
                                .font(.system(size: 11 * appFontScale))
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


    private var filterBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.caption)
                .foregroundColor(.secondary)

            TextField("Search file names", text: $filterText)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11 * appFontScale))
                .focused($isFilterFocused)

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

    private var organizationMenu: some View {
        Menu {
            Section("Sort By") {
                Picker("Column", selection: $sortColumn) {
                    ForEach(FileSortColumn.allCases) { column in
                        Text(column.rawValue).tag(column)
                    }
                }
            }

            Section("Sort Direction") {
                Picker("Direction", selection: $sortDirection) {
                    ForEach(FileSortDirection.allCases) { direction in
                        Text(direction.rawValue).tag(direction)
                    }
                }
            }

            Section("Group in Icon Views") {
                Picker("Group By", selection: $grouping) {
                    ForEach(FileGrouping.allCases) { option in
                        Text(option.rawValue).tag(option)
                    }
                }
            }

            Section("Filter by Extension") {
                Button("All Extensions") { extensionFilter = nil }
                ForEach(availableExtensions, id: \.self) { ext in
                    Button {
                        extensionFilter = ext
                    } label: {
                        if extensionFilter == ext {
                            Label(".\(ext)", systemImage: "checkmark")
                        } else {
                            Text(".\(ext)")
                        }
                    }
                }
            }

            if organizationIsActive {
                Section {
                    Button(role: .destructive, action: resetOrganization) {
                        Label("Reset to Defaults", systemImage: "arrow.counterclockwise")
                    }
                }
            }
        } label: {
            Image(systemName: organizationIsActive ? "arrow.up.arrow.down.circle.fill" : "arrow.up.arrow.down.circle")
                .font(.system(size: 14 * appFontScale))
                .foregroundColor(organizationIsActive ? .accentColor : .secondary)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Sort, group, and filter files")
    }

    private func resetOrganization() {
        grouping = .none
        sortColumn = .name
        sortDirection = .ascending
        extensionFilter = nil
        applyFilterAndSort()
    }

    private var organizationSummary: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.up.arrow.down.circle.fill")
                .foregroundColor(.accentColor)

            if grouping != .none {
                Text("Grouped by " + grouping.rawValue)
            }

            if grouping != .none && (sortColumn != .name || sortDirection != .ascending) {
                Divider().frame(height: 12)
            }

            if sortColumn != .name || sortDirection != .ascending || grouping != .none {
                Text("Sorted by " + sortColumn.rawValue + " " + sortDirection.rawValue)
            }

            if let extensionFilter {
                Divider().frame(height: 12)
                Text("Filtered to ." + extensionFilter)
            }

            Spacer(minLength: 0)

            Button(action: resetOrganization) {
                HStack(spacing: 4) {
                    Image(systemName: "xmark.circle.fill")
                    Text("Clear")
                }
                .font(.system(size: 10 * appFontScale, weight: .semibold))
                .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .help("Clear grouping, sorting, and filters")
        }
        .font(.system(size: 10 * appFontScale, weight: .medium))
        .foregroundColor(.secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Color(NSColor.controlBackgroundColor).opacity(0.7))
        .overlay(alignment: .bottom) { Divider() }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(organizationSummaryAccessibilityLabel)
    }

    private var organizationSummaryAccessibilityLabel: String {
        var parts: [String] = []
        if grouping != .none { parts.append("Grouped by " + grouping.rawValue) }
        if sortColumn != .name || sortDirection != .ascending || grouping != .none {
            parts.append("Sorted by " + sortColumn.rawValue + " " + sortDirection.rawValue)
        }
        if let extensionFilter { parts.append("Filtered to ." + extensionFilter) }
        return parts.joined(separator: ", ")
    }

    private var availableExtensions: [String] {
        Array(Set(files.lazy.filter { !$0.isDirectory && !$0.extensionName.isEmpty }.map(\.extensionName))).sorted {
            $0.localizedStandardCompare($1) == .orderedAscending
        }
    }

    private var organizationIsActive: Bool {
        sortColumn != .name || sortDirection != .ascending || grouping != .none || extensionFilter != nil
    }

    private var browserOrganization: FileBrowserOrganization {
        FileBrowserOrganization(
            searchText: filterText,
            extensionFilter: extensionFilter,
            sortColumn: sortColumn,
            sortDirection: sortDirection,
            grouping: grouping
        )
    }


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
                    .font(.system(size: 11 * appFontScale, weight: .medium))
                    .foregroundColor(.secondary)

                if sortColumn == column {
                    Image(systemName: sortDirection.iconName)
                        .font(.system(size: 8 * appFontScale, weight: .bold))
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
        AppKitFileBrowser(
            files: ungroupedFiles,
            groups: [],
            selectedPaths: $selectedItems,
            mode: .list,
            fontScale: appFontScale,
            isLocal: isLocal,
            onOpen: handleDoubleClick,
            onActivate: { onActivate?() },
            onSelectionChanged: resetTypeahead,
            onContextMenu: { file in appKitContextMenu(for: file) },
            onFilesDropped: { droppedFiles, targetDir in
                onFilesDropped?(droppedFiles, targetDir ?? currentPath)
            }
        )
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
        AppKitFileBrowser(
            files: displayedFiles,
            groups: grouping == .none ? [] : displayedGroups,
            selectedPaths: $selectedItems,
            mode: viewMode,
            fontScale: appFontScale,
            isLocal: isLocal,
            onOpen: handleDoubleClick,
            onActivate: { onActivate?() },
            onSelectionChanged: resetTypeahead,
            onContextMenu: { file in appKitContextMenu(for: file) },
            onFilesDropped: { droppedFiles, targetDir in
                onFilesDropped?(droppedFiles, targetDir ?? currentPath)
            }
        )
        .contextMenu { emptySpaceContextMenuItems }
        .overlay(
            RoundedRectangle(cornerRadius: 0)
                .stroke(isDropTargeted ? Color.accentColor : Color.clear, lineWidth: 2)
        )
        .onDrop(of: [.fileURL, .utf8PlainText], isTargeted: $isDropTargeted) { providers in
            handleDrop(providers: providers)
        }
    }

    private func appKitContextMenu(for file: FileNode) -> NSMenu {
        let targeted = targetedItems(for: file)
        var actions: [() -> Void] = []
        let menu = NSMenu()

        func addAction(_ title: String, _ action: @escaping () -> Void) {
            let index = actions.count
            actions.append(action)
            let item = NSMenuItem(
                title: title,
                action: #selector(AppKitMenuActionProxy.invoke(_:)),
                keyEquivalent: ""
            )
            item.tag = index
            menu.addItem(item)
        }

        addAction("Open") { handleDoubleClick(file: file) }
        menu.addItem(.separator())
        addAction("Copy") {
            ClipboardManager.shared.copyItems(items: targeted, from: currentPath, isLocal: isLocal)
        }
        addAction("Cut") {
            ClipboardManager.shared.cutItems(items: targeted, from: currentPath, isLocal: isLocal)
        }
        addAction("Paste") { onPaste?() }
        menu.addItem(.separator())
        addAction("Delete") {
            onFileOperation?(.delete(paths: targeted.map(\.path)))
        }
        addAction("Rename") {
            resetTypeahead()
            onFileOperation?(.requestRename(file: file))
        }
        menu.addItem(.separator())
        addAction("New Folder") {
            resetTypeahead()
            onRequestNewFolder?(currentPath, isLocal)
        }
        addAction("Select All") {
            selectedItems = Set(displayedFiles.map(\.path))
        }
        menu.addItem(.separator())
        addAction("Properties") { propertiesFile = targeted.first ?? file }

        let proxy = AppKitMenuActionProxy(actions: actions)
        for item in menu.items where !item.isSeparatorItem {
            item.target = proxy
            item.representedObject = proxy
        }
        return menu
    }


    private func targetedItems(for file: FileNode) -> [FileNode] {
        guard selectedItems.contains(file.path) else {
            return [file]
        }
        let items = displayedFiles.filter { selectedItems.contains($0.path) }
        return items.isEmpty ? [file] : items
    }
    
    @ViewBuilder
    private var emptySpaceContextMenuItems: some View {
        Button(action: {
            onPaste?()
        }) {
            Label("Paste", systemImage: "doc.on.clipboard")
        }
        .disabled(!ClipboardManager.shared.hasContent)

        Button(action: {
            copyPaths([currentPath])
        }) {
            Label("Copy Current Path", systemImage: "doc.on.clipboard")
        }
        
        Divider()
        
        Button(action: {
            resetTypeahead()
            onRequestNewFolder?(currentPath, isLocal)
        }) {
            Label("New Folder", systemImage: "folder.badge.plus")
        }

        Button(action: {
            selectedItems = Set(displayedFiles.map { $0.path })
        }) {
            Label("Select All", systemImage: "checkmark.circle")
        }
        .disabled(displayedFiles.isEmpty)

        Button(action: {
            navigateTo(path: currentPath)
        }) {
            Label("Refresh", systemImage: "arrow.clockwise")
        }
    }

    private func copyPaths(_ paths: [String]) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(paths.joined(separator: "\n"), forType: .string)
    }


    private var disabledStateView: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: isLocal ? "externaldrive.badge.xmark" : "cable.connector.horizontal")
                .font(.system(size: 48 * appFontScale))
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

            if !isLocal {
                Button(action: { onConnect?() }) {
                    Label("Retry Connection", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
            }

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
                .font(.system(size: 40 * appFontScale))
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
                .font(.system(size: 44 * appFontScale))
                .foregroundColor(.secondary)
                .symbolRenderingMode(.hierarchical)

            Text("This folder is empty")
                .font(.headline)
                .foregroundColor(.secondary)

            if !filterText.isEmpty || extensionFilter != nil {
                Text(emptyFilterMessage)
                    .font(.caption)
                    .foregroundColor(.secondary)

                Button(action: {
                    filterText = ""
                    extensionFilter = nil
                }) {
                    Label("Clear Filters", systemImage: "xmark.circle")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(NSColor.controlBackgroundColor))
    }

    private var emptyFilterMessage: String {
        if let extensionFilter, !filterText.isEmpty {
            return "No .\(extensionFilter) files match \"\(filterText)\""
        }
        if let extensionFilter { return "No .\(extensionFilter) files in this folder" }
        return "No files match \"\(filterText)\""
    }




    private func navigateTo(path: String) {
        resetTypeahead()
        let cleanPath = path.isEmpty ? "/" : path
        if usesProvidedFiles {
            if pathHistoryIndex < pathHistory.count - 1 {
                pathHistory.removeSubrange((pathHistoryIndex + 1)...)
            }
            pathHistory.append(cleanPath)
            pathHistoryIndex = pathHistory.count - 1
            currentPath = cleanPath
            applyFilterAndSort()
            return
        }

        if isLocal {
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
        
        let manager = MTPDeviceManager.shared
        if cleanPath == manager.currentMTPPath && !manager.isLoading && !manager.mtpFiles.isEmpty {
            let currentFiles = manager.mtpFiles
            applyFilterAndSort(using: currentFiles)
            loadingState = .loaded
        } else {
            loadingState = .loading
            Task {
                await manager.navigateTo(path: cleanPath)
            }
        }
    }
    }

    private func navigateBack() {
        resetTypeahead()
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
        resetTypeahead()
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
        resetTypeahead()
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


    private func loadDirectory() {
        if usesProvidedFiles {
            seedProvidedFiles()
            return
        }
        if isLocal {
            loadingState = .loading
            let path = currentPath
            loadGeneration &+= 1
            let generation = loadGeneration
            DispatchQueue.global(qos: .userInitiated).async {
                let result = self.listLocalDirectory(path: path)
                DispatchQueue.main.async {
                    guard self.loadGeneration == generation else { return }
                    if case .failure(let error) = result {
                        self.loadingState = .error(error.localizedDescription)
                    } else if case .success(let items) = result {
                        self.files = items
                        self.applyFilterAndSort(using: items)
                        if items.isEmpty {
                            self.loadingState = .empty
                        } else if self.displayedFiles.isEmpty && (!self.filterText.isEmpty || self.extensionFilter != nil) {
                            self.loadingState = .empty
                        } else {
                            self.loadingState = .loaded
                        }
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
            let resourceKeys: Set<URLResourceKey> = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey]
            let contents = try FileManager.default.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: Array(resourceKeys),
                options: [.skipsPackageDescendants]
            )

            items.reserveCapacity(contents.count)
            for itemUrl in contents {
                let resourceValues = try? itemUrl.resourceValues(forKeys: resourceKeys)
                let isDir = resourceValues?.isDirectory ?? false
                let size = Int64(resourceValues?.fileSize ?? 0)
                let date = resourceValues?.contentModificationDate ?? Date()

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

    @AppStorage("showHiddenFilesLocal") private var showHiddenFilesLocal: Bool = false
    @AppStorage("showHiddenFilesMTP") private var showHiddenFilesMTP: Bool = false

    private func applyFilterAndSort(using input: [FileNode]? = nil) {
        resetTypeahead()
        let sourceFiles = input ?? files
        let showHidden = isLocal ? showHiddenFilesLocal : showHiddenFilesMTP
        let organization = browserOrganization
        displayedGroups = organization.organize(sourceFiles, showHidden: showHidden)
        var ungroupedOrganization = organization
        ungroupedOrganization.grouping = .none
        ungroupedFiles = ungroupedOrganization.organize(sourceFiles, showHidden: showHidden).flatMap(\.files)
        displayedFiles = viewMode == .list ? ungroupedFiles : displayedGroups.flatMap(\.files)

        let visiblePaths = Set(displayedFiles.map(\.path))
        selectedItems.formIntersection(visiblePaths)

        if displayedFiles.isEmpty && !sourceFiles.isEmpty && (!filterText.isEmpty || extensionFilter != nil) {
            loadingState = .empty
        } else if displayedFiles.isEmpty && sourceFiles.isEmpty {
            if !isLocal && MTPDeviceManager.shared.isLoading {
                loadingState = .loading
            } else if loadingState != .loading {
                loadingState = .empty
            }
        } else {
            loadingState = .loaded
        }
    }

    private func seedProvidedFiles() {
        if pathHistory.isEmpty {
            pathHistory = [currentPath.isEmpty ? "/" : currentPath]
            pathHistoryIndex = 0
        }
        applyFilterAndSort(using: files)
    }

    private func handleDoubleClick(file: FileNode) {
        if file.isDirectory {
            navigateTo(path: file.path)
        } else if isLocal {
            NSWorkspace.shared.open(URL(fileURLWithPath: file.path))
        }
    }

    private func handleKeyPress(_ key: String) {
        guard !key.isEmpty, !displayedFiles.isEmpty else { return }

        let now = Date()
        let result = FileTypeaheadRules.advance(
            key: key,
            files: displayedFiles,
            selectedPath: selectedItems.count == 1 ? selectedItems.first : nil,
            state: FileTypeaheadState(query: keySearchBuffer, lastKeyTime: lastKeyTime),
            now: now
        )
        keySearchBuffer = result.state.query
        lastKeyTime = result.state.lastKeyTime
        if let selectedPath = result.selectedPath {
            selectedItems = [selectedPath]
        }
    }

    private func resetTypeahead() {
        keySearchBuffer = ""
        lastKeyTime = .distantPast
    }


    private func handleDrop(providers: [NSItemProvider], targetDirectory: String? = nil) -> Bool {
        onActivate?()
        let collectedFiles = ThreadSafeArray<DroppedFile>()
        let group = DispatchGroup()
        let dropDestination = targetDirectory ?? currentPath

        for provider in providers {
            let suggestedName = provider.suggestedName ?? ""
            if provider.hasItemConformingToTypeIdentifier(UTType.utf8PlainText.identifier) {
                group.enter()
                let _ = provider.loadDataRepresentation(for: .utf8PlainText) { data, _ in
                    defer { group.leave() }
                    guard let data, let str = String(data: data, encoding: .utf8) else { return }

                    let lines = str.split(separator: "\n", omittingEmptySubsequences: true)
                    var foundInternalPayload = false

                    for line in lines {
                        let parts = line.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
                        guard parts.count == 3 else { continue }

                        let prefix = String(parts[0])
                        guard prefix == "local" || prefix == "mtp" else { continue }

                        let type = String(parts[1])
                        let path = String(parts[2])
                        let isMTP = prefix == "mtp"
                        let isDirectory = type == "dir"
                        let name = (path as NSString).lastPathComponent
                        collectedFiles.append(DroppedFile(path: path, isLocal: !isMTP, name: name, isDirectory: isDirectory))
                        foundInternalPayload = true
                    }

                    if !foundInternalPayload {
                        if let url = URL(string: str), url.isFileURL {
                            Self.appendLocalDroppedFile(url: url, suggestedName: suggestedName, to: collectedFiles)
                        } else if str.hasPrefix("/") {
                            Self.appendLocalDroppedFile(url: URL(fileURLWithPath: str), suggestedName: suggestedName, to: collectedFiles)
                        }
                    }
                }
            } else if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                group.enter()
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    if let url {
                        Self.appendLocalDroppedFile(url: url, suggestedName: suggestedName, to: collectedFiles)
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

    nonisolated private static func appendLocalDroppedFile(url: URL, suggestedName _: String, to files: ThreadSafeArray<DroppedFile>) {
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
        let isDirectory = exists && isDir.boolValue
        let name = url.lastPathComponent
        files.append(DroppedFile(path: url.path, isLocal: true, name: name, isDirectory: isDirectory))
    }


    private func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useAll]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }

    private func fileSizeDisplay(for file: FileNode) -> String {
        file.isDirectory ? "—" : formatBytes(file.size)
    }

    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    private func isValidChildName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." &&
            !name.contains("/") && !name.contains("\\")
    }
}

extension FileExplorerPane {
    func usesProvidedFiles(_ enabled: Bool) -> FileExplorerPane {
        var copy = self
        copy.usesProvidedFiles = enabled
        return copy
    }
}


struct FilePropertiesView: View {
    @AppStorage("appFontScale") private var appFontScale: Double = 1.0
    let file: FileNode
    let isLocal: Bool
    @Environment(\.dismiss) private var dismiss
    @State private var localDetails: LocalFileDetails?
    @State private var detailsError: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: file.iconName)
                    .font(.system(size: 32 * appFontScale))
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

            VStack(spacing: 0) {
                propertyRow(label: "Kind", value: file.isDirectory ? "Folder" : "Document")
                propertyRow(label: "Size", value: displaySize)
                propertyRow(label: "Modified", value: file.formattedDate)
                propertyRow(label: "Path", value: file.path)
                if !file.parentPath.isEmpty {
                    propertyRow(label: "Parent", value: file.parentPath)
                }
                if !file.extensionName.isEmpty {
                    propertyRow(label: "Extension", value: file.extensionName)
                }
                if let localDetails {
                    propertyRow(label: "Created", value: FormatUtils.formatDate(localDetails.creationDate))
                    propertyRow(label: "Permissions", value: localDetails.permissions)
                    propertyRow(label: "Owner", value: localDetails.owner)
                }
                if let detailsError {
                    propertyRow(label: "Details", value: detailsError)
                }
            }
            .padding(.vertical, 6)

            Divider()

            HStack {
                Button("Copy Path") { copyPath() }
                if isLocal {
                    Button("Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: file.path)])
                    }
                }
                Spacer()
                Button("Close") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .frame(width: 480)
        .frame(minHeight: 320)
        .background(Color(NSColor.windowBackgroundColor))
        .task(id: file.path) {
            await loadDetails()
        }
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

    private var displaySize: String {
        if let byteCount = localDetails?.byteCount {
            return FormatUtils.formatBytes(byteCount)
        }
        return file.formattedSize
    }

    private func copyPath() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(file.path, forType: .string)
    }

    private func loadDetails() async {
        guard isLocal else { return }
        do {
            let details = try await Task.detached(priority: .utility) {
                try LocalFileDetails.load(path: file.path, isDirectory: file.isDirectory)
            }.value
            await MainActor.run {
                localDetails = details
                detailsError = nil
            }
        } catch {
            await MainActor.run {
                detailsError = error.localizedDescription
            }
        }
    }
}

private struct LocalFileDetails: Sendable {
    let byteCount: Int64
    let creationDate: Date
    let permissions: String
    let owner: String

    static func load(path: String, isDirectory: Bool) throws -> LocalFileDetails {
        let fileManager = FileManager.default
        let attributes = try fileManager.attributesOfItem(atPath: path)
        let creationDate = (attributes[.creationDate] as? Date) ?? Date()
        let permissionsValue = (attributes[.posixPermissions] as? NSNumber)?.uint16Value ?? 0
        let owner = (attributes[.ownerAccountName] as? String) ?? "Unknown"
        let byteCount: Int64

        if isDirectory {
            byteCount = directoryByteCount(path: path)
        } else {
            byteCount = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        }

        return LocalFileDetails(
            byteCount: byteCount,
            creationDate: creationDate,
            permissions: String(format: "%04o", permissionsValue),
            owner: owner
        )
    }

    private static func directoryByteCount(path: String) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(
            at: URL(fileURLWithPath: path),
            includingPropertiesForKeys: [.isRegularFileKey, .totalFileSizeKey, .fileSizeKey],
            options: [],
            errorHandler: { _, _ in true }
        ) else { return 0 }

        var total: Int64 = 0
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .totalFileSizeKey, .fileSizeKey]),
                  values.isRegularFile == true else { continue }
            let fileSize = Int64(values.totalFileSize ?? values.fileSize ?? 0)
            let (sum, overflow) = total.addingReportingOverflow(fileSize)
            total = overflow ? Int64.max : sum
        }
        return total
    }
}
