import SwiftUI
import Combine

// MARK: - Transfer State

public enum TransferState: Equatable {
    case idle
    case transferring
    case paused
    case completed
    case failed(String)
    case cancelled

    public var isTerminal: Bool {
        switch self {
        case .completed, .cancelled, .failed: return true
        default: return false
        }
    }
}

// MARK: - Transfer Batch (Observable Model)

/// Used by TransferProgressView to display real-time progress.
public class TransferBatch: ObservableObject {
    @Published public var items: [TransferItem] = []
    @Published public var currentItemIndex: Int = 0
    @Published public var state: TransferState = .idle
    @Published public var startTime: Date? = nil
    @Published public var bytesPerSecond: Double = 0

    // Speed calculation history for smoothing
    private var speedSamples: [(time: Date, bytes: Int64)] = []
    private let maxSpeedSamples = 10

    public var totalFileCount: Int { items.count }

    public var completedFileCount: Int { items.filter { $0.status == .completed }.count }

    public var failedFileCount: Int { items.filter { $0.status == .failed }.count }

    public var totalBytes: Int64 { items.reduce(0) { $0 + $1.fileSize } }

    public var totalBytesTransferred: Int64 { items.reduce(0) { $0 + $1.bytesTransferred } }

    public var overallProgress: Double {
        guard totalBytes > 0 else { return 0 }
        return Double(totalBytesTransferred) / Double(totalBytes)
    }

    public var currentItem: TransferItem? {
        guard currentItemIndex >= 0 && currentItemIndex < items.count else { return nil }
        return items[currentItemIndex]
    }

    public var elapsedTime: TimeInterval {
        guard let start = startTime else { return 0 }
        return Date().timeIntervalSince(start)
    }

    public var estimatedTimeRemaining: TimeInterval? {
        guard bytesPerSecond > 0 else { return nil }
        let remainingBytes = Double(totalBytes - totalBytesTransferred)
        return remainingBytes / bytesPerSecond
    }

    public var isActive: Bool {
        state == .transferring
    }

    public var canPause: Bool {
        state == .transferring
    }

    public var canResume: Bool {
        state == .paused
    }

    // MARK: - Control Methods

    public func start() {
        state = .transferring
        startTime = Date()
        speedSamples.removeAll()
    }

    public func pause() {
        state = .paused
    }

    public func resume() {
        state = .transferring
    }

    public func cancel() {
        state = .cancelled
    }

    public func complete() {
        state = .completed
    }

    public func recordSpeedSample(bytesTransferredNow: Int64) {
        let now = Date()
        speedSamples.append((time: now, bytes: bytesTransferredNow))
        if speedSamples.count > maxSpeedSamples {
            speedSamples.removeFirst()
        }

        // Calculate speed from sliding window
        guard speedSamples.count >= 2 else { return }
        let oldest = speedSamples.first!
        let newest = speedSamples.last!
        let timeDelta = newest.time.timeIntervalSince(oldest.time)
        guard timeDelta > 0 else { return }
        let bytesDelta = Double(newest.bytes - oldest.bytes)
        bytesPerSecond = max(0, bytesDelta / timeDelta)
    }

    public func updateCurrentItemProgress(bytesTransferred: Int64) {
        guard currentItemIndex < items.count else { return }
        items[currentItemIndex].bytesTransferred = bytesTransferred
        recordSpeedSample(bytesTransferredNow: totalBytesTransferred)
    }

    public func advanceToNextItem() {
        guard currentItemIndex < items.count else { return }
        items[currentItemIndex].markCompleted()
        if currentItemIndex < items.count - 1 {
            currentItemIndex += 1
        } else {
            complete()
        }
    }

    public func failCurrentItem(error: String) {
        guard currentItemIndex < items.count else { return }
        items[currentItemIndex].markFailed(error)
        if currentItemIndex < items.count - 1 {
            currentItemIndex += 1
        } else {
            complete()
        }
    }
}

// MARK: - Transfer Progress View

/// speed, ETA, elapsed time, and pause/cancel controls.
public struct TransferProgressView: View {
    @ObservedObject public var batch: TransferBatch

    public var onCancel: () -> Void = {}
    public var onPause: () -> Void = {}
    public var onResume: () -> Void = {}

    @State private var isPulsing: Bool = false

