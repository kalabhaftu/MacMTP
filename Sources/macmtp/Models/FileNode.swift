import Foundation
import SwiftUI

/// `FileNode` is the primary data model used throughout macMTP to represent filesystem
/// (objectId/parentId-based), enabling unified display and transfer logic.
public struct FileNode: Identifiable, Hashable, Sendable {

    // MARK: - Core Properties

    public let name: String

    /// For local files this is the absolute POSIX path; for MTP files it is
    public let path: String

    public let parentPath: String

    public let isDirectory: Bool

    public let size: Int64

    public var calculatedSize: Int64?

    public let modificationDate: Date

    // MARK: - MTP-Specific Properties

    public let objectId: UInt32

    public let parentId: UInt32

    // MARK: - UI State

    public var isSelected: Bool

    // MARK: - Identifiable

    public var id: String { path }

    // MARK: - Initializer

    /// - Parameters:
    ///   - path: Full path within its file system.
    ///   - isDirectory: Whether this entry is a directory.
    ///   - modificationDate: Last-modification timestamp.
    ///   - parentId: MTP parent object handle (default 0).
    public init(
        name: String,
        path: String,
        parentPath: String = "",
        isDirectory: Bool = false,
        size: Int64 = 0,
        modificationDate: Date = Date(),
        objectId: UInt32 = 0,
        parentId: UInt32 = 0,
        isSelected: Bool = false,
        calculatedSize: Int64? = nil
    ) {
        self.name = name
        self.path = path
        self.parentPath = parentPath
        self.isDirectory = isDirectory
        self.size = size
        self.modificationDate = modificationDate
        self.objectId = objectId
        self.parentId = parentId
        self.isSelected = isSelected
        self.calculatedSize = calculatedSize
    }

    // MARK: - Computed Properties

    /// or files without an extension.
    public var extensionName: String {
        guard !isDirectory else { return "" }
        let ext = (name as NSString).pathExtension.lowercased()
        return ext
    }

    /// Returns "Folder" for directories and "File" for extensionless files.
    public var displayExtension: String {
        if isDirectory { return "Folder" }
        let ext = extensionName
        return ext.isEmpty ? "File" : ext.uppercased()
    }

    /// counting style (base-10: KB, MB, GB).
    public var formattedSize: String {
        if let calculatedSize = calculatedSize {
            return FormatUtils.formatBytes(calculatedSize)
        }
        guard !isDirectory else { return "—" }
        return FormatUtils.formatBytes(size)
    }

    public var formattedDate: String {
        FormatUtils.formatDate(modificationDate)
    }

    /// Directories use `folder.fill`. Files are mapped by extension to the most
    public var iconName: String {
        if isDirectory {
            return "folder.fill"
        }
        return FormatUtils.fileExtensionIcon(extensionName)
    }

    public var iconColor: Color {
        if isDirectory { return .accentColor }
        let ext = extensionName.lowercased()
        switch ext {
        case "jpg", "jpeg", "png", "gif", "heic", "heif", "bmp", "tiff", "webp", "svg": return .green
        case "mp4", "mov", "avi", "mkv", "m4v", "wmv", "flv": return .purple
        case "mp3", "aac", "flac", "wav", "m4a", "ogg": return .pink
        case "pdf": return .red
        case "zip", "gz", "tar", "rar", "7z", "dmg": return .yellow
        case "swift": return .orange
        case "py", "js", "ts", "c", "h", "cpp", "java", "go", "rs", "rb": return .teal
        default: return .secondary
        }
    }

    // MARK: - Hashable

    public func hash(into hasher: inout Hasher) {
        hasher.combine(path)
    }

    public static func == (lhs: FileNode, rhs: FileNode) -> Bool {
        lhs.path == rhs.path
    }
}

// MARK: - Comparable

extension FileNode: Comparable {
    /// alphabetically by name using a case-insensitive, locale-aware comparison.
    public static func < (lhs: FileNode, rhs: FileNode) -> Bool {
        if lhs.isDirectory != rhs.isDirectory {
            return lhs.isDirectory
        }
        return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
    }
}

// MARK: - Convenience Factory Methods

extension FileNode {
    /// - Parameter url: A file URL pointing to a local file or directory.
    public static func fromLocalURL(_ url: URL) -> FileNode? {
        let fileManager = FileManager.default
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path) else {
            return nil
        }

        let isDir = (attributes[.type] as? FileAttributeType) == .typeDirectory
        let fileSize = (attributes[.size] as? Int64) ?? 0
        let modDate = (attributes[.modificationDate] as? Date) ?? Date()

