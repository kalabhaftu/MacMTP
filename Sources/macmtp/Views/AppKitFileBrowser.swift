import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct AppKitFileBrowser: NSViewRepresentable {
    let files: [FileNode]
    @Binding var selectedPaths: Set<String>
    let mode: FileViewMode
    let fontScale: Double
    let isLocal: Bool
    let onOpen: (FileNode) -> Void
    let onSelectionChanged: () -> Void
    let onContextMenu: (FileNode) -> NSMenu?

    func makeCoordinator() -> Coordinator {
        Coordinator(
            selectedPaths: $selectedPaths,
            onOpen: onOpen,
            onSelectionChanged: onSelectionChanged,
            onContextMenu: onContextMenu,
            isLocal: isLocal
        )
    }

    func makeNSView(context: Context) -> FileBrowserHostView {
        let view = FileBrowserHostView()
        view.update(
            files: files,
            mode: mode,
            fontScale: fontScale,
            coordinator: context.coordinator
        )
        return view
    }

    func updateNSView(_ nsView: FileBrowserHostView, context: Context) {
        context.coordinator.update(
            selectedPaths: $selectedPaths,
            onOpen: onOpen,
            onSelectionChanged: onSelectionChanged,
            onContextMenu: onContextMenu,
            isLocal: isLocal
        )
        nsView.update(
            files: files,
            mode: mode,
            fontScale: fontScale,
            coordinator: context.coordinator
        )
    }

    @MainActor
    final class Coordinator: NSObject, NSCollectionViewDataSource, NSCollectionViewDelegate, NSTableViewDataSource, NSTableViewDelegate {
        var files: [FileNode] = []
        var mode: FileViewMode = .icons
        var selectedPaths: Binding<Set<String>>
        var onOpen: (FileNode) -> Void
        var onSelectionChanged: () -> Void
        var onContextMenu: (FileNode) -> NSMenu?
        var isLocal: Bool
        var applyingSelection = false

        init(
            selectedPaths: Binding<Set<String>>,
            onOpen: @escaping (FileNode) -> Void,
            onSelectionChanged: @escaping () -> Void,
            onContextMenu: @escaping (FileNode) -> NSMenu?,
            isLocal: Bool
        ) {
            self.selectedPaths = selectedPaths
            self.onOpen = onOpen
            self.onSelectionChanged = onSelectionChanged
            self.onContextMenu = onContextMenu
            self.isLocal = isLocal
        }

        func update(
            selectedPaths: Binding<Set<String>>,
            onOpen: @escaping (FileNode) -> Void,
            onSelectionChanged: @escaping () -> Void,
            onContextMenu: @escaping (FileNode) -> NSMenu?,
            isLocal: Bool
        ) {
            self.selectedPaths = selectedPaths
            self.onOpen = onOpen
            self.onSelectionChanged = onSelectionChanged
            self.onContextMenu = onContextMenu
            self.isLocal = isLocal
        }

        func numberOfSections(in collectionView: NSCollectionView) -> Int { 1 }

        func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
            files.count
        }

        func collectionView(
            _ collectionView: NSCollectionView,
            itemForRepresentedObjectAt indexPath: IndexPath
        ) -> NSCollectionViewItem {
            let item = collectionView.makeItem(
                withIdentifier: AppKitFileCollectionItem.identifier,
                for: indexPath
            ) as? AppKitFileCollectionItem ?? AppKitFileCollectionItem()
            if files.indices.contains(indexPath.item) {
                let file = files[indexPath.item]
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

        func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) {
            guard !applyingSelection else { return }
            for indexPath in indexPaths {
                (collectionView.item(at: indexPath) as? AppKitFileCollectionItem)?.updateSelection(true)
            }
            updateSelection(indexPaths: indexPaths, selected: true)
        }

        func collectionView(_ collectionView: NSCollectionView, didDeselectItemsAt indexPaths: Set<IndexPath>) {
            guard !applyingSelection else { return }
            for indexPath in indexPaths {
                (collectionView.item(at: indexPath) as? AppKitFileCollectionItem)?.updateSelection(false)
            }
            updateSelection(indexPaths: indexPaths, selected: false)
        }

        private func updateSelection(indexPaths: Set<IndexPath>, selected: Bool) {
            var paths = selectedPaths.wrappedValue
            for indexPath in indexPaths where files.indices.contains(indexPath.item) {
                let path = files[indexPath.item].path
                if selected { paths.insert(path) } else { paths.remove(path) }
            }
            selectedPaths.wrappedValue = paths
            onSelectionChanged()
        }

        func openCollectionItem(at indexPath: IndexPath) {
            guard files.indices.contains(indexPath.item) else { return }
            onOpen(files[indexPath.item])
        }

        func collectionView(
            _ collectionView: NSCollectionView,
            pasteboardWriterForItemAt indexPath: IndexPath
        ) -> NSPasteboardWriting? {
            pasteboardWriter(at: indexPath.item)
        }

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

        private func pasteboardWriter(at index: Int) -> NSPasteboardWriting? {
            guard files.indices.contains(index) else { return nil }
            let file = files[index]
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
            let indexes = Set(files.indices.compactMap { paths.contains(files[$0].path) ? IndexPath(item: $0, section: 0) : nil })
            applyingSelection = true
            collectionView.deselectAll(nil)
            collectionView.selectItems(at: indexes, scrollPosition: [])
            for indexPath in indexes {
                (collectionView.item(at: indexPath) as? AppKitFileCollectionItem)?.updateSelection(true)
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

    override var isFlipped: Bool { true }

    func update(
        files: [FileNode],
        mode: FileViewMode,
        fontScale: Double,
        coordinator: AppKitFileBrowser.Coordinator
    ) {
        self.coordinator = coordinator
        coordinator.files = files
        coordinator.mode = mode
        if self.mode != mode {
            rebuild(mode: mode, fontScale: fontScale, coordinator: coordinator)
        }
        if mode == .list {
            tableView?.fontScale = fontScale
            tableView?.reloadData()
            coordinator.applySelection(to: tableView!)
        } else {
            collectionView?.reloadData()
            coordinator.applySelection(to: collectionView!)
        }
    }

    private func rebuild(mode: FileViewMode, fontScale: Double, coordinator: AppKitFileBrowser.Coordinator) {
        subviews.forEach { $0.removeFromSuperview() }
        collectionView = nil
        tableView = nil
        scrollView = nil
        self.mode = mode

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
            collection.collectionViewLayout = layout
            collection.isSelectable = true
            collection.allowsMultipleSelection = true
            collection.backgroundColors = [NSColor.controlBackgroundColor]
            collection.register(
                AppKitFileCollectionItem.self,
                forItemWithIdentifier: AppKitFileCollectionItem.identifier
            )
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
        let point = convert(event.locationInWindow, from: nil)
        if indexPathForItem(at: point) == nil {
            deselectAll(nil)
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

    override func mouseDown(with event: NSEvent) {
        let row = row(at: convert(event.locationInWindow, from: nil))
        if row < 0 {
            deselectAll(nil)
            coordinator?.selectedPaths.wrappedValue.removeAll()
            coordinator?.onSelectionChanged()
        }
        super.mouseDown(with: event)
    }

    @objc func doubleClick(_ sender: Any?) {
        coordinator?.openTableRow(clickedRow)
    }
}

final class AppKitFileCollectionItem: NSCollectionViewItem {
    static let identifier = NSUserInterfaceItemIdentifier("MacMTPFileItem")
    private let cellView = AppKitFileCellView()

    override func loadView() {
        view = cellView
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

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.borderWidth = 0

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
    }

    func updateSelection(_ selected: Bool) {
        layer?.backgroundColor = selected ? NSColor.controlAccentColor.withAlphaComponent(0.16).cgColor : NSColor.clear.cgColor
        layer?.borderWidth = selected ? 1 : 0
        layer?.borderColor = selected ? NSColor.controlAccentColor.withAlphaComponent(0.7).cgColor : nil
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
        NSLayoutConstraint.activate([
            iconView.widthAnchor.constraint(equalToConstant: 18),
            iconView.heightAnchor.constraint(equalToConstant: 18),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            detailLabel.widthAnchor.constraint(equalToConstant: 150)
        ])
        addSubview(stack)
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
