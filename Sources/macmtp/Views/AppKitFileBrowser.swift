import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct AppKitFileBrowser: NSViewRepresentable {
    let files: [FileNode]
    let groups: [FileGroup]
    @Binding var selectedPaths: Set<String>
    let mode: FileViewMode
    let fontScale: Double
    let isLocal: Bool
    let onOpen: (FileNode) -> Void
    let onActivate: () -> Void
    let onSelectionChanged: () -> Void
    let onContextMenu: (FileNode) -> NSMenu?
    var onFilesDropped: (([DroppedFile], String?) -> Void)? = nil

    func makeCoordinator() -> Coordinator {
        Coordinator(
            selectedPaths: $selectedPaths,
            groups: groups,
            onOpen: onOpen,
            onActivate: onActivate,
            onSelectionChanged: onSelectionChanged,
            onContextMenu: onContextMenu,
            onFilesDropped: onFilesDropped,
            isLocal: isLocal
        )
    }

    func makeNSView(context: Context) -> FileBrowserHostView {
        let view = FileBrowserHostView()
        view.update(
            files: files,
            groups: groups,
            mode: mode,
            fontScale: fontScale,
            coordinator: context.coordinator
        )
        return view
    }

    func updateNSView(_ nsView: FileBrowserHostView, context: Context) {
        context.coordinator.update(
            selectedPaths: $selectedPaths,
            groups: groups,
            onOpen: onOpen,
            onActivate: onActivate,
            onSelectionChanged: onSelectionChanged,
            onContextMenu: onContextMenu,
            onFilesDropped: onFilesDropped,
            isLocal: isLocal
        )
        nsView.update(
            files: files,
            groups: groups,
            mode: mode,
            fontScale: fontScale,
            coordinator: context.coordinator
        )
    }

    @MainActor
    final class Coordinator: NSObject, NSCollectionViewDataSource, NSCollectionViewDelegate, NSTableViewDataSource, NSTableViewDelegate {
        var files: [FileNode] = []
        var groups: [FileGroup] = []
        var mode: FileViewMode = .icons
        var selectedPaths: Binding<Set<String>>
        var onOpen: (FileNode) -> Void
        var onActivate: () -> Void
        var onSelectionChanged: () -> Void
        var onContextMenu: (FileNode) -> NSMenu?
        var onFilesDropped: (([DroppedFile], String?) -> Void)?
        var isLocal: Bool
        var applyingSelection = false
        var nativeSelectionPending = false

        init(
            selectedPaths: Binding<Set<String>>,
            groups: [FileGroup],
            onOpen: @escaping (FileNode) -> Void,
            onActivate: @escaping () -> Void,
            onSelectionChanged: @escaping () -> Void,
            onContextMenu: @escaping (FileNode) -> NSMenu?,
            onFilesDropped: (([DroppedFile], String?) -> Void)? = nil,
            isLocal: Bool
        ) {
            self.selectedPaths = selectedPaths
            self.groups = groups
            self.onOpen = onOpen
            self.onActivate = onActivate
            self.onSelectionChanged = onSelectionChanged
            self.onContextMenu = onContextMenu
            self.onFilesDropped = onFilesDropped
            self.isLocal = isLocal
        }

        func update(
            selectedPaths: Binding<Set<String>>,
            groups: [FileGroup],
            onOpen: @escaping (FileNode) -> Void,
            onActivate: @escaping () -> Void,
            onSelectionChanged: @escaping () -> Void,
            onContextMenu: @escaping (FileNode) -> NSMenu?,
            onFilesDropped: (([DroppedFile], String?) -> Void)? = nil,
            isLocal: Bool
        ) {
            self.selectedPaths = selectedPaths
            self.groups = groups
            self.onOpen = onOpen
            self.onActivate = onActivate
            self.onSelectionChanged = onSelectionChanged
            self.onContextMenu = onContextMenu
            self.onFilesDropped = onFilesDropped
            self.isLocal = isLocal
        }

        private var collectionGroups: [FileGroup] {
            groups.isEmpty ? [FileGroup(title: "", files: files)] : groups
        }

        private func file(at indexPath: IndexPath) -> FileNode? {
            guard collectionGroups.indices.contains(indexPath.section) else { return nil }
            let section = collectionGroups[indexPath.section]
            guard section.files.indices.contains(indexPath.item) else { return nil }
            return section.files[indexPath.item]
        }

        func numberOfSections(in collectionView: NSCollectionView) -> Int {
            collectionGroups.count
        }

        func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
            collectionGroups.indices.contains(section) ? collectionGroups[section].files.count : 0
        }

        func collectionView(
            _ collectionView: NSCollectionView,
            itemForRepresentedObjectAt indexPath: IndexPath
        ) -> NSCollectionViewItem {
            let item = collectionView.makeItem(
                withIdentifier: AppKitFileCollectionItem.identifier,
                for: indexPath
            ) as? AppKitFileCollectionItem ?? AppKitFileCollectionItem()
            if let file = file(at: indexPath) {
                item.configure(
                    file: file,
                    large: mode == .largeIcons,
                    menuProvider: { [weak self] in
                        self?.makeContextMenu(for: file)
                    }
                )
                item.updateSelection(selectedPaths.wrappedValue.contains(file.path))
            }
            return item
        }

        func collectionView(
            _ collectionView: NSCollectionView,
            viewForSupplementaryElementOfKind kind: NSCollectionView.SupplementaryElementKind,
            at indexPath: IndexPath
        ) -> NSView {
            guard kind == NSCollectionView.elementKindSectionHeader,
                  collectionGroups.indices.contains(indexPath.section) else {
                return NSView()
            }
            let header = collectionView.makeSupplementaryView(
                ofKind: kind,
                withIdentifier: AppKitFileGroupHeaderView.identifier,
                for: indexPath
            ) as? AppKitFileGroupHeaderView ?? AppKitFileGroupHeaderView()
            let group = collectionGroups[indexPath.section]
            header.configure(title: group.title, count: group.files.count)
            return header
        }

        func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) {
            guard !applyingSelection else { return }
            syncSelectionFromCollectionView(collectionView)
        }

        func collectionView(_ collectionView: NSCollectionView, didDeselectItemsAt indexPaths: Set<IndexPath>) {
            guard !applyingSelection else { return }
            syncSelectionFromCollectionView(collectionView)
        }

        private func syncSelectionFromCollectionView(_ collectionView: NSCollectionView) {
            let paths = Set(collectionView.selectionIndexPaths.compactMap { file(at: $0)?.path })
            nativeSelectionPending = true
            selectedPaths.wrappedValue = paths
            onSelectionChanged()
        }

        func openCollectionItem(at indexPath: IndexPath) {
            guard let file = file(at: indexPath) else { return }
            onOpen(file)
        }

        func collectionView(
            _ collectionView: NSCollectionView,
            pasteboardWriterForItemAt indexPath: IndexPath
        ) -> NSPasteboardWriting? {
            guard let file = file(at: indexPath) else { return nil }
            return pasteboardWriter(for: file)
        }

        func collectionView(
            _ collectionView: NSCollectionView,
            draggingSession session: NSDraggingSession,
            willBeginAt screenPoint: NSPoint,
            forItemsAt indexPaths: Set<IndexPath>
        ) {
            draggedCollectionIndexPaths = indexPaths
        }

        func collectionView(
            _ collectionView: NSCollectionView,
            draggingSession session: NSDraggingSession,
            endedAt screenPoint: NSPoint,
            dragOperation operation: NSDragOperation
        ) {
            draggedCollectionIndexPaths = []
        }

        func collectionView(
            _ collectionView: NSCollectionView,
            validateDrop draggingInfo: NSDraggingInfo,
            proposedIndexPath proposedDropIndexPath: AutoreleasingUnsafeMutablePointer<NSIndexPath>,
            dropOperation proposedDropOperation: UnsafeMutablePointer<NSCollectionView.DropOperation>
        ) -> NSDragOperation {
            let targetIndexPath = proposedDropIndexPath.pointee as IndexPath
            if let file = file(at: targetIndexPath), file.isDirectory {
                proposedDropOperation.pointee = .on
                return .copy
            }
            proposedDropOperation.pointee = .before
            return .copy
        }

        func collectionView(
            _ collectionView: NSCollectionView,
            acceptDrop draggingInfo: NSDraggingInfo,
            indexPath: IndexPath,
            dropOperation: NSCollectionView.DropOperation
        ) -> Bool {
            onActivate()
            let droppedFiles = DroppedFile.extract(from: draggingInfo.draggingPasteboard)
            guard !droppedFiles.isEmpty else { return false }
            let targetDir: String?
            if dropOperation == .on, let file = file(at: indexPath), file.isDirectory {
                targetDir = file.path
            } else {
                targetDir = nil
            }
            onFilesDropped?(droppedFiles, targetDir)
            return true
        }

        private var draggedCollectionIndexPaths: Set<IndexPath> = []

        func numberOfRows(in tableView: NSTableView) -> Int { files.count }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard files.indices.contains(row) else { return nil }
            let identifier = NSUserInterfaceItemIdentifier("MacMTPTableCell")
            let cell = tableView.makeView(withIdentifier: identifier, owner: nil) as? AppKitFileTableCellView
                ?? AppKitFileTableCellView()
            cell.identifier = identifier
            let file = files[row]
            cell.configure(
                file: file,
                fontScale: (tableView as? ClearingTableView)?.fontScale ?? 1,
                menuProvider: { [weak self] in self?.makeContextMenu(for: file) }
            )
            return cell
        }

        private func makeContextMenu(for file: FileNode) -> NSMenu? {
            return onContextMenu(file)
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !applyingSelection,
                  let tableView = notification.object as? NSTableView else { return }
            let paths = Set(tableView.selectedRowIndexes.compactMap { files.indices.contains($0) ? files[$0].path : nil })
            nativeSelectionPending = true
            selectedPaths.wrappedValue = paths
            onSelectionChanged()
        }

        func openTableRow(_ row: Int) {
            guard files.indices.contains(row) else { return }
            onOpen(files[row])
        }

        func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
            pasteboardWriter(at: row)
        }

        func tableView(
            _ tableView: NSTableView,
            validateDrop info: NSDraggingInfo,
            proposedRow row: Int,
            proposedDropOperation dropOperation: NSTableView.DropOperation
        ) -> NSDragOperation {
            if row >= 0 && row < files.count && files[row].isDirectory {
                tableView.setDropRow(row, dropOperation: .on)
                return .copy
            }
            tableView.setDropRow(-1, dropOperation: .on)
            return .copy
        }

        func tableView(
            _ tableView: NSTableView,
            acceptDrop info: NSDraggingInfo,
            row: Int,
            dropOperation: NSTableView.DropOperation
        ) -> Bool {
            onActivate()
            let droppedFiles = DroppedFile.extract(from: info.draggingPasteboard)
            guard !droppedFiles.isEmpty else { return false }
            let targetDir: String?
            if row >= 0 && row < self.files.count && dropOperation == .on && self.files[row].isDirectory {
                targetDir = self.files[row].path
            } else {
                targetDir = nil
            }
            onFilesDropped?(droppedFiles, targetDir)
            return true
        }

        private func pasteboardWriter(at index: Int) -> NSPasteboardWriting? {
            guard files.indices.contains(index) else { return nil }
            return pasteboardWriter(for: files[index])
        }

        private func pasteboardWriter(for file: FileNode) -> NSPasteboardWriting? {
            let nodes: [FileNode]
            if selectedPaths.wrappedValue.contains(file.path) {
                nodes = files.filter { selectedPaths.wrappedValue.contains($0.path) }
            } else {
                selectedPaths.wrappedValue = [file.path]
                onSelectionChanged()
                nodes = [file]
            }
            return AppKitFilePasteboardWriter(files: nodes, isLocal: isLocal)
        }

        func applySelection(to collectionView: NSCollectionView) {
            let paths = selectedPaths.wrappedValue
            let indexes = Set(collectionGroups.indices.flatMap { section in
                collectionGroups[section].files.indices.compactMap { item in
                    paths.contains(collectionGroups[section].files[item].path)
                        ? IndexPath(item: item, section: section)
                        : nil
                }
            })
            applyingSelection = true
            collectionView.selectionIndexPaths = indexes
            for indexPath in collectionView.indexPathsForVisibleItems() {
                let isSel = indexes.contains(indexPath)
                (collectionView.item(at: indexPath) as? AppKitFileCollectionItem)?.updateSelection(isSel)
            }
            applyingSelection = false
        }

        func applySelection(to tableView: NSTableView) {
            let indexes = IndexSet(files.indices.compactMap { selectedPaths.wrappedValue.contains(files[$0].path) ? $0 : nil })
            applyingSelection = true
            tableView.selectRowIndexes(indexes, byExtendingSelection: false)
            applyingSelection = false
        }
    }
}