    @State private var isMinimized: Bool = false

    // Timer for elapsed time updates
    @State private var elapsedTimerTick: Int = 0
    private let elapsedTimer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    public var body: some View {
        VStack(spacing: 0) {
            Divider()

            if isMinimized {
                minimizedView
                    .padding(.horizontal, 20)
                    .padding(.vertical, 8)
            } else {
                VStack(spacing: 12) {
                    // Top row: title and status badge
                    HStack(alignment: .center) {
                        transferStatusIcon

                        VStack(alignment: .leading, spacing: 2) {
                            Text(statusTitle)
                                .font(.headline)
                                .fontWeight(.semibold)

                            Text(statusSubtitle)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }

                        Spacer()

                    // File count badge
                    fileCountBadge

                    Button(action: { isMinimized = true }) {
                        Image(systemName: "chevron.down")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Minimize progress panel")
                    .padding(.leading, 4)
                }

                    // Overall progress bar
                    overallProgressSection

                    // Current file section
                    if let currentFile = batch.currentItem, batch.isActive || batch.state == .paused {
                        currentFileSection(currentFile)
                    }

                    // Stats row
                    statsRow

                    // Control buttons
                    controlButtons
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
            }
        }
        .background(
            ZStack {
                // Translucent background with blur effect
                VisualEffectBlur(material: .hudWindow, blendingMode: .behindWindow)
                Color(NSColor.windowBackgroundColor).opacity(0.7)
            }
        )
        .onReceive(elapsedTimer) { _ in
            if batch.isActive {
                elapsedTimerTick += 1
            }
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true)) {
                isPulsing = true
            }
        }
    }

    // MARK: - Minimized View

    private var minimizedView: some View {
        HStack(spacing: 10) {
            transferStatusIcon
                .font(.system(size: 14))

            VStack(alignment: .leading, spacing: 1) {
                Text(statusTitle)
                    .font(.caption)
                    .fontWeight(.semibold)
                Text(statusSubtitle)
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            .lineLimit(1)

            ProgressView(value: batch.overallProgress)
                .progressViewStyle(.linear)
                .frame(width: 120)

            Text(formatPercentage(batch.overallProgress))
                .font(.caption2)
                .monospacedDigit()
                .foregroundColor(.secondary)
                .frame(width: 36)

            Spacer()

            Button(action: { isMinimized = false }) {
                Image(systemName: "chevron.up")
                    .font(.caption)
            }
            .buttonStyle(.plain)
            .help("Expand progress details")

            if batch.isActive || batch.state == .paused {
                Button(role: .destructive, action: {
                    batch.cancel()
                    onCancel()
                }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .help("Cancel transfer")
            }
        }
    }

    // MARK: - Initializer

    public init(
        batch: TransferBatch,
        onCancel: @escaping () -> Void = {},
        onPause: @escaping () -> Void = {},
        onResume: @escaping () -> Void = {}
    ) {
        self.batch = batch
        self.onCancel = onCancel
        self.onPause = onPause
        self.onResume = onResume
    }

    // MARK: - Status Icon

    private var transferStatusIcon: some View {
        Group {
            switch batch.state {
            case .transferring:
                Image(systemName: "arrow.left.arrow.right.circle.fill")
                    .font(.title2)
                    .foregroundColor(.accentColor)
                    .opacity(isPulsing ? 0.6 : 1.0)
                    .symbolEffect(.pulse, isActive: batch.isActive)
            case .paused:
                Image(systemName: "pause.circle.fill")
                    .font(.title2)
                    .foregroundColor(.yellow)
            case .completed:
                Image(systemName: "checkmark.circle.fill")
                    .font(.title2)
                    .foregroundColor(.green)
            case .failed:
                Image(systemName: "exclamationmark.circle.fill")
                    .font(.title2)
                    .foregroundColor(.red)
            case .cancelled:
                Image(systemName: "xmark.circle.fill")
                    .font(.title2)
                    .foregroundColor(.secondary)
            case .idle:
                Image(systemName: "circle.dotted")
                    .font(.title2)
                    .foregroundColor(.secondary)
            }
        }
    }

    // MARK: - Status Text

    private var statusTitle: String {
        switch batch.state {
        case .transferring: return "Transferring Files…"
        case .paused: return "Transfer Paused"
        case .completed:
            if batch.failedFileCount > 0 {
                return "Transfer Completed with Errors"
            }
            return "Transfer Complete"
        case .failed(let msg): return "Transfer Failed: \(msg)"
        case .cancelled: return "Transfer Cancelled"
        case .idle: return "Ready"
        }
    }

    private var statusSubtitle: String {
        switch batch.state {
        case .transferring:
            if let current = batch.currentItem {
                return "Copying \(current.fileName)"
            }
            return "Preparing…"
        case .paused:
            return "Tap Resume to continue"
        case .completed:
            let duration = formatDuration(batch.elapsedTime)
            return "Completed in \(duration)"
        case .failed:
            return "\(batch.completedFileCount) of \(batch.totalFileCount) files transferred"
        case .cancelled:
            return "\(batch.completedFileCount) of \(batch.totalFileCount) files were transferred before cancellation"
        case .idle:
            return "No active transfers"
        }
    }

    // MARK: - File Count Badge

    private var fileCountBadge: some View {
        HStack(spacing: 4) {
            Image(systemName: "doc.on.doc")
                .font(.caption2)
            Text("\(batch.completedFileCount) of \(batch.totalFileCount) files")
                .font(.caption)
                .fontWeight(.medium)
                .monospacedDigit()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(
            Capsule()
                .fill(Color(NSColor.controlBackgroundColor))
        )
        .overlay(
            Capsule()
                .stroke(Color(NSColor.separatorColor), lineWidth: 0.5)
        )
    }

    // MARK: - Overall Progress

    private var overallProgressSection: some View {
        VStack(spacing: 4) {
            // Progress bar
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    // Track
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color(NSColor.controlBackgroundColor))

                    // Fill
                    RoundedRectangle(cornerRadius: 4)
                        .fill(overallProgressColor)
                        .frame(width: max(0, geometry.size.width * CGFloat(batch.overallProgress)))
                        .animation(.easeInOut(duration: 0.3), value: batch.overallProgress)
                }
            }
            .frame(height: 8)

            // Progress details
            HStack {
                Text(formatPercentage(batch.overallProgress))
                    .font(.caption)
                    .fontWeight(.semibold)
                    .monospacedDigit()
                    .foregroundColor(.primary)

                Spacer()

                Text("\(formatBytes(batch.totalBytesTransferred)) of \(formatBytes(batch.totalBytes))")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .monospacedDigit()
            }
        }
    }

