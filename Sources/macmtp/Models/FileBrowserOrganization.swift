import Foundation

enum FileSortColumn: String, CaseIterable, Identifiable {
    case name = "Name"
    case size = "Size"
    case type = "Type"
    case dateModified = "Date Modified"

    var id: Self { self }
}

enum FileSortDirection: String, CaseIterable, Identifiable {
    case ascending = "Ascending"
    case descending = "Descending"

    var id: Self { self }
    var toggled: Self { self == .ascending ? .descending : .ascending }
    var iconName: String { self == .ascending ? "chevron.up" : "chevron.down" }
}

enum FileGrouping: String, CaseIterable, Identifiable {
    case none = "None"
    case kind = "Kind"
    case extensionName = "Extension"
    case size = "Size"
    case dateModified = "Date Modified"

    var id: Self { self }
}

struct FileGroup: Identifiable, Equatable {
    let title: String
    let files: [FileNode]

    var id: String { title }
}

struct FileBrowserOrganization: Equatable {
    var searchText = ""
    var extensionFilter: String?
    var sortColumn: FileSortColumn = .name
    var sortDirection: FileSortDirection = .ascending
    var grouping: FileGrouping = .none

    func organize(_ files: [FileNode], showHidden: Bool, now: Date = Date()) -> [FileGroup] {
        var result = files.filter { showHidden || !$0.name.hasPrefix(".") }
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)

        if !query.isEmpty {
            result = result.filter {
                $0.isDirectory || $0.name.localizedCaseInsensitiveContains(query)
            }
        }
        if let extensionFilter {
            result = result.filter {
                $0.isDirectory || $0.extensionName.caseInsensitiveCompare(extensionFilter) == .orderedSame
            }
        }

        result.sort(by: compare)
        guard grouping != .none else { return [FileGroup(title: "", files: result)] }

        let grouped = Dictionary(grouping: result) { groupTitle(for: $0, now: now) }
        return grouped.keys.sorted(by: groupTitlePrecedes).map {
            FileGroup(title: $0, files: grouped[$0] ?? [])
        }
    }

    private func compare(_ lhs: FileNode, _ rhs: FileNode) -> Bool {
        if lhs.isDirectory != rhs.isDirectory {
            return lhs.isDirectory
        }

        let order: ComparisonResult
        switch sortColumn {
        case .name:
            order = lhs.name.localizedStandardCompare(rhs.name)
        case .size:
            order = effectiveSize(lhs) == effectiveSize(rhs)
                ? lhs.name.localizedStandardCompare(rhs.name)
                : (effectiveSize(lhs) < effectiveSize(rhs) ? .orderedAscending : .orderedDescending)
        case .type:
            order = typeName(lhs) == typeName(rhs)
                ? lhs.name.localizedStandardCompare(rhs.name)
                : typeName(lhs).localizedStandardCompare(typeName(rhs))
        case .dateModified:
            order = lhs.modificationDate == rhs.modificationDate
                ? lhs.name.localizedStandardCompare(rhs.name)
                : (lhs.modificationDate < rhs.modificationDate ? .orderedAscending : .orderedDescending)
        }
        return sortDirection == .ascending ? order == .orderedAscending : order == .orderedDescending
    }

    private func effectiveSize(_ file: FileNode) -> Int64 {
        file.size
    }

    private func typeName(_ file: FileNode) -> String {
        file.isDirectory ? "Folder" : (file.extensionName.isEmpty ? "File" : file.extensionName)
    }

    private func groupTitle(for file: FileNode, now: Date) -> String {
        switch grouping {
        case .none:
            return ""
        case .kind:
            if file.isDirectory { return "Folders" }
            switch file.extensionName {
            case "jpg", "jpeg", "png", "gif", "heic", "heif", "bmp", "tiff", "webp", "svg": return "Images"
            case "mp4", "mov", "avi", "mkv", "m4v", "wmv", "flv": return "Videos"
            case "mp3", "aac", "flac", "wav", "m4a", "ogg": return "Audio"
            case "pdf", "doc", "docx", "txt", "rtf", "pages", "key", "ppt", "pptx", "xls", "xlsx", "csv": return "Documents"
            case "zip", "gz", "tar", "rar", "7z", "dmg": return "Archives"
            default: return "Other Files"
            }
        case .extensionName:
            if file.isDirectory { return "Folders" }
            return file.extensionName.isEmpty ? "No Extension" : ".\(file.extensionName.lowercased())"
        case .size:
            if file.isDirectory { return "Folders" }
            switch effectiveSize(file) {
            case 0: return "Empty"
            case ..<1_000_000: return "Small (under 1 MB)"
            case ..<100_000_000: return "Medium (1–100 MB)"
            case ..<1_000_000_000: return "Large (100 MB–1 GB)"
            default: return "Very Large (1 GB+)"
            }
        case .dateModified:
            let calendar = Calendar.current
            if calendar.isDateInToday(file.modificationDate) { return "Today" }
            if calendar.isDateInYesterday(file.modificationDate) { return "Yesterday" }
            if let weekAgo = calendar.date(byAdding: .day, value: -7, to: now), file.modificationDate >= weekAgo {
                return "Previous 7 Days"
            }
            if calendar.isDate(file.modificationDate, equalTo: now, toGranularity: .month) { return "Earlier This Month" }
            return "Older"
        }
    }

    private func groupTitlePrecedes(_ lhs: String, _ rhs: String) -> Bool {
        let preferredOrder: [String]
        switch grouping {
        case .kind: preferredOrder = ["Folders", "Images", "Videos", "Audio", "Documents", "Archives", "Other Files"]
        case .size: preferredOrder = ["Folders", "Empty", "Small (under 1 MB)", "Medium (1–100 MB)", "Large (100 MB–1 GB)", "Very Large (1 GB+)"]
        case .dateModified: preferredOrder = ["Today", "Yesterday", "Previous 7 Days", "Earlier This Month", "Older"]
        case .extensionName, .none: preferredOrder = ["Folders", "No Extension"]
        }
        let left = preferredOrder.firstIndex(of: lhs)
        let right = preferredOrder.firstIndex(of: rhs)
        if let left, let right { return left < right }
        if left != nil { return true }
        if right != nil { return false }
        return lhs.localizedStandardCompare(rhs) == .orderedAscending
    }
}

enum FileSelectionRules {
    static func range(in orderedPaths: [String], from anchor: String, through target: String) -> Set<String>? {
        guard let anchorIndex = orderedPaths.firstIndex(of: anchor),
              let targetIndex = orderedPaths.firstIndex(of: target) else { return nil }
        let bounds = min(anchorIndex, targetIndex)...max(anchorIndex, targetIndex)
        return Set(bounds.map { orderedPaths[$0] })
    }
}