final class FileBrowserHostView: NSView {
    private var mode: FileViewMode?
    private var collectionView: ClearingCollectionView?
    private var tableView: ClearingTableView?
    private var scrollView: NSScrollView?
    private weak var coordinator: AppKitFileBrowser.Coordinator?
    private var isGrouped = false
    private var lastFiles: [FileNode] = []
    private var lastGroups: [FileGroup] = []
    private var lastSelection: Set<String> = []
    private var lastFontScale: Double?

    func update(
        files: [FileNode],
        groups: [FileGroup],
        mode: FileViewMode,
        fontScale: Double,
        coordinator: AppKitFileBrowser.Coordinator
    ) {
        self.coordinator = coordinator
        coordinator.files = files
        coordinator.groups = groups
        coordinator.mode = mode
        let shouldGroup = !groups.isEmpty
        let modeChanged = self.mode != mode
        let groupingChanged = self.isGrouped != shouldGroup
        let contentChanged = Self.filesChanged(from: lastFiles, to: files) || lastGroups != groups
        let fontScaleChanged = lastFontScale != fontScale
        let selection = coordinator.selectedPaths.wrappedValue
        let selectionChanged = lastSelection != selection

        if modeChanged || groupingChanged {
            rebuild(mode: mode, isGrouped: shouldGroup, fontScale: fontScale, coordinator: coordinator)
        }

        if modeChanged || groupingChanged || contentChanged || fontScaleChanged {
            if mode == .list {
                tableView?.fontScale = fontScale
                tableView?.reloadData()
                if let tableView { coordinator.applySelection(to: tableView) }
            } else {
                collectionView?.reloadData()
                if let collectionView { coordinator.applySelection(to: collectionView) }
            }
        } else if selectionChanged {
            if coordinator.nativeSelectionPending {
                coordinator.nativeSelectionPending = false
            } else {
                if mode == .list {
                    if let tableView { coordinator.applySelection(to: tableView) }
                } else if let collectionView {
                    coordinator.applySelection(to: collectionView)
                }
            }
        }

        lastFiles = files
        lastGroups = groups
        lastSelection = selection
        lastFontScale = fontScale
    }

