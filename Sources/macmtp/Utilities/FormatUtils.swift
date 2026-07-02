import Foundation

enum FormatUtils {


    private static let byteFormatterLock = NSLock()

    nonisolated(unsafe) private static let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useAll]
        formatter.countStyle = .file
        formatter.includesUnit = true
        formatter.isAdaptive = true
        return formatter
    }()


    static func formatBytes(_ bytes: Int64) -> String {
        byteFormatterLock.lock()
        defer { byteFormatterLock.unlock() }
        return byteFormatter.string(fromByteCount: bytes)
    }

    static func formatBytes(_ bytes: UInt64) -> String {
        if bytes <= UInt64(Int64.max) {
            byteFormatterLock.lock()
            defer { byteFormatterLock.unlock() }
            return byteFormatter.string(fromByteCount: Int64(bytes))
        }
        let tb = Double(bytes) / 1_000_000_000_000
        return String(format: "%.1f TB", tb)
    }


    static func formatDate(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .shortened)
    }


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


    static func fileExtensionIcon(_ ext: String) -> String {
        let key = ext.lowercased()

        let videoExtensions: Set<String> = [
            "mp4", "mkv", "avi", "mov", "wmv", "flv", "webm", "m4v",
            "mpg", "mpeg", "3gp", "ts", "vob",
        ]
        if videoExtensions.contains(key) { return "film" }

        let audioExtensions: Set<String> = [
            "mp3", "aac", "flac", "wav", "ogg", "wma", "m4a", "aiff",
            "alac", "opus", "mid", "midi",
        ]
        if audioExtensions.contains(key) { return "music.note" }

        let imageExtensions: Set<String> = [
            "jpg", "jpeg", "png", "heic", "heif", "gif", "bmp", "tiff",
            "tif", "webp", "svg", "ico", "raw", "cr2", "nef", "arw",
            "dng",
        ]
        if imageExtensions.contains(key) { return "photo" }

        if key == "pdf" { return "doc.richtext" }

        let richDocExtensions: Set<String> = [
            "doc", "docx", "rtf", "odt", "pages",
        ]
        if richDocExtensions.contains(key) { return "doc.richtext" }

        let spreadsheetExtensions: Set<String> = [
            "xls", "xlsx", "csv", "numbers", "ods",
        ]
        if spreadsheetExtensions.contains(key) { return "tablecells" }

        let presentationExtensions: Set<String> = [
            "ppt", "pptx", "key", "odp",
        ]
        if presentationExtensions.contains(key) { return "rectangle.on.rectangle" }

        let archiveExtensions: Set<String> = [
            "zip", "tar", "gz", "bz2", "xz", "7z", "rar", "dmg",
            "iso", "pkg", "deb", "rpm",
        ]
        if archiveExtensions.contains(key) { return "doc.zipper" }

        let textExtensions: Set<String> = [
            "txt", "md", "markdown", "log", "cfg", "ini", "conf",
            "yaml", "yml", "toml",
        ]
        if textExtensions.contains(key) { return "doc.text" }

        let codeExtensions: Set<String> = [
            "swift", "py", "js", "ts", "java", "kt", "c", "cpp",
            "h", "hpp", "cs", "go", "rs", "rb", "php", "html",
            "css", "scss", "json", "xml", "sh", "bash", "zsh",
            "sql", "r", "m", "mm",
        ]
        if codeExtensions.contains(key) { return "chevron.left.forwardslash.chevron.right" }

        let execExtensions: Set<String> = [
            "app", "exe", "bin", "command", "sh",
        ]
        if execExtensions.contains(key) { return "terminal" }

        let fontExtensions: Set<String> = [
            "ttf", "otf", "woff", "woff2",
        ]
        if fontExtensions.contains(key) { return "textformat" }

        let dbExtensions: Set<String> = [
            "db", "sqlite", "sqlite3", "realm",
        ]
        if dbExtensions.contains(key) { return "cylinder" }

        if key == "apk" || key == "aab" { return "shippingbox" }

        return "doc"
    }


    static func mimeTypeForExtension(_ ext: String) -> String {
        let key = ext.lowercased()

        let mimeMap: [String: String] = [
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

            "zip": "application/zip",
            "tar": "application/x-tar",
            "gz": "application/gzip",
            "bz2": "application/x-bzip2",
            "xz": "application/x-xz",
            "7z": "application/x-7z-compressed",
            "rar": "application/vnd.rar",
            "dmg": "application/x-apple-diskimage",
            "iso": "application/x-iso9660-image",

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

            "ttf": "font/ttf",
            "otf": "font/otf",
            "woff": "font/woff",
            "woff2": "font/woff2",

            "apk": "application/vnd.android.package-archive",

            "sqlite": "application/x-sqlite3",
            "sqlite3": "application/x-sqlite3",
            "db": "application/x-sqlite3",
        ]

        return mimeMap[key] ?? "application/octet-stream"
    }
}