    private var overallProgressColor: Color {
        switch batch.state {
        case .transferring: return .accentColor
        case .paused: return .yellow
        case .completed: return .green
        case .failed: return .red
        case .cancelled: return .secondary
        case .idle: return .secondary
        }
    }

    // MARK: - Current File Section

    private func currentFileSection(_ item: TransferItem) -> some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: fileIcon(for: item.fileName))
                    .font(.caption)
                    .foregroundColor(.secondary)

                VStack(alignment: .leading, spacing: 1) {
                    Text(item.fileName)
                        .font(.caption)
                        .fontWeight(.medium)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    Text(item.destinationPath)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }

                Spacer()

                Text("\(formatBytes(item.bytesTransferred)) / \(formatBytes(item.fileSize))")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .monospacedDigit()
            }

            // Per-file progress bar
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color(NSColor.controlBackgroundColor))

                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.accentColor.opacity(0.6))
                        .frame(width: max(0, geometry.size.width * CGFloat(item.progress)))
                        .animation(.easeInOut(duration: 0.2), value: item.progress)
                }
            }
            .frame(height: 4)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(NSColor.controlBackgroundColor).opacity(0.5))
        )
    }

    // MARK: - Stats Row

    private var statsRow: some View {
        HStack(spacing: 16) {
            // Transfer speed
            statItem(
                icon: "gauge.with.dots.needle.bottom.50percent",
                label: "Speed",
                value: batch.isActive && batch.bytesPerSecond > 0 ? formatSpeed(batch.bytesPerSecond) : "—"
            )

            Divider().frame(height: 16)

            // ETA
            statItem(
                icon: "clock",
                label: "Remaining",
                value: etaDisplayString
            )

            Divider().frame(height: 16)

            // Elapsed time
            statItem(
                icon: "timer",
                label: "Elapsed",
                value: formatDuration(batch.elapsedTime)
            )

            if batch.failedFileCount > 0 {
                Divider().frame(height: 16)

                statItem(
                    icon: "exclamationmark.triangle.fill",
                    label: "Failed",
                    value: "\(batch.failedFileCount)",
                    valueColor: .red
                )
            }
        }
        .padding(.horizontal, 4)
    }

    private var etaDisplayString: String {
        guard batch.isActive else {
            if batch.state == .paused { return "Paused" }
            if batch.state == .completed { return "Done" }
            return "—"
        }
        guard batch.bytesPerSecond > 0 else {
            return formatDuration(batch.elapsedTime)
        }
        guard let eta = batch.estimatedTimeRemaining else { return "—" }
        return "About \(formatDuration(eta))"
    }

    private func statItem(
        icon: String,
        label: String,
        value: String,
        valueColor: Color = .primary
    ) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.caption2)
                .foregroundColor(.secondary)

            VStack(alignment: .leading, spacing: 1) {
                Text(label)
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
                    .textCase(.uppercase)
                Text(value)
                    .font(.caption)
                    .fontWeight(.medium)
                    .monospacedDigit()
                    .foregroundColor(valueColor)
            }
        }
    }

    // MARK: - Control Buttons

    private var controlButtons: some View {
        HStack(spacing: 12) {
            Spacer()

            if batch.canPause {
                Button(action: {
                    batch.pause()
                    onPause()
                }) {
                    Label("Pause", systemImage: "pause.fill")
                        .font(.subheadline)
                        .fontWeight(.medium)
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
            }

            if batch.canResume {
                Button(action: {
                    batch.resume()
                    onResume()
                }) {
                    Label("Resume", systemImage: "play.fill")
                        .font(.subheadline)
                        .fontWeight(.medium)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
            }

            if batch.isActive || batch.state == .paused {
                Button(role: .destructive, action: {
                    batch.cancel()
                    onCancel()
                }) {
                    Label("Cancel", systemImage: "xmark.circle.fill")
                        .font(.subheadline)
                        .fontWeight(.medium)
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
            }

            if batch.state == .completed || batch.state == .cancelled {
                Button(action: onCancel) {
                    Label("Dismiss", systemImage: "xmark")
                        .font(.subheadline)
                        .fontWeight(.medium)
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
            }
        }
    }

    // MARK: - Formatting Helpers

    private func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useAll]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }

    private func formatPercentage(_ fraction: Double) -> String {
        let pct = fraction * 100
        if pct >= 99.95 && fraction < 1.0 {
            return "99.9%"
        }
        if fraction >= 1.0 {
            return "100%"
        }
        return String(format: "%.1f%%", pct)
    }

    private func formatSpeed(_ bytesPerSec: Double) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useAll]
        formatter.countStyle = .file
        return "\(formatter.string(fromByteCount: Int64(bytesPerSec)))/s"
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let totalSeconds = Int(seconds)
        if totalSeconds < 60 {
            return "\(totalSeconds)s"
        }
        let minutes = totalSeconds / 60
        let secs = totalSeconds % 60
        if minutes < 60 {
            return "\(minutes)m \(secs)s"
        }
        let hours = minutes / 60
        let mins = minutes % 60
        return "\(hours)h \(mins)m"
    }

    private func fileIcon(for fileName: String) -> String {
        let ext = (fileName as NSString).pathExtension.lowercased()
        switch ext {
        case "jpg", "jpeg", "png", "gif", "heic", "webp":
            return "photo"
        case "mp4", "mov", "avi", "mkv":
            return "film"
        case "mp3", "aac", "flac", "wav", "m4a":
            return "music.note"
        case "pdf":
            return "doc.richtext"
        case "zip", "gz", "tar", "rar":
            return "doc.zipper"
        default:
            return "doc"
        }
    }
}

// MARK: - Visual Effect Blur (NSVisualEffectView wrapper)

public struct VisualEffectBlur: NSViewRepresentable {
    public var material: NSVisualEffectView.Material
    public var blendingMode: NSVisualEffectView.BlendingMode

    public init(material: NSVisualEffectView.Material, blendingMode: NSVisualEffectView.BlendingMode) {
        self.material = material
        self.blendingMode = blendingMode
    }

    public func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .followsWindowActiveState
        return view
    }

    public func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
    }
}