    static func filesChanged(from previous: [FileNode], to current: [FileNode]) -> Bool {
        guard previous.count == current.count else { return true }
        return zip(previous, current).contains { old, new in
            old.path != new.path
                || old.name != new.name
                || old.isDirectory != new.isDirectory
                || old.size != new.size
                || old.modificationDate != new.modificationDate
                || old.objectId != new.objectId
        }
    }

    private func rebuild(mode: FileViewMode, isGrouped: Bool, fontScale: Double, coordinator: AppKitFileBrowser.Coordinator) {
        subviews.forEach { $0.removeFromSuperview() }
        collectionView = nil
        tableView = nil
        scrollView = nil
        self.mode = mode
        self.isGrouped = isGrouped

        let scroll = NSScrollView(frame: bounds)
        scroll.autoresizingMask = [.width, .height]
        scroll.drawsBackground = true
        scroll.backgroundColor = NSColor.controlBackgroundColor
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        addSubview(scroll)
        scrollView = scroll

        if mode == .list {
            let table = ClearingTableView(frame: .zero)
            table.fontScale = fontScale
            table.headerView = nil
            table.usesAlternatingRowBackgroundColors = false
            table.selectionHighlightStyle = .regular
            table.allowsMultipleSelection = true
            table.allowsEmptySelection = true
            table.rowHeight = 26
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("File"))
            column.resizingMask = .autoresizingMask
            table.addTableColumn(column)
            table.registerForDraggedTypes([
                .fileURL,
                .string,
                NSPasteboard.PasteboardType(UTType.utf8PlainText.identifier),
                NSPasteboard.PasteboardType("NSFilenamesPboardType")
            ])
            table.setDraggingSourceOperationMask(.copy, forLocal: false)
            table.setDraggingSourceOperationMask(.copy, forLocal: true)
            table.delegate = coordinator
            table.dataSource = coordinator
            table.coordinator = coordinator
            table.target = table
            table.doubleAction = #selector(ClearingTableView.doubleClick(_:))
            scroll.documentView = table
            tableView = table
        } else {
            let collection = ClearingCollectionView(frame: .zero)
            let layout = NSCollectionViewFlowLayout()
            layout.itemSize = NSSize(
                width: FileGridLayout.cellWidth(large: mode == .largeIcons),
                height: FileGridLayout.cellHeight(large: mode == .largeIcons)
            )
            layout.minimumInteritemSpacing = FileGridLayout.spacing
            layout.minimumLineSpacing = FileGridLayout.spacing
            layout.sectionInset = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
            layout.headerReferenceSize = isGrouped ? NSSize(width: 0, height: 30) : .zero
            collection.collectionViewLayout = layout
            collection.isSelectable = true
            collection.allowsMultipleSelection = true
            collection.backgroundColors = [NSColor.controlBackgroundColor]
            collection.register(
                AppKitFileCollectionItem.self,
                forItemWithIdentifier: AppKitFileCollectionItem.identifier
            )
            if isGrouped {
                collection.register(
                    AppKitFileGroupHeaderView.self,
                    forSupplementaryViewOfKind: NSCollectionView.elementKindSectionHeader,
                    withIdentifier: AppKitFileGroupHeaderView.identifier
                )
            }
            collection.registerForDraggedTypes([
                .fileURL,
                .string,
                NSPasteboard.PasteboardType(UTType.utf8PlainText.identifier),
                NSPasteboard.PasteboardType("NSFilenamesPboardType")
            ])
            collection.setDraggingSourceOperationMask(.copy, forLocal: false)
            collection.setDraggingSourceOperationMask(.copy, forLocal: true)
            collection.dataSource = coordinator
            collection.delegate = coordinator
            collection.coordinator = coordinator
            scroll.documentView = collection
            collectionView = collection
        }
    }
}

