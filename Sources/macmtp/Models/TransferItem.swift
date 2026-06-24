import Foundation
import SwiftUI

// MARK: - TransferDirection

public enum TransferDirection: String, Codable, Sendable, CaseIterable {
    case localToMTP = "Local → Device"
    case mtpToLocal = "Device → Local"

    public var iconName: String {
        switch self {
        case .localToMTP:
            return "arrow.right.circle.fill"
        case .mtpToLocal:
            return "arrow.left.circle.fill"
        }
    }

    public var actionLabel: String {
        switch self {
        case .localToMTP:
            return "Upload"
        case .mtpToLocal:
            return "Download"
        }
    }
}

// MARK: - TransferStatus

public enum TransferStatus: String, Codable, Sendable, CaseIterable {
    case queued = "Queued"
    case preprocessing = "Preparing"
    case transferring = "Transferring"
    case completed = "Completed"
    case failed = "Failed"
    case skipped = "Skipped"
    case paused = "Paused"

    public var isActive: Bool {
        switch self {
        case .queued, .preprocessing, .transferring, .paused:
            return true
        case .completed, .failed, .skipped:
            return false
        }
    }

    public var isTerminal: Bool {
        switch self {
        case .completed, .failed, .skipped:
            return true
        case .queued, .preprocessing, .transferring, .paused:
            return false
        }
    }

    public var iconName: String {
        switch self {
        case .queued:
            return "clock.fill"
        case .preprocessing:
            return "gearshape.fill"
        case .transferring:
            return "arrow.left.arrow.right.circle.fill"
        case .completed:
            return "checkmark.circle.fill"
        case .failed:
            return "xmark.circle.fill"
        case .skipped:
            return "forward.fill"
        case .paused:
            return "pause.circle.fill"
        }
    }

    public var colorName: String {
        switch self {
        case .queued:
            return "secondary"
        case .preprocessing:
            return "orange"
        case .transferring:
            return "blue"
        case .completed:
            return "green"
        case .failed:
            return "red"
        case .skipped:
            return "gray"
        case .paused:
            return "yellow"
        }
    }
}

// MARK: - ConflictResolution

public enum ConflictResolution: String, Codable, Sendable, CaseIterable, Identifiable {
    case overwrite = "Overwrite"
    case skip = "Skip"
    case overwriteIfDifferent = "Overwrite if Different"
    case skipIfSameSize = "Skip if Same Size"
    case cancel = "Cancel"
    case askEach = "Ask for Each"

    public var menuLabel: String { rawValue }

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .overwrite: return "Overwrite All"
        case .skip: return "Skip All"
        case .overwriteIfDifferent: return "Overwrite if Different"
        case .skipIfSameSize: return "Skip if Same Size (Resume)"
        case .cancel: return "Cancel"
        case .askEach: return "Ask for Each"
        }
    }

    public var subtitle: String {
        switch self {
        case .overwrite: return "Replace all conflicting destination files with source files"
        case .skip: return "Keep all existing destination files and skip conflicting transfers"
        case .overwriteIfDifferent: return "Only overwrite files whose sizes differ from the source"
        case .skipIfSameSize: return "Skip fully-copied files with matching sizes; re-copy partial or broken files"
        case .cancel: return "Abort the entire transfer operation"
        case .askEach: return "Prompt for each conflicting file individually"
        }
    }

    public var iconName: String {
        switch self {
        case .overwrite: return "arrow.triangle.2.circlepath"
        case .skip: return "arrow.right.circle"
        case .overwriteIfDifferent: return "doc.badge.gearshape"
        case .skipIfSameSize: return "arrow.clockwise.circle"
        case .cancel: return "xmark.circle"
        case .askEach: return "questionmark.circle"
        }
    }

    public var iconColor: Color {
        switch self {
        case .overwrite: return .orange
        case .skip: return .blue
        case .overwriteIfDifferent: return .purple
        case .skipIfSameSize: return .green
        case .cancel: return .red
        case .askEach: return .gray
        }
    }
}

// MARK: - TransferItem

public struct TransferItem: Identifiable, Hashable, Sendable {

    public let id: UUID

    public let sourcePath: String

    public let destinationPath: String

    public let fileName: String

    public let fileSize: Int64

    public let direction: TransferDirection

    public var status: TransferStatus

    public var bytesTransferred: Int64

    public var speed: Double

    public var error: String?

    public var startTime: Date?

    public var estimatedTimeRemaining: TimeInterval?

    // MARK: - Initializer

