import SwiftUI

struct StatusView: View {
    var localPath: String
    var mtpPath: String
    var isMTPConnected: Bool
    
    @State private var localTotalSpace: String = "--"
    @State private var localFreeSpace: String = "--"
    
    var body: some View {
        HStack {
            // Local Pane Space Info
            HStack(spacing: 6) {
                Image(systemName: "laptopcomputer")
                    .foregroundColor(.secondary)
                Text("Mac Storage:")
                    .font(.caption)
                    .fontWeight(.semibold)
                Text("Free: \(localFreeSpace) / Total: \(localTotalSpace)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(.leading, 12)
            
            Spacer()
            
            Divider()
                .frame(height: 16)
            
            Spacer()
            
            // MTP Pane Space Info
            HStack(spacing: 6) {
                Image(systemName: "ipad.and.iphone")
                    .foregroundColor(isMTPConnected ? .green : .secondary)
                Text(isMTPConnected ? "Android Storage:" : "Android Disconnected")
                    .font(.caption)
                    .fontWeight(.semibold)
                
                if isMTPConnected {
                    Text("Free: 14.5 GB / Total: 64.0 GB")
                        .font(.caption)
                        .foregroundColor(.secondary)
                } else {
                    Text("--")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .padding(.trailing, 12)
        }
        .frame(height: 28)
        .background(Color(NSColor.windowBackgroundColor))
        .overlay(
            VStack {
                Divider()
                Spacer()
            }
        )
        .onAppear {
            refreshLocalStorageInfo()
        }
        .onChange(of: localPath) { _ in
            refreshLocalStorageInfo()
        }
    }
    
    private func refreshLocalStorageInfo() {
        let path = localPath.isEmpty ? "/" : localPath
        let url = URL(fileURLWithPath: path)
        
        do {
            let values = try url.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityKey])
            if let total = values.volumeTotalCapacity, let available = values.volumeAvailableCapacity {
                localTotalSpace = formatBytes(Int64(total))
                localFreeSpace = formatBytes(Int64(available))
            }
        } catch {
            print("Error reading disk capacity: \(error)")
        }
    }
    
    private func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useGB, .useTB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}
