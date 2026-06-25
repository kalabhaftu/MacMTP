import Foundation

/// All methods are static and thread-safe. Formatters are cached to avoid
enum FormatUtils {

    // MARK: - Cached Formatters

    private static let byteFormatterLock = NSLock()

    nonisolated(unsafe) private static let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useAll]
        formatter.countStyle = .file
        formatter.includesUnit = true
        formatter.isAdaptive = true
        return formatter
    }()

    // MARK: - Byte Formatting

    /// - Parameter bytes: The number of bytes (Int64).
    static func formatBytes(_ bytes: Int64) -> String {
        byteFormatterLock.lock()
        defer { byteFormatterLock.unlock() }
        return byteFormatter.string(fromByteCount: bytes)
    }

    /// Values larger than `Int64.max` are capped and annotated with "+".
    /// - Parameter bytes: The number of bytes (UInt64).
    static func formatBytes(_ bytes: UInt64) -> String {
        if bytes <= UInt64(Int64.max) {
            byteFormatterLock.lock()
            defer { byteFormatterLock.unlock() }
            return byteFormatter.string(fromByteCount: Int64(bytes))
        }
        // For values exceeding Int64.max (~8 EB), format in TB manually.
        let tb = Double(bytes) / 1_000_000_000_000
        return String(format: "%.1f TB", tb)
    }

    // MARK: - Date Formatting

    /// - Parameter date: The date to format.
    static func formatDate(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .shortened)
    }

    // MARK: - Duration Formatting

    /// Examples:
    /// - 4320 seconds → "1h 12m"
    /// - 0.5 seconds → "< 1s"
    /// - Parameter interval: The duration in seconds.
    static func formatDuration(_ interval: TimeInterval) -> String {
        guard interval.isFinite, interval >= 0 else { return "--" }

        let totalSeconds = Int(interval)

        if totalSeconds < 1 {
            return "< 1s"
        }

        let days = totalSeconds / 86400
        let hours = (totalSeconds % 86400) / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60

        if days > 0 {
            return "\(days)d \(hours)h"
        } else if hours > 0 {
            return "\(hours)h \(minutes)m"
        } else if minutes > 0 {
            return "\(minutes)m \(seconds)s"
        } else {
            return "\(seconds)s"
        }
    }

    // MARK: - Speed Formatting

    /// - Parameter bytesPerSecond: The speed in bytes per second.
    static func formatSpeed(_ bytesPerSecond: Double) -> String {
        guard bytesPerSecond.isFinite, bytesPerSecond >= 0 else { return "--" }

        let units: [(threshold: Double, suffix: String)] = [
            (1_000_000_000, "GB/s"),
            (1_000_000, "MB/s"),
            (1_000, "KB/s"),
        ]

        for unit in units {
            if bytesPerSecond >= unit.threshold {
                let value = bytesPerSecond / unit.threshold
                // Use integer formatting when the value rounds to a whole number.
                if value >= 100 {
                    return String(format: "%.0f %@", value, unit.suffix)
                } else if value >= 10 {
                    return String(format: "%.1f %@", value, unit.suffix)
                } else {
                    return String(format: "%.2f %@", value, unit.suffix)
                }
            }
        }

        return String(format: "%.0f B/s", bytesPerSecond)
    }

    // MARK: - File Extension → SF Symbol Icon

    /// The mapping covers common media, document, archive, code, and system
    /// - Parameter ext: The file extension without a leading dot, lowercased.
    static func fileExtensionIcon(_ ext: String) -> String {
        let key = ext.lowercased()

        // Video
        let videoExtensions: Set<String> = [
            "mp4", "mkv", "avi", "mov", "wmv", "flv", "webm", "m4v",
            "mpg", "mpeg", "3gp", "ts", "vob",
        ]
        if videoExtensions.contains(key) { return "film" }

        // Audio
        let audioExtensions: Set<String> = [
            "mp3", "aac", "flac", "wav", "ogg", "wma", "m4a", "aiff",
            "alac", "opus", "mid", "midi",
        ]
        if audioExtensions.contains(key) { return "music.note" }

        // Image
        let imageExtensions: Set<String> = [
            "jpg", "jpeg", "png", "heic", "heif", "gif", "bmp", "tiff",
            "tif", "webp", "svg", "ico", "raw", "cr2", "nef", "arw",
            "dng",
        ]
        if imageExtensions.contains(key) { return "photo" }

        // PDF
        if key == "pdf" { return "doc.richtext" }

        // Rich documents
        let richDocExtensions: Set<String> = [
            "doc", "docx", "rtf", "odt", "pages",
        ]
        if richDocExtensions.contains(key) { return "doc.richtext" }

        // Spreadsheets
        let spreadsheetExtensions: Set<String> = [
            "xls", "xlsx", "csv", "numbers", "ods",
        ]
        if spreadsheetExtensions.contains(key) { return "tablecells" }

        // Presentations
        let presentationExtensions: Set<String> = [
            "ppt", "pptx", "key", "odp",
        ]
        if presentationExtensions.contains(key) { return "rectangle.on.rectangle" }

        // Archives
        let archiveExtensions: Set<String> = [
            "zip", "tar", "gz", "bz2", "xz", "7z", "rar", "dmg",
            "iso", "pkg", "deb", "rpm",
        ]
        if archiveExtensions.contains(key) { return "doc.zipper" }

        // Plain text
        let textExtensions: Set<String> = [
            "txt", "md", "markdown", "log", "cfg", "ini", "conf",
            "yaml", "yml", "toml",
        ]
        if textExtensions.contains(key) { return "doc.text" }

        // Source code
        let codeExtensions: Set<String> = [
            "swift", "py", "js", "ts", "java", "kt", "c", "cpp",
            "h", "hpp", "cs", "go", "rs", "rb", "php", "html",
            "css", "scss", "json", "xml", "sh", "bash", "zsh",
            "sql", "r", "m", "mm",
        ]
        if codeExtensions.contains(key) { return "chevron.left.forwardslash.chevron.right" }

        // Executables / binaries
        let execExtensions: Set<String> = [
            "app", "exe", "bin", "command", "sh",
        ]
        if execExtensions.contains(key) { return "terminal" }

        // Fonts
        let fontExtensions: Set<String> = [
            "ttf", "otf", "woff", "woff2",
        ]
        if fontExtensions.contains(key) { return "textformat" }

        // Database
        let dbExtensions: Set<String> = [
            "db", "sqlite", "sqlite3", "realm",
        ]
        if dbExtensions.contains(key) { return "cylinder" }

        // Android-specific
        if key == "apk" || key == "aab" { return "shippingbox" }

        // Default
        return "doc"
    }

    // MARK: - MIME Type Mapping

    /// Covers the most common media, document, archive, and text types.
    /// - Parameter ext: The file extension without a leading dot (case-insensitive).
    static func mimeTypeForExtension(_ ext: String) -> String {
        let key = ext.lowercased()

        let mimeMap: [String: String] = [
            // Video
            "mp4": "video/mp4",
            "mkv": "video/x-matroska",
            "avi": "video/x-msvideo",
            "mov": "video/quicktime",
            "wmv": "video/x-ms-wmv",
            "flv": "video/x-flv",
            "webm": "video/webm",
            "m4v": "video/x-m4v",
            "mpg": "video/mpeg",
            "mpeg": "video/mpeg",
            "3gp": "video/3gpp",
            "ts": "video/mp2t",

            // Audio
            "mp3": "audio/mpeg",
            "aac": "audio/aac",
            "flac": "audio/flac",
            "wav": "audio/wav",
            "ogg": "audio/ogg",
            "wma": "audio/x-ms-wma",
            "m4a": "audio/mp4",
            "aiff": "audio/aiff",
            "opus": "audio/opus",
            "mid": "audio/midi",
            "midi": "audio/midi",

            // Image
            "jpg": "image/jpeg",
            "jpeg": "image/jpeg",
            "png": "image/png",
            "gif": "image/gif",
            "bmp": "image/bmp",
            "tiff": "image/tiff",
            "tif": "image/tiff",
            "webp": "image/webp",
            "svg": "image/svg+xml",
            "ico": "image/x-icon",
            "heic": "image/heic",
            "heif": "image/heif",
            "raw": "image/x-raw",
            "dng": "image/x-adobe-dng",

            // Documents
            "pdf": "application/pdf",
            "doc": "application/msword",
            "docx": "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
            "rtf": "application/rtf",
            "odt": "application/vnd.oasis.opendocument.text",
            "xls": "application/vnd.ms-excel",
            "xlsx": "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
            "ppt": "application/vnd.ms-powerpoint",
            "pptx": "application/vnd.openxmlformats-officedocument.presentationml.presentation",
            "csv": "text/csv",

            // Archives
            "zip": "application/zip",
            "tar": "application/x-tar",
            "gz": "application/gzip",
            "bz2": "application/x-bzip2",
            "xz": "application/x-xz",
            "7z": "application/x-7z-compressed",
            "rar": "application/vnd.rar",
            "dmg": "application/x-apple-diskimage",
            "iso": "application/x-iso9660-image",

            // Text / Code
            "txt": "text/plain",
            "md": "text/markdown",
            "html": "text/html",
            "htm": "text/html",
            "css": "text/css",
            "js": "text/javascript",
            "typescript": "text/typescript",
            "json": "application/json",
            "xml": "application/xml",
            "yaml": "application/x-yaml",
            "yml": "application/x-yaml",
            "toml": "application/toml",
            "sh": "application/x-sh",
            "swift": "text/x-swift",
            "py": "text/x-python",
            "java": "text/x-java-source",
            "c": "text/x-c",
            "cpp": "text/x-c++",
            "h": "text/x-c",
            "go": "text/x-go",
            "rs": "text/x-rust",
            "rb": "text/x-ruby",
            "php": "text/x-php",
            "sql": "application/sql",

            // Fonts
            "ttf": "font/ttf",
            "otf": "font/otf",
            "woff": "font/woff",
            "woff2": "font/woff2",

            // Android
            "apk": "application/vnd.android.package-archive",

            // Database
            "sqlite": "application/x-sqlite3",
            "sqlite3": "application/x-sqlite3",
            "db": "application/x-sqlite3",
        ]

        return mimeMap[key] ?? "application/octet-stream"
    }
}
