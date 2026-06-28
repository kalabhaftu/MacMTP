import SwiftUI

// MARK: - Conflicting File Pair

public struct ConflictingFilePair: Identifiable, Hashable {
    public let id = UUID()
    public let fileName: String
    public let sourcePath: String
    public let sourceSize: Int64
    public let sourceDate: Date
    public let destinationPath: String
    public let destinationSize: Int64
    public let destinationDate: Date

    var sizesDiffer: Bool {
        sourceSize != destinationSize
    }

    public var sourceIsNewer: Bool {
        sourceDate > destinationDate
    }

    public init(
        fileName: String,
        sourcePath: String,
        sourceSize: Int64,
        sourceDate: Date,
        destinationPath: String,
        destinationSize: Int64,
        destinationDate: Date
    ) {
        self.fileName = fileName
        self.sourcePath = sourcePath
        self.sourceSize = sourceSize
        self.sourceDate = sourceDate
        self.destinationPath = destinationPath
        self.destinationSize = destinationSize
        self.destinationDate = destinationDate
    }
}

// MARK: - Conflict Dialog View

/// Presents a scrollable list of conflicting files with source vs destination comparison,
struct ConflictDialogView: View {
    @Environment(\.dismiss) private var dismiss

    let conflictingFiles: [ConflictingFilePair]

    let totalFileCount: Int

    @Binding var resolution: ConflictResolution?

    @Binding var rememberForBatch: Bool

    @State private var expandedFileID: UUID? = nil

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            // Header
            headerSection

            Divider()

            // File conflict list
            conflictListSection

            Divider()

            // Remember checkbox
            rememberSection

            Divider()

