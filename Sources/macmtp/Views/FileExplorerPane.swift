import SwiftUI
import UniformTypeIdentifiers


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

    @State private var keySearchBuffer: String = ""
    @State private var lastKeyTime: Date = Date.distantPast

    @State private var isEditingPath: Bool = false
    @State private var editablePathText: String = ""

    @State private var showRenameDialog: Bool = false
    @State private var renameTargetFile: FileNode? = nil
    @State private var renameText: String = ""

    @State private var propertiesFile: FileNode?

    @State private var isDropTargeted: Bool = false

    @State private var loadGeneration: UInt64 = 0

    @State private var contextMenuTargetID: String? = nil

    @State private var lastClickedItemID: String? = nil

    @State private var dragRect: CGRect? = nil
    @State private var ignoreMarqueeDrag: Bool = false
    @State private var itemFrames: [String: CGRect] = [:]
    @State private var dragStartSelection: Set<String> = []


    enum FileOperation {
        case delete(paths: [String])
        case rename(oldPath: String, newName: String)
        case open(path: String)
    }


    var body: some View {
        VStack(spacing: 0) {
            navigationHeader

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
            applyFilterAndSort(using: newFiles)
        }
        .onChange(of: isDisabled) { _, disabled in
            guard !usesProvidedFiles else { return }
            if !disabled {
                loadDirectory()
            }
        }
        .onReceive(MTPDeviceManager.shared.$mtpFiles) { newFiles in
            guard !usesProvidedFiles else { return }
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
        .onChange(of: browserOrganization) { _, _ in
            applyFilterAndSort()
        }
        .onChange(of: viewMode) { _, _ in
            applyFilterAndSort()
        }
        .background(
            KeyboardLetterNav(
                onKeyPress: { key in handleKeyPress(key) },
                isActive: isDisabled ? false : isActivePane
            )
        )
        .onChange(of: isActivePane) { _, active in
            if active { resetTypeahead() }
        }
        .sheet(item: $propertiesFile) { file in
            FilePropertiesView(file: file, isLocal: isLocal)
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
                withAnimation(.easeInOut(duration: 0.2)) {
                    isFilterVisible.toggle()
                    if !isFilterVisible { filterText = "" }
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
                ForEach(FileSortColumn.allCases) { column in
                    Button {
                        if sortColumn == column {
                            sortDirection = sortDirection.toggled
                        } else {
                            sortColumn = column
                            sortDirection = .ascending
                        }
                    } label: {
                        if sortColumn == column {
                            Label(column.rawValue, systemImage: sortDirection.iconName)
                        } else {
                            Text(column.rawValue)
                        }
                    }
                }
                Divider()
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

            Section("File Extension") {
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
        } label: {
            Image(systemName: organizationIsActive ? "arrow.up.arrow.down.circle.fill" : "arrow.up.arrow.down.circle")
                .font(.system(size: 14 * appFontScale))
                .foregroundColor(organizationIsActive ? .accentColor : .secondary)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Sort, group, and filter by extension")
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
        List(selection: $selectedItems) {
            ForEach(ungroupedFiles) { file in
                fileRow(for: file)
                    .tag(file.path)
                    .contextMenu { contextMenuItems(for: file) }
                    .listRowSeparator(.visible)
                    .onTapGesture(count: 2) {
                        handleDoubleClick(file: file)
                    }
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
        return GeometryReader { scrollGeo in
            let isLarge = viewMode == .largeIcons
            let cellWidth = CGFloat(FileGridLayout.cellWidth(large: isLarge))
            let columnSpacing = CGFloat(FileGridLayout.spacing)
            let columnCount = FileGridLayout.columnCount(
                containerWidth: scrollGeo.size.width,
                large: isLarge
            )
            let columns = Array(
                repeating: GridItem(.fixed(cellWidth), spacing: columnSpacing, alignment: .top),
                count: columnCount
            )

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    LazyVGrid(columns: columns, spacing: 8) {
                        ForEach(displayedGroups) { group in
                            if grouping != .none {
                                groupHeader(group)
                                    .gridCellColumns(columns.count)
                            }
                            ForEach(group.files) { file in
                                gridItemWithPreference(for: file, cellWidth: cellWidth)
                            }
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
        .onTapGesture {
            resetTypeahead()
            selectedItems.removeAll()
        }
        .onDrop(of: [.fileURL, .utf8PlainText], isTargeted: $isDropTargeted) { providers in
            handleDrop(providers: providers)
        }
    }

    private func groupHeader(_ group: FileGroup) -> some View {
        HStack {
            Text(group.title)
                .font(.system(size: 11 * appFontScale, weight: .semibold))
                .foregroundStyle(.secondary)
            Text("\(group.files.count)")
                .font(.system(size: 10 * appFontScale))
                .foregroundStyle(.tertiary)
            Spacer()
        }
        .padding(.vertical, 3)
    }

    private func gridItemWithPreference(for file: FileNode, cellWidth: CGFloat) -> some View {
        let isSelected = selectedItems.contains(file.path)
        let iconSize: CGFloat = viewMode == .largeIcons ? 48 : 28
        let isLarge = viewMode == .largeIcons
        let labelHeight = CGFloat(FileGridLayout.labelHeight(large: isLarge))
        let cellHeight = CGFloat(FileGridLayout.cellHeight(large: isLarge))

        return VStack(spacing: 4) {
            Image(systemName: file.iconName)
                .font(.system(size: iconSize))
                .foregroundColor(file.iconColor)
                .symbolRenderingMode(.hierarchical)
                .frame(height: iconSize)

            Text(file.name)
                .font(viewMode == .largeIcons ? .caption : .caption2)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .truncationMode(.tail)
                .frame(width: cellWidth - 8, height: labelHeight, alignment: .top)

            if viewMode == .largeIcons {
                Text(fileSizeDisplay(for: file))
                    .font(.system(size: 8 * appFontScale))
                    .foregroundColor(.secondary)
                    .monospacedDigit()
                    .frame(height: 10)
            }
        }
        .frame(
            width: cellWidth,
            height: cellHeight,
            alignment: .top
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


    private func fileRow(for file: FileNode) -> some View {
        HStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: file.iconName)
                    .font(.system(size: 14 * appFontScale))
                    .foregroundColor(file.iconColor)
                    .frame(width: 20)

                Text(file.name)
                    .font(.system(size: 12 * appFontScale))
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer()
            }
            .frame(minWidth: 180, maxWidth: .infinity)

            Text(fileSizeDisplay(for: file))
                .font(.system(size: 11 * appFontScale))
                .foregroundColor(.secondary)
                .monospacedDigit()
                .frame(minWidth: 70, maxWidth: 90, alignment: .trailing)
                .padding(.horizontal, 8)

            Text(file.isDirectory ? "Folder" : file.extensionName)
                .font(.system(size: 11 * appFontScale))
                .foregroundColor(.secondary)
                .frame(minWidth: 60, maxWidth: 80, alignment: .leading)
                .padding(.horizontal, 8)

            Text(formatDate(file.modificationDate))
                .font(.system(size: 11 * appFontScale))
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


    @ViewBuilder
    private func contextMenuItems(for file: FileNode) -> some View {
        Button(action: { handleDoubleClick(file: file) }) {
            Label("Open", systemImage: "arrow.up.forward.square")
        }

        Divider()

        Button(action: {
            ClipboardManager.shared.copyItems(items: targetedItems(for: file), from: currentPath, isLocal: isLocal)
        }) {
            Label("Copy", systemImage: "doc.on.doc")
        }

        Button(action: {
            copyPaths(targetedItems(for: file).map(\.path))
        }) {
            Label(targetedItems(for: file).count == 1 ? "Copy Path" : "Copy Paths", systemImage: "doc.on.clipboard")
        }

        Button(action: {
            ClipboardManager.shared.cutItems(items: targetedItems(for: file), from: currentPath, isLocal: isLocal)
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
            onFileOperation?(.delete(paths: targetedItems(for: file).map(\.path)))
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

        if isLocal {
            Button(action: {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: file.path)])
            }) {
                Label("Show in Finder", systemImage: "finder")
            }
        }

        Divider()

        Button(action: {
            propertiesFile = targetedItems(for: file).first ?? file
        }) {
            Label("Properties", systemImage: "info.circle")
        }
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
        if cleanPath == manager.currentMTPPath && !manager.isLoading {
            let currentFiles = manager.mtpFiles
            applyFilterAndSort(using: currentFiles)
            if currentFiles.isEmpty {
                if let err = manager.errorMessage {
                    loadingState = .error(err)
                } else {
                    loadingState = .empty
                }
            } else {
                loadingState = .loaded
            }
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
                        self.applyFilterAndSort()
                        self.loadingState = self.files.isEmpty ? .empty : .loaded
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

    @AppStorage("showHiddenFilesLocal") private var showHiddenFilesLocal: Bool = false
    @AppStorage("showHiddenFilesMTP") private var showHiddenFilesMTP: Bool = false

    private func applyFilterAndSort(using input: [FileNode]? = nil) {
        resetTypeahead()
        let showHidden = isLocal ? showHiddenFilesLocal : showHiddenFilesMTP
        let organization = browserOrganization
        displayedGroups = organization.organize(input ?? files, showHidden: showHidden)
        var ungroupedOrganization = organization
        ungroupedOrganization.grouping = .none
        ungroupedFiles = ungroupedOrganization.organize(input ?? files, showHidden: showHidden).flatMap(\.files)
        displayedFiles = viewMode == .list ? ungroupedFiles : displayedGroups.flatMap(\.files)

        let visiblePaths = Set(displayedFiles.map(\.path))
        selectedItems.formIntersection(visiblePaths)
        if let lastClickedItemID, !visiblePaths.contains(lastClickedItemID) {
            self.lastClickedItemID = nil
        }

        if displayedFiles.isEmpty && !files.isEmpty && (!filterText.isEmpty || extensionFilter != nil) {
            loadingState = .empty
        } else if displayedFiles.isEmpty && files.isEmpty {
            loadingState = .empty
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

    private func handleSingleClick(file: FileNode) {
        resetTypeahead()
        let flags = NSEvent.modifierFlags
        if flags.contains(.shift) {
            handleShiftClick(file: file, additive: flags.contains(.command))
        } else if flags.contains(.command) {
            handleCommandClick(file: file)
        } else {
            selectedItems = [file.path]
            lastClickedItemID = file.path
        }
    }

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
        let paths = items.map { $0.path }
            if let data = try? PropertyListSerialization.data(fromPropertyList: paths, format: .xml, options: 0) {
                provider.registerDataRepresentation(forTypeIdentifier: "NSFilenamesPboardType", visibility: .all) { completion in
                    completion(data, nil)
                    return nil
                }
            }
            
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
        resetTypeahead()
        if selectedItems.contains(file.path) {
            selectedItems.remove(file.path)
        } else {
            selectedItems.insert(file.path)
        }
        lastClickedItemID = file.path
    }

    private func handleShiftClick(file: FileNode, additive: Bool) {
        resetTypeahead()
        guard let lastID = lastClickedItemID,
              let rangeSelection = FileSelectionRules.range(
                in: displayedFiles.map(\.path),
                from: lastID,
                through: file.path
              ) else {
            selectedItems = [file.path]
            lastClickedItemID = file.path
            return
        }

        if additive {
            selectedItems.formUnion(rangeSelection)
        } else {
            selectedItems = rangeSelection
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
            lastClickedItemID = selectedPath
        }
    }

    private func resetTypeahead() {
        keySearchBuffer = ""
        lastKeyTime = .distantPast
    }


    private func commitRename(file: FileNode) {
        let trimmed = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isValidChildName(trimmed), trimmed != file.name else {
            return
        }

        if isLocal {
            let sourceURL = URL(fileURLWithPath: file.path)
            let destURL = sourceURL.deletingLastPathComponent().appendingPathComponent(trimmed)
            do {
                try FileManager.default.moveItem(at: sourceURL, to: destURL)
                loadDirectory()
            } catch {
                ErrorLogger.log(error, message: "Rename failed")
            }
        } else {
            onFileOperation?(.rename(oldPath: file.path, newName: trimmed))
        }
    }

    private func handleDrop(providers: [NSItemProvider], targetDirectory: String? = nil) -> Bool {
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
                let isTextEditing = MainActor.assumeIsolated {
                    NSApp.modalWindow != nil
                        || (NSApp.keyWindow?.firstResponder is NSTextField)
                        || (NSApp.keyWindow?.firstResponder is NSTextView)
                }
                guard !isTextEditing else { return event }
                if let responder = MainActor.assumeIsolated({ NSApp.keyWindow?.firstResponder }),
                   responder is NSTextField || responder is NSTextView {
                    return event
                }
                let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                guard modifiers == [] else { return event }
                guard let chars = event.charactersIgnoringModifiers?.lowercased(),
                      let first = chars.first,
                      first.unicodeScalars.allSatisfy({ CharacterSet.letters.contains($0) }) else {
                    return event
                }
                self.onKeyPress(String(first))
                return nil
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


struct ItemFramePreferenceKey: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]
    
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue()) { current, _ in current }
    }
}