        return FileNode(
            name: url.lastPathComponent,
            path: url.path,
            parentPath: url.deletingLastPathComponent().path,
            isDirectory: isDir,
            size: fileSize,
            modificationDate: modDate
        )
    }

    /// - Parameter parentPath: The path of the parent directory to navigate to.
    public static func parentNavigationNode(for parentPath: String) -> FileNode {
        FileNode(
            name: "..",
            path: parentPath,
            parentPath: (parentPath as NSString).deletingLastPathComponent,
            isDirectory: true
        )
    }
}

// MARK: - Directory Size Calculation

extension FileNode {

    public static func calculateDirectorySize(path: String, isLocal: Bool, storageId: UInt32?) async -> Int64? {
        if isLocal {
            return await Task.detached {
                let fileManager = FileManager.default
                guard let enumerator = fileManager.enumerator(
                    at: URL(fileURLWithPath: path),
                    includingPropertiesForKeys: [.fileSizeKey, .isDirectoryKey]
                ) else { return nil }
                var total: Int64 = 0
                while let fileURL = enumerator.nextObject() as? URL {
                    guard let values = try? fileURL.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey]),
                          let isDir = values.isDirectory,
                          !isDir,
                          let fileSize = values.fileSize else { continue }
                    total += Int64(fileSize)
                }
                return total
            }.value
        } else {
            guard let storageId = storageId else { return nil }
            do {
                let files = try await KalamBridge.shared.listDirectory(storageId: storageId, path: path, recursive: true)
                return files.reduce(0) { $0 + $1.size }
            } catch {
                print("Failed to calculate MTP directory size for \(path): \(error)")
                return nil
            }
        }
    }
}

// MARK: - Mock Data

extension FileNode {
    public static let mockData: [FileNode] = {
        let calendar = Calendar.current
        let now = Date()

        func date(daysAgo days: Int) -> Date {
            calendar.date(byAdding: .day, value: -days, to: now) ?? now
        }

        return [
            FileNode(
                name: "Documents",
                path: "/storage/Documents",
                parentPath: "/storage",
                isDirectory: true,
                size: 0,
                modificationDate: date(daysAgo: 1),
                objectId: 100,
                parentId: 1
            ),
            FileNode(
                name: "Photos",
                path: "/storage/Photos",
                parentPath: "/storage",
                isDirectory: true,
                size: 0,
                modificationDate: date(daysAgo: 3),
                objectId: 101,
                parentId: 1
            ),
            FileNode(
                name: "vacation_2025.mp4",
                path: "/storage/Videos/vacation_2025.mp4",
                parentPath: "/storage/Videos",
                isDirectory: false,
                size: 1_547_832_012,
                modificationDate: date(daysAgo: 5),
                objectId: 200,
                parentId: 102
            ),
            FileNode(
                name: "playlist.mp3",
                path: "/storage/Music/playlist.mp3",
                parentPath: "/storage/Music",
                isDirectory: false,
                size: 8_734_291,
                modificationDate: date(daysAgo: 12),
                objectId: 201,
                parentId: 103
            ),
            FileNode(
                name: "sunset.heic",
                path: "/storage/Photos/sunset.heic",
                parentPath: "/storage/Photos",
                isDirectory: false,
                size: 4_218_901,
                modificationDate: date(daysAgo: 2),
                objectId: 202,
                parentId: 101
            ),
            FileNode(
                name: "report_final.pdf",
                path: "/storage/Documents/report_final.pdf",
                parentPath: "/storage/Documents",
                isDirectory: false,
                size: 2_340_678,
                modificationDate: date(daysAgo: 7),
                objectId: 203,
                parentId: 100
            ),
            FileNode(
                name: "project_backup.zip",
                path: "/storage/Documents/project_backup.zip",
                parentPath: "/storage/Documents",
                isDirectory: false,
                size: 157_286_400,
                modificationDate: date(daysAgo: 14),
                objectId: 204,
                parentId: 100
            ),
            FileNode(
                name: "notes.txt",
                path: "/storage/Documents/notes.txt",
                parentPath: "/storage/Documents",
                isDirectory: false,
                size: 4_096,
                modificationDate: date(daysAgo: 0),
                objectId: 205,
                parentId: 100
            ),
            FileNode(
                name: "presentation.key",
                path: "/storage/Documents/presentation.key",
                parentPath: "/storage/Documents",
                isDirectory: false,
                size: 34_567_890,
                modificationDate: date(daysAgo: 4),
                objectId: 206,
                parentId: 100
            ),
            FileNode(
                name: "database_dump.tar.gz",
                path: "/storage/Documents/database_dump.tar.gz",
                parentPath: "/storage/Documents",
                isDirectory: false,
                size: 524_288_000,
                modificationDate: date(daysAgo: 30),
                objectId: 207,
                parentId: 100
            ),
        ]
    }()
}