            // Resolution buttons
            resolutionButtonsSection
        }
        .frame(minWidth: 560, idealWidth: 620, maxWidth: 720)
        .frame(minHeight: 480, idealHeight: 580, maxHeight: 700)
        .background(Color(NSColor.windowBackgroundColor))
    }

    // MARK: - Header

    private var headerSection: some View {
        VStack(spacing: 8) {
            HStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 32))
                    .foregroundColor(.orange)
                    .symbolRenderingMode(.multicolor)

                VStack(alignment: .leading, spacing: 4) {
                    Text("File Conflict Detected")
                        .font(.title2)
                        .fontWeight(.bold)

                    Text(conflictSummaryText)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }

                Spacer()
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 18)
    }

    private var conflictSummaryText: String {
        let count = conflictingFiles.count
        let noun = count == 1 ? "file already exists" : "files already exist"
        return "\(count) of \(totalFileCount) \(noun) at destination"
    }

    // MARK: - Conflict List

    private var conflictListSection: some View {
        ScrollView {
            LazyVStack(spacing: 1) {
                ForEach(conflictingFiles) { pair in
                    conflictRow(for: pair)
                }
            }
            .padding(.vertical, 4)
        }
        .frame(maxHeight: .infinity)
        .background(Color(NSColor.controlBackgroundColor))
    }

    private func conflictRow(for pair: ConflictingFilePair) -> some View {
        let isExpanded = expandedFileID == pair.id

        return VStack(spacing: 0) {
            // Summary row
            Button(action: {
                withAnimation(.easeInOut(duration: 0.2)) {
                    expandedFileID = isExpanded ? nil : pair.id
                }
            }) {
                HStack(spacing: 10) {
                    Image(systemName: fileIconName(for: pair.fileName))
                        .font(.title3)
                        .foregroundColor(.accentColor)
                        .frame(width: 24)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(pair.fileName)
                            .font(.system(.body, design: .default))
                            .fontWeight(.medium)
                            .lineLimit(1)
                            .truncationMode(.middle)

                        HStack(spacing: 12) {
                            if pair.sizesDiffer {
                                Label("Different sizes", systemImage: "exclamationmark.circle.fill")
                                    .font(.caption2)
                                    .foregroundColor(.orange)
                            } else {
                                Label("Same size", systemImage: "checkmark.circle.fill")
                                    .font(.caption2)
                                    .foregroundColor(.green)
                            }

                            if pair.sourceIsNewer {
                                Label("Source is newer", systemImage: "clock.arrow.circlepath")
                                    .font(.caption2)
                                    .foregroundColor(.blue)
                            }
                        }
                    }

                    Spacer()

                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            // Expanded detail
            if isExpanded {
                VStack(spacing: 8) {
                    fileComparisonRow(
                        label: "Source",
                        icon: "arrow.up.doc.fill",
                        iconColor: .blue,
                        path: pair.sourcePath,
                        size: pair.sourceSize,
                        date: pair.sourceDate
                    )
                    fileComparisonRow(
                        label: "Destination",
                        icon: "arrow.down.doc.fill",
                        iconColor: .orange,
                        path: pair.destinationPath,
                        size: pair.destinationSize,
                        date: pair.destinationDate
                    )
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 10)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isExpanded
                    ? Color(NSColor.selectedContentBackgroundColor).opacity(0.1)
                    : Color.clear)
        )
        .padding(.horizontal, 8)
    }

    private func fileComparisonRow(
        label: String,
        icon: String,
        iconColor: Color,
        path: String,
        size: Int64,
        date: Date
    ) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .foregroundColor(iconColor)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundColor(.secondary)

                Text(path)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                Text(formatBytes(size))
                    .font(.caption)
                    .fontWeight(.medium)
                    .monospacedDigit()

                Text(formatDate(date))
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color(NSColor.controlBackgroundColor))
        )
    }

    // MARK: - Remember Checkbox

    private var rememberSection: some View {
        HStack {
            Toggle(isOn: $rememberForBatch) {
                Text("Apply to all conflicts in this batch")
                    .font(.subheadline)
            }
            .toggleStyle(.checkbox)

            Spacer()

            Text("\(conflictingFiles.count) conflict\(conflictingFiles.count == 1 ? "" : "s")")
                .font(.caption)
                .foregroundColor(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    Capsule()
                        .fill(Color(NSColor.controlBackgroundColor))
                )
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
    }

    // MARK: - Resolution Buttons

    private var resolutionButtonsSection: some View {
        VStack(spacing: 8) {
            // Primary actions row
            HStack(spacing: 10) {
                resolutionButton(for: .overwrite)
                resolutionButton(for: .skip)
            }

            // Secondary actions row
            HStack(spacing: 10) {
                resolutionButton(for: .overwriteIfDifferent)
                resolutionButton(for: .skipIfSameSize)
            }

            // Cancel button (full width)
            resolutionButton(for: .cancel)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
    }

    private func resolutionButton(for option: ConflictResolution) -> some View {
        Button(action: {
            resolution = option
            dismiss()
        }) {
            HStack(spacing: 10) {
                Image(systemName: option.iconName)
                    .font(.title3)
                    .foregroundColor(option.iconColor)
                    .frame(width: 28)

                VStack(alignment: .leading, spacing: 2) {
                    Text(option.title)
                        .font(.system(.body, design: .default))
                        .fontWeight(.semibold)
                        .foregroundColor(option == .cancel ? .red : .primary)

                    Text(option.subtitle)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer()

                if option == .skipIfSameSize {
                    Image(systemName: "info.circle")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .help("This option is ideal for resuming interrupted transfers. Files with matching sizes are assumed complete and will be skipped.")
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(buttonBackgroundColor(for: option))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(buttonBorderColor(for: option), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
    }

    // MARK: - Helpers

    private func buttonBackgroundColor(for option: ConflictResolution) -> Color {
        switch option {
        case .cancel:
            return Color.red.opacity(0.08)
        default:
            return Color(NSColor.controlBackgroundColor)
        }
    }

    private func buttonBorderColor(for option: ConflictResolution) -> Color {
        switch option {
        case .cancel:
            return Color.red.opacity(0.3)
        default:
            return Color(NSColor.separatorColor).opacity(0.5)
        }
    }

    private func fileIconName(for fileName: String) -> String {
        let ext = (fileName as NSString).pathExtension.lowercased()
        switch ext {
        case "jpg", "jpeg", "png", "gif", "heic", "heif", "bmp", "tiff", "webp":
            return "photo.fill"
        case "mp4", "mov", "avi", "mkv", "m4v", "wmv":
            return "film.fill"
        case "mp3", "aac", "flac", "wav", "m4a", "ogg", "wma":
            return "music.note"
        case "pdf":
            return "doc.richtext.fill"
        case "zip", "gz", "tar", "rar", "7z":
            return "doc.zipper"
        case "txt", "md", "rtf":
            return "doc.text.fill"
        case "swift", "py", "js", "ts", "c", "h", "cpp", "java", "go", "rs":
            return "chevron.left.forwardslash.chevron.right"
        case "app":
            return "app.fill"
        default:
            return "doc.fill"
        }
    }

    private func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useAll]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }

    private func formatDate(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .shortened)
    }
}
