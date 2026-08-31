import Foundation
import Combine
import AppKit

public enum ClipboardOperation: String, Sendable {
    case copy = "Copy"
    case cut = "Cut"

    public var iconName: String {
        switch self {
        case .copy:
            return "doc.on.doc"
        case .cut:
            return "scissors"
        }
    }
}

@MainActor
public final class ClipboardManager: ObservableObject {
    public static let shared = ClipboardManager()

    @Published public private(set) var hasContent: Bool = false
    public private(set) var items: [FileNode] = []
    public private(set) var operation: ClipboardOperation = .copy
    public private(set) var sourceIsLocal: Bool = true
    public private(set) var sourcePath: String = ""

    private init() {}

    public func copyItems(items: [FileNode], from sourcePath: String, isLocal: Bool) {
        setClipboard(items: items, operation: .copy, sourcePath: sourcePath, isLocal: isLocal)
    }

    public func cutItems(items: [FileNode], from sourcePath: String, isLocal: Bool) {
        setClipboard(items: items, operation: .cut, sourcePath: sourcePath, isLocal: isLocal)
    }

    public func clear() {
        items = []
        operation = .copy
        sourceIsLocal = true
        sourcePath = ""
        hasContent = false
        NSPasteboard.general.clearContents()
    }

    public func removeItems(matchingPaths paths: Set<String>) {
        guard hasContent else { return }
        items.removeAll { paths.contains($0.path) }
        if items.isEmpty {
            clear()
        } else {
            setClipboard(items: items, operation: operation, sourcePath: sourcePath, isLocal: sourceIsLocal)
        }
    }

    public func updateItemPath(oldPath: String, newPath: String, newName: String) {
        guard hasContent else { return }
        var updated = false
        items = items.map { item in
            if item.path == oldPath {
                updated = true
                return FileNode(
                    name: newName,
                    path: newPath,
                    parentPath: item.parentPath,
                    isDirectory: item.isDirectory,
                    size: item.size,
                    modificationDate: Date(),
                    objectId: item.objectId
                )
            }
            return item
        }
        if updated {
            setClipboard(items: items, operation: operation, sourcePath: sourcePath, isLocal: sourceIsLocal)
        }
    }

    public var pasteDescription: String {
        guard hasContent else { return "Clipboard is empty" }

        let count = items.count
        let itemWord = count == 1 ? "item" : "items"
        let verb = operation == .cut ? "move" : "copy"
        let source = sourceIsLocal ? "local" : "device"

        return "Paste \(count) \(itemWord) (\(verb) from \(source))"
    }

    public var badgeLabel: String {
        guard hasContent else { return "" }
        let count = items.count
        let verb = operation == .cut ? "cut" : "copied"
        return "\(count) \(verb)"
    }

    public func isSameSidePaste(isLocalDestination: Bool) -> Bool {
        sourceIsLocal == isLocalDestination
    }

    public var isCutOperation: Bool {
        operation == .cut && hasContent
    }

    public var totalSize: Int64 {
        items.reduce(0) { $0 + $1.size }
    }

    public var formattedTotalSize: String {
        FormatUtils.formatBytes(totalSize)
    }

    public var directoryCount: Int {
        items.filter(\.isDirectory).count
    }

    public var fileCount: Int {
        items.filter { !$0.isDirectory }.count
    }

    public var detailedDescription: String {
        guard hasContent else { return "Clipboard is empty" }

        var parts: [String] = []

        let files = fileCount
        let dirs = directoryCount

        if files > 0 {
            parts.append("\(files) \(files == 1 ? "file" : "files")")
        }
        if dirs > 0 {
            parts.append("\(dirs) \(dirs == 1 ? "folder" : "folders")")
        }

        let sizeStr = formattedTotalSize
        let verb = operation == .cut ? "cut" : "copied"
        let source = sourceIsLocal ? "local" : "device"

        return "\(parts.joined(separator: ", ")) (\(sizeStr)) — \(verb) from \(source):\(sourcePath)"
    }

    private func setClipboard(
        items: [FileNode],
        operation: ClipboardOperation,
        sourcePath: String,
        isLocal: Bool
    ) {
        self.items = items
        self.operation = operation
        self.sourcePath = sourcePath
        self.sourceIsLocal = isLocal
        self.hasContent = !items.isEmpty

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        guard !items.isEmpty else { return }

        let textPayload = items.map {
            "\(isLocal ? "local" : "mtp"):\($0.isDirectory ? "dir" : "file"):\($0.path)"
        }.joined(separator: "\n")
        pasteboard.setString(textPayload, forType: .string)
        if isLocal {
            pasteboard.setPropertyList(items.map(\.path), forType: NSPasteboard.PasteboardType("NSFilenamesPboardType"))
        }
    }
}
