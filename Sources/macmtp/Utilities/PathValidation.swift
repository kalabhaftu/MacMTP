import Foundation

public enum PathValidation {
    /// Maximum allowable directory depth before aborting scanning/transfer to prevent runaway recursion or stack overflow.
    public static let maxDirectoryDepth: Int = 30

    /// Maximum path length in bytes/characters to avoid buffer overflows or crashes in Android MTP / VFS.
    public static let maxPathLength: Int = 900

    /// Maximum times a single folder name can be repeated in a path before detecting an infinite directory copy cycle.
    public static let maxRepeatingFolderSegments: Int = 2

    /// Returns true if `destinationPath` is identical to `sourcePath` or is a descendant subdirectory of `sourcePath`.
    /// Copying or moving a directory into itself or into one of its subdirectories causes infinite recursion.
    public static func isSelfOrDescendant(sourcePath: String, destinationPath: String) -> Bool {
        let src = URL(fileURLWithPath: sourcePath).standardized.resolvingSymlinksInPath().path
        let dest = URL(fileURLWithPath: destinationPath).standardized.resolvingSymlinksInPath().path

        if src == dest {
            return true
        }

        let prefix = src.hasSuffix("/") ? src : src + "/"
        return dest.hasPrefix(prefix)
    }

    /// Returns true if `sourcePath` already resides directly inside `destinationDir`.
    public static func isAlreadyInDirectory(sourcePath: String, destinationDir: String) -> Bool {
        let srcParent = URL(fileURLWithPath: (sourcePath as NSString).deletingLastPathComponent)
            .standardized.resolvingSymlinksInPath().path
        let dest = URL(fileURLWithPath: destinationDir)
            .standardized.resolvingSymlinksInPath().path
        return srcParent == dest
    }

    /// Checks whether copying or moving an item from `sourcePath` into `destinationDir` is safe.
    public static func isSafeToTransfer(sourcePath: String, destinationDir: String) -> (isSafe: Bool, reason: String?) {
        if isSelfOrDescendant(sourcePath: sourcePath, destinationPath: destinationDir) {
            return (false, "Cannot copy or move a folder into itself or into one of its subfolders.")
        }
        if isAlreadyInDirectory(sourcePath: sourcePath, destinationDir: destinationDir) {
            return (false, "Item is already located in the destination folder.")
        }
        if destinationDir.count + (sourcePath as NSString).lastPathComponent.count + 1 > maxPathLength {
            return (false, "Destination path exceeds maximum supported length.")
        }
        return (true, nil)
    }

    /// Detects whether a path contains cyclical repeating directory names or exceeds depth limits.
    public static func hasPathCycleOrExcessiveDepth(relativePath: String) -> Bool {
        let components = relativePath.split(separator: "/").map(String.init).filter { !$0.isEmpty && $0 != "." }
        if components.count > maxDirectoryDepth {
            return true
        }

        var counts: [String: Int] = [:]
        for comp in components {
            counts[comp, default: 0] += 1
            if counts[comp]! > maxRepeatingFolderSegments {
                return true
            }
        }
        return false
    }
}