    public init(
        id: UUID = UUID(),
        sourcePath: String,
        destinationPath: String,
        fileName: String? = nil,
        fileSize: Int64,
        direction: TransferDirection,
        status: TransferStatus = .queued,
        bytesTransferred: Int64 = 0,
        speed: Double = 0,
        error: String? = nil,
        startTime: Date? = nil,
        estimatedTimeRemaining: TimeInterval? = nil
    ) {
        self.id = id
        self.sourcePath = sourcePath
        self.destinationPath = destinationPath
        self.fileName = fileName ?? (sourcePath as NSString).lastPathComponent
        self.fileSize = fileSize
        self.direction = direction
        self.status = status
        self.bytesTransferred = bytesTransferred
        self.speed = speed
        self.error = error
        self.startTime = startTime
        self.estimatedTimeRemaining = estimatedTimeRemaining
    }

    // MARK: - Computed Properties

    /// Returns 1.0 for zero-byte files that have completed or are in progress.
    public var progress: Double {
        guard fileSize > 0 else {
            return status == .completed ? 1.0 : 0.0
        }
        return min(Double(bytesTransferred) / Double(fileSize), 1.0)
    }

    public var formattedSpeed: String {
        guard speed > 0 else { return "--" }
        return FormatUtils.formatSpeed(speed)
    }

    public var formattedETA: String {
        if let eta = estimatedTimeRemaining, eta > 0, eta.isFinite {
            return FormatUtils.formatDuration(eta)
        }
        // Fall back to computing from speed if the explicit ETA is absent.
        guard speed > 0 else { return "--" }
        let remaining = Double(fileSize - bytesTransferred)
        let computedETA = remaining / speed
        guard computedETA.isFinite, computedETA > 0 else { return "--" }
        return FormatUtils.formatDuration(computedETA)
    }

    public var formattedProgress: String {
        let transferred = FormatUtils.formatBytes(bytesTransferred)
        let total = FormatUtils.formatBytes(fileSize)
        let pct = String(format: "%.1f", progress * 100.0)
        return "\(transferred) / \(total) (\(pct)%)"
    }

    public var elapsedTime: TimeInterval? {
        guard let start = startTime else { return nil }
        return Date().timeIntervalSince(start)
    }

    public var formattedElapsedTime: String {
        guard let elapsed = elapsedTime else { return "--" }
        return FormatUtils.formatDuration(elapsed)
    }

    // MARK: - Hashable

    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    public static func == (lhs: TransferItem, rhs: TransferItem) -> Bool {
        lhs.id == rhs.id
    }
}

// MARK: - TransferItem Mutating Helpers

extension TransferItem {

    public mutating func markTransferring() {
        status = .transferring
        if startTime == nil {
            startTime = Date()
        }
    }

    /// - Parameter bytes: The total number of bytes transferred so far.
    public mutating func updateProgress(bytesTransferred bytes: Int64) {
        bytesTransferred = bytes
        if let start = startTime {
            let elapsed = Date().timeIntervalSince(start)
            if elapsed > 0 {
                speed = Double(bytes) / elapsed
                let remaining = Double(fileSize - bytes)
                estimatedTimeRemaining = remaining / speed
            }
        }
    }

    public mutating func markCompleted() {
        status = .completed
        bytesTransferred = fileSize
        estimatedTimeRemaining = 0
    }

    /// - Parameter message: A human-readable error description.
    public mutating func markFailed(_ message: String) {
        status = .failed
        error = message
        speed = 0
        estimatedTimeRemaining = nil
    }

    public mutating func markSkipped() {
        status = .skipped
        speed = 0
        estimatedTimeRemaining = nil
    }

    public mutating func togglePause() {
        if status == .paused {
            status = .transferring
        } else if status == .transferring {
            status = .paused
            speed = 0
        }
    }
}

// MARK: - Mock Data

extension TransferItem {
    public static let mockData: [TransferItem] = [
        TransferItem(
            sourcePath: "/Users/user/Downloads/movie.mp4",
            destinationPath: "/storage/Videos/movie.mp4",
            fileSize: 1_547_832_012,
            direction: .localToMTP,
            status: .transferring,
            bytesTransferred: 773_916_006,
            speed: 42_500_000,
            startTime: Date().addingTimeInterval(-18)
        ),
        TransferItem(
            sourcePath: "/Users/user/Downloads/photo.heic",
            destinationPath: "/storage/Photos/photo.heic",
            fileSize: 4_218_901,
            direction: .localToMTP,
            status: .completed,
            bytesTransferred: 4_218_901,
            speed: 0,
            startTime: Date().addingTimeInterval(-60)
        ),
        TransferItem(
            sourcePath: "/storage/Documents/report.pdf",
            destinationPath: "/Users/user/Desktop/report.pdf",
            fileSize: 2_340_678,
            direction: .mtpToLocal,
            status: .queued
        ),
        TransferItem(
            sourcePath: "/Users/user/Music/track.mp3",
            destinationPath: "/storage/Music/track.mp3",
            fileSize: 8_734_291,
            direction: .localToMTP,
            status: .failed,
            error: "Permission denied: storage is read-only"
        ),
    ]
}