final class ClearingCollectionView: NSCollectionView {
    weak var coordinator: AppKitFileBrowser.Coordinator?

    override func mouseDown(with event: NSEvent) {
        coordinator?.onActivate()
        let point = convert(event.locationInWindow, from: nil)
        if indexPathForItem(at: point) == nil {
            deselectAll(nil)
            coordinator?.nativeSelectionPending = true
            coordinator?.selectedPaths.wrappedValue.removeAll()
            coordinator?.onSelectionChanged()
        }
        super.mouseDown(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        super.mouseUp(with: event)
        guard event.clickCount == 2 else { return }
        let point = convert(event.locationInWindow, from: nil)
        if let indexPath = indexPathForItem(at: point) {
            coordinator?.openCollectionItem(at: indexPath)
        }
    }
}

final class ClearingTableView: NSTableView {
    weak var coordinator: AppKitFileBrowser.Coordinator?
    var fontScale: Double = 1
    private var draggedRows = IndexSet()

    override func mouseDown(with event: NSEvent) {
        coordinator?.onActivate()
        let row = row(at: convert(event.locationInWindow, from: nil))
        if row < 0 {
            deselectAll(nil)
            coordinator?.nativeSelectionPending = true
            coordinator?.selectedPaths.wrappedValue.removeAll()
            coordinator?.onSelectionChanged()
        }
        super.mouseDown(with: event)
    }

