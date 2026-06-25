import SwiftUI

/// current item counts, and transfer status at a glance.
struct StatusView: View {
    var localPath: String
    var mtpPath: String
    var isMTPConnected: Bool
    var localItemCount: Int = 0
    var localSelectedCount: Int = 0
    var localSelectedSize: Int64 = 0
    var localDirSize: Int64 = 0
    var mtpItemCount: Int = 0
    var mtpSelectedCount: Int = 0
    var mtpSelectedSize: Int64 = 0
    var mtpDirSize: Int64 = 0
    var isTransferring: Bool = false
    var transferProgress: Double = 0
    var transferFileName: String = ""
    var mtpTotalBytes: Int64 = 0
    var mtpFreeBytes: Int64 = 0
    
    @State private var localTotalBytes: Int64 = 0
    @State private var localFreeBytes: Int64 = 0
    
    var body: some View {
        HStack(spacing: 0) {
            // ── Local Pane Status ──
            localStatusPanel
                .frame(maxWidth: .infinity)
            
            Divider()
                .frame(height: 16)
            
            // ── Transfer Status (if active) ──
            if isTransferring {
                transferStatusPanel
                    .frame(width: 200)
                
                Divider()
                    .frame(height: 16)
            }
            
            // ── MTP Pane Status ──
            mtpStatusPanel
                .frame(maxWidth: .infinity)
        }
        .frame(height: 28)
        .background(Color(NSColor.windowBackgroundColor))
        .overlay(alignment: .top) {
            Divider()
        }
        .onAppear {
            refreshLocalStorageInfo()
        }
        .onChange(of: localPath) { _, _ in
            refreshLocalStorageInfo()
        }
    }
    
    // MARK: - Local Status Panel
    
    private var localStatusPanel: some View {
        HStack(spacing: 8) {
            Image(systemName: "laptopcomputer")
                .font(.system(size: 11))
                .foregroundColor(.secondary)

            // Item count + size info
            VStack(alignment: .leading, spacing: 0) {
                Text(itemCountText(total: localItemCount, selected: localSelectedCount))
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                if localSelectedCount > 0 {
                    Text("\(formatBytes(localSelectedSize)) selected")
                        .font(.system(size: 9))
                        .foregroundColor(.accentColor)
                } else {
                    Text("\(formatBytes(localDirSize)) total")
                        .font(.system(size: 9))
                        .foregroundColor(.secondary.opacity(0.7))
                }
            }

            Spacer()

            // Disk capacity
            HStack(spacing: 4) {
                // Mini capacity bar
                capacityBar(free: localFreeBytes, total: localTotalBytes)

                Text("\(formatBytes(localFreeBytes)) free")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.secondary)
            }
        }
        .padding(.horizontal, 12)
    }
    
    // MARK: - MTP Status Panel
    
    private var mtpStatusPanel: some View {
        HStack(spacing: 8) {
            // Disk capacity
            if isMTPConnected {
                HStack(spacing: 4) {
                    Text("\(formatBytes(mtpFreeBytes)) free")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.secondary)

                    capacityBar(free: mtpFreeBytes, total: mtpTotalBytes)
                }
            }

            Spacer()

            // Item count + size info
            if isMTPConnected {
                VStack(alignment: .trailing, spacing: 0) {
                    Text(itemCountText(total: mtpItemCount, selected: mtpSelectedCount))
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                    if mtpSelectedCount > 0 {
                        Text("\(formatBytes(mtpSelectedSize)) selected")
                            .font(.system(size: 9))
                            .foregroundColor(.accentColor)
                    } else {
                        Text("\(formatBytes(mtpDirSize)) total")
                            .font(.system(size: 9))
                            .foregroundColor(.secondary.opacity(0.7))
                    }
                }
            } else {
                Text("No device connected")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }

            Image(systemName: isMTPConnected ? "ipad.and.iphone" : "ipad.and.iphone.slash")
                .font(.system(size: 11))
                .foregroundColor(isMTPConnected ? .green : .secondary)
        }
        .padding(.horizontal, 12)
    }
    
    // MARK: - Transfer Status Panel
    
    private var transferStatusPanel: some View {
        HStack(spacing: 6) {
            ProgressView(value: transferProgress)
                .progressViewStyle(.linear)
                .frame(width: 80)
            
            Text(transferFileName)
                .font(.system(size: 10))
                .foregroundColor(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            
            Text("\(Int(transferProgress * 100))%")
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundColor(.accentColor)
        }
        .padding(.horizontal, 8)
    }
    
    // MARK: - Capacity Bar
    
    private func capacityBar(free: Int64, total: Int64) -> some View {
        let ratio: Double
        if total > 0 {
            let used = Double(total - free)
            ratio = max(0, min(1, used / Double(total)))
        } else {
            ratio = 0
        }
        return RoundedRectangle(cornerRadius: 2)
            .fill(Color.secondary.opacity(0.2))
            .frame(width: 40, height: 4)
            .overlay(alignment: .leading) {
                GeometryReader { geo in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.accentColor.opacity(0.7))
                        .frame(width: geo.size.width * CGFloat(ratio), height: 4)
                }
            }
    }
    
    // MARK: - Helpers
    
    private func itemCountText(total: Int, selected: Int) -> String {
        if selected > 0 {
            return "\(total) items (\(selected) selected)"
        }
        return "\(total) items"
    }
    
    private func refreshLocalStorageInfo() {
        let path = localPath.isEmpty ? "/" : localPath
        let url = URL(fileURLWithPath: path)
        
        do {
            let values = try url.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityKey])
            if let total = values.volumeTotalCapacity, let available = values.volumeAvailableCapacity {
                localTotalBytes = Int64(total)
                localFreeBytes = Int64(available)
            }
        } catch {
            print("[StatusView] Error reading disk capacity for \(path): \(error)")
        }
    }
    
    private func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useGB, .useTB, .useMB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}
