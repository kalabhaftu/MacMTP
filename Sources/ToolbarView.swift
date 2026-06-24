import SwiftUI

struct ToolbarView: View {
    var isMTPConnected: Bool
    var deviceName: String
    var onRefresh: () -> Void
    
    var body: some View {
        HStack {
            // Device Status Info
            HStack(spacing: 8) {
                Image(systemName: isMTPConnected ? "ipad.and.iphone" : "ipad.and.iphone.slash")
                    .font(.title3)
                    .foregroundColor(isMTPConnected ? .green : .secondary)
                
                VStack(alignment: .leading, spacing: 2) {
                    Text(isMTPConnected ? deviceName : "No Device Detected")
                        .font(.headline)
                    Text(isMTPConnected ? "Connected via USB" : "Please connect your Android device")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .padding(.leading, 12)
            
            Spacer()
            
            // Operations
            HStack(spacing: 12) {
                Button(action: {}) {
                    Label("Cut", systemImage: "scissors")
                }
                .buttonStyle(.plain)
                .help("Cut selected files (Cmd + X)")
                
                Button(action: {}) {
                    Label("Copy", systemImage: "doc.on.doc")
                }
                .buttonStyle(.plain)
                .help("Copy selected files (Cmd + C)")
                
                Button(action: {}) {
                    Label("Paste", systemImage: "doc.on.clipboard")
                }
                .buttonStyle(.plain)
                .help("Paste files (Cmd + V)")
                
                Button(action: {}) {
                    Label("Delete", systemImage: "trash")
                }
                .buttonStyle(.plain)
                .help("Delete selected files (Cmd + Delete)")
                
                Button(action: {}) {
                    Label("New Folder", systemImage: "folder.badge.plus")
                }
                .buttonStyle(.plain)
                .help("Create new folder")
                
                Divider()
                    .frame(height: 20)
                
                Button(action: onRefresh) {
                    Image(systemName: "arrow.clockwise")
                        .font(.body)
                }
                .buttonStyle(.plain)
                .help("Refresh directory listing")
            }
            .padding(.trailing, 12)
        }
        .frame(height: 52)
        .background(Color(NSColor.windowBackgroundColor))
        .overlay(
            VStack {
                Spacer()
                Divider()
            }
        )
    }
}