    override func draggingSession(
        _ session: NSDraggingSession,
        willBeginAt screenPoint: NSPoint
    ) {
        super.draggingSession(session, willBeginAt: screenPoint)
        draggedRows = selectedRowIndexes
    }

    override func draggingSession(
        _ session: NSDraggingSession,
        endedAt screenPoint: NSPoint,
        operation: NSDragOperation
    ) {
        super.draggingSession(session, endedAt: screenPoint, operation: operation)
        draggedRows = IndexSet()
    }

    @objc func doubleClick(_ sender: Any?) {
        coordinator?.openTableRow(clickedRow)
    }
}

final class AppKitFileGroupHeaderView: NSView {
    static let identifier = NSUserInterfaceItemIdentifier("MacMTPFileGroupHeader")

    private let leadingRule = NSBox()
    private let titleLabel = NSTextField(labelWithString: "")
    private let countLabel = NSTextField(labelWithString: "")
    private let trailingRule = NSBox()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        leadingRule.boxType = .separator
        trailingRule.boxType = .separator
        titleLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        titleLabel.textColor = .secondaryLabelColor
        countLabel.font = .systemFont(ofSize: 10)
        countLabel.textColor = .tertiaryLabelColor

        let stack = NSStackView(views: [leadingRule, titleLabel, countLabel, trailingRule])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        leadingRule.setContentHuggingPriority(.defaultLow, for: .horizontal)
        trailingRule.setContentHuggingPriority(.defaultLow, for: .horizontal)
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 7),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -7),
            leadingRule.heightAnchor.constraint(equalToConstant: 1),
            trailingRule.heightAnchor.constraint(equalToConstant: 1)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(title: String, count: Int) {
        titleLabel.stringValue = title
        countLabel.stringValue = String(count) + (count == 1 ? " item" : " items")
    }
}

