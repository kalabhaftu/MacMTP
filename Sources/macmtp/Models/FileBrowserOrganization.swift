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

struct FileTypeaheadState: Equatable {
    var query = ""
    var lastKeyTime = Date.distantPast
}

struct FileTypeaheadResult: Equatable {
    let state: FileTypeaheadState
    let selectedPath: String?
}

enum FileTypeaheadRules {
    static let timeout: TimeInterval = 1.0

    static func advance(
        key: String,
        files: [FileNode],
        selectedPath: String?,
        state: FileTypeaheadState,
        now: Date,
        timeout: TimeInterval = timeout
    ) -> FileTypeaheadResult {
        let normalizedKey = String(key.lowercased().prefix(1))
        guard !normalizedKey.isEmpty,
              normalizedKey.unicodeScalars.allSatisfy({ CharacterSet.letters.contains($0) }) else {
            return FileTypeaheadResult(state: state, selectedPath: nil)
        }

        let withinTimeout = now.timeIntervalSince(state.lastKeyTime) < timeout
        let repeatedLetter = withinTimeout && state.query == normalizedKey
        let query = repeatedLetter
            ? normalizedKey
            : (withinTimeout && !state.query.isEmpty ? state.query + normalizedKey : normalizedKey)
        let matches = files.filter { $0.name.lowercased().hasPrefix(query) }

        if !matches.isEmpty {
            let selected: FileNode?
            if repeatedLetter,
               let selectedPath,
               let selectedIndex = matches.firstIndex(where: { $0.path == selectedPath }) {
                selected = matches[(selectedIndex + 1) % matches.count]
            } else {
                selected = matches.first
            }
            return FileTypeaheadResult(
                state: FileTypeaheadState(query: query, lastKeyTime: now),
                selectedPath: selected?.path
            )
        }

        // A failed multi-character query should not poison the next key. Keep
        // the latest letter as the new query and let the caller keep selection.
        return FileTypeaheadResult(
            state: FileTypeaheadState(query: normalizedKey, lastKeyTime: now),
            selectedPath: nil
        )
    }
}

enum FileGridLayout {
    static let spacing = 8.0
    static let horizontalPadding = 12.0

    static func cellWidth(large: Bool) -> Double {
        large ? 96 : 80
    }

    static func cellHeight(large: Bool) -> Double {
        large ? 116 : 76
    }

    static func labelHeight(large: Bool) -> Double {
        large ? 34 : 30
    }

    static func columnCount(containerWidth: Double, large: Bool) -> Int {
        let availableWidth = max(0, containerWidth - (horizontalPadding * 2))
        return max(1, Int((availableWidth + spacing) / (cellWidth(large: large) + spacing)))
    }
}
