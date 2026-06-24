import Foundation
import Combine

// MARK: - ClipboardOperation

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

// MARK: - ClipboardManager

/// operations across local and MTP file system panels.
/// `ClipboardManager` is a `@MainActor` singleton `ObservableObject` so that
/// the Paste menu item).
/// ## Usage
/// // Copy selected files
/// // Check if paste is available
///     let description = ClipboardManager.shared.pasteDescription
/// }
/// // After paste completes
/// ```
@MainActor
public final class ClipboardManager: ObservableObject {

    // MARK: - Singleton

    public static let shared = ClipboardManager()

    // MARK: - Published Properties

    @Published public private(set) var hasContent: Bool = false

    // MARK: - Stored Properties

    public private(set) var items: [FileNode] = []

    public private(set) var operation: ClipboardOperation = .copy

    /// `true` for local, `false` for MTP.
    public private(set) var sourceIsLocal: Bool = true

    public private(set) var sourcePath: String = ""

    // MARK: - Initializer

    private init() {}

    // MARK: - Public Methods

    /// The previous clipboard contents are replaced. The `hasContent` property
    /// - Parameters:
    ///   - sourcePath: The directory path the items reside in.
    public func copyItems(items: [FileNode], from sourcePath: String, isLocal: Bool) {
        setClipboard(items: items, operation: .copy, sourcePath: sourcePath, isLocal: isLocal)
    }

    /// A cut operation indicates that the source files should be deleted after
    /// is responsible for performing the deletion.
    /// - Parameters:
    ///   - sourcePath: The directory path the items reside in.
    public func cutItems(items: [FileNode], from sourcePath: String, isLocal: Bool) {
        setClipboard(items: items, operation: .cut, sourcePath: sourcePath, isLocal: isLocal)
    }

    /// Call this after a paste operation completes, or when the clipboard
    public func clear() {
        items = []
        operation = .copy
        sourceIsLocal = true
        sourcePath = ""
        hasContent = false
    }

    /// for menu items and confirmation dialogs.
    /// Examples:
    /// - "Paste 1 item (move from device)"
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

    /// requesting a paste. This can be used to handle same-panel moves
    /// - Parameter isLocalDestination: Whether the paste destination is local.
    public func isSameSidePaste(isLocalDestination: Bool) -> Bool {
        sourceIsLocal == isLocalDestination
    }

    /// files should be deleted after successful paste.
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

    /// Example: "2 files, 1 folder (45.2 MB) — cut from /storage/Documents"
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

    // MARK: - Private Helpers

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
    }
}