final class AppKitFileCollectionItem: NSCollectionViewItem {
    static let identifier = NSUserInterfaceItemIdentifier("MacMTPFileItem")
    private let cellView = AppKitFileCellView()

    override func loadView() {
        view = cellView
    }

    override var isSelected: Bool {
        didSet {
            super.isSelected = isSelected
            cellView.updateSelection(isSelected)
        }
    }

    override var highlightState: NSCollectionViewItem.HighlightState {
        didSet {
            cellView.updateDropHighlight(highlightState == .asDropTarget)
        }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        cellView.prepareForReuse()
    }

    func configure(
        file: FileNode,
        large: Bool,
        menuProvider: (() -> NSMenu?)? = nil
    ) {
        cellView.configure(file: file, large: large, menuProvider: menuProvider)
    }

    func updateSelection(_ selected: Bool) {
        cellView.updateSelection(selected)
    }
}

final class AppKitFileCellView: NSView {
    private let iconView = NSImageView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let sizeLabel = NSTextField(labelWithString: "")
    var menuProvider: (() -> NSMenu?)?
    private var isSelectedState = false
    private var isDropTargetState = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.borderWidth = 0
        layer?.actions = [
            "backgroundColor": NSNull(),
            "borderColor": NSNull(),
            "borderWidth": NSNull()
        ]

        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.imageAlignment = .alignCenter
        nameLabel.alignment = .center
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.maximumNumberOfLines = 2
        nameLabel.font = .systemFont(ofSize: 11)
        sizeLabel.alignment = .center
        sizeLabel.font = .monospacedDigitSystemFont(ofSize: 9, weight: .regular)
        sizeLabel.textColor = .secondaryLabelColor

        let stack = NSStackView(views: [iconView, nameLabel, sizeLabel])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 3
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -4),
            iconView.widthAnchor.constraint(equalToConstant: 42),
            iconView.heightAnchor.constraint(equalTo: iconView.widthAnchor),
            nameLabel.heightAnchor.constraint(equalToConstant: 30),
            sizeLabel.heightAnchor.constraint(equalToConstant: 10)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func menu(for event: NSEvent) -> NSMenu? {
        menuProvider?()
    }

    func prepareForReuse() {
        isSelectedState = false
        isDropTargetState = false
        menuProvider = nil
        applyStyles()
    }

    func configure(
        file: FileNode,
        large: Bool = false,
        fontScale: Double = 1,
        menuProvider: (() -> NSMenu?)? = nil
    ) {
        self.menuProvider = menuProvider
        iconView.image = NSImage(systemSymbolName: file.iconName, accessibilityDescription: file.name)
        iconView.contentTintColor = file.isDirectory ? .systemBlue : .secondaryLabelColor
        nameLabel.stringValue = file.name
        nameLabel.font = .systemFont(ofSize: (large ? 12 : 11) * fontScale)
        sizeLabel.stringValue = large && !file.isDirectory ? file.formattedSize : ""
        sizeLabel.isHidden = !large
        applyStyles()
    }

    func updateSelection(_ selected: Bool) {
        isSelectedState = selected
        applyStyles()
    }

    func updateDropHighlight(_ isDropTarget: Bool) {
        isDropTargetState = isDropTarget
        applyStyles()
    }

    private func applyStyles() {
        if isDropTargetState {
            layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.28).cgColor
            layer?.borderWidth = 2
            layer?.borderColor = NSColor.controlAccentColor.cgColor
        } else if isSelectedState {
            layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.16).cgColor
            layer?.borderWidth = 1
            layer?.borderColor = NSColor.controlAccentColor.withAlphaComponent(0.7).cgColor
        } else {
            layer?.backgroundColor = NSColor.clear.cgColor
            layer?.borderWidth = 0
            layer?.borderColor = nil
        }
    }
}

final class AppKitFileTableCellView: NSView {
    private let iconView = NSImageView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    var menuProvider: (() -> NSMenu?)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        let stack = NSStackView(views: [iconView, nameLabel, detailLabel])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        iconView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            iconView.widthAnchor.constraint(equalToConstant: 18),
            iconView.heightAnchor.constraint(equalToConstant: 18),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            detailLabel.widthAnchor.constraint(equalToConstant: 150)
        ])
        nameLabel.lineBreakMode = .byTruncatingMiddle
        detailLabel.textColor = .secondaryLabelColor
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func menu(for event: NSEvent) -> NSMenu? {
        menuProvider?()
    }

    func configure(
        file: FileNode,
        fontScale: Double,
        menuProvider: (() -> NSMenu?)? = nil
    ) {
        self.menuProvider = menuProvider
        iconView.image = NSImage(systemSymbolName: file.iconName, accessibilityDescription: file.name)
        iconView.contentTintColor = file.isDirectory ? .systemBlue : .secondaryLabelColor
        nameLabel.stringValue = file.name
        nameLabel.font = .systemFont(ofSize: 12 * fontScale)
        detailLabel.stringValue = file.isDirectory ? "Folder" : file.formattedSize
        detailLabel.font = .systemFont(ofSize: 11 * fontScale)
    }
}

final class AppKitMenuActionProxy: NSObject {
    private let actions: [() -> Void]

    init(actions: [() -> Void]) {
        self.actions = actions
    }

    @objc func invoke(_ sender: NSMenuItem) {
        guard actions.indices.contains(sender.tag) else { return }
        actions[sender.tag]()
    }
}

final class AppKitFilePasteboardWriter: NSObject, NSPasteboardWriting {
    private let files: [FileNode]
    private let isLocal: Bool

    init(files: [FileNode], isLocal: Bool) {
        self.files = files
        self.isLocal = isLocal
    }

    func writableTypes(for pasteboard: NSPasteboard) -> [NSPasteboard.PasteboardType] {
        var types: [NSPasteboard.PasteboardType] = [
            .string,
            NSPasteboard.PasteboardType(UTType.utf8PlainText.identifier)
        ]
        if isLocal {
            types.append(NSPasteboard.PasteboardType("NSFilenamesPboardType"))
        }
        return types
    }

    func pasteboardPropertyList(forType type: NSPasteboard.PasteboardType) -> Any? {
        if type == .string || type == NSPasteboard.PasteboardType(UTType.utf8PlainText.identifier) {
            return files.map {
                "\(isLocal ? "local" : "mtp"):\($0.isDirectory ? "dir" : "file"):\($0.path)"
            }.joined(separator: "\n")
        }
        if type == NSPasteboard.PasteboardType("NSFilenamesPboardType") {
            return files.map(\.path)
        }
        return nil
    }
}
