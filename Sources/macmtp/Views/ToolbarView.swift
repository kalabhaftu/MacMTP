import SwiftUI

struct ToolbarView: View {
    var isMTPConnected: Bool
    var deviceName: String
    var onRefresh: () -> Void
    var onCopy: () -> Void
    var onCut: () -> Void
    var onPaste: () -> Void
    var onDelete: () -> Void
    var onNewFolder: () -> Void
    var onSelectAll: () -> Void
    var hasClipboardContent: Bool
    var selectedCount: Int
    
    @State private var isRefreshing: Bool = false
    
    var body: some View {
        HStack(spacing: 0) {
            deviceStatusPanel
                .padding(.leading, 16)
            
            Spacer()
            
            fileOperationButtons
                .padding(.trailing, 16)
        }
        .frame(height: 56)
        .background(toolbarBackground)
    }
    
    
    private var deviceStatusPanel: some View {
        HStack(spacing: 10) {
            ZStack {
                Image(systemName: isMTPConnected ? "ipad.and.iphone" : "ipad.and.iphone.slash")
                    .font(.system(size: 22, weight: .medium))
                    .foregroundColor(isMTPConnected ? .green : .secondary)
                    .symbolEffect(.pulse, isActive: isMTPConnected)
                
                if isMTPConnected {
                    Circle()
                        .fill(.green)
                        .frame(width: 8, height: 8)
                        .offset(x: 14, y: -10)
                }
            }
            
            VStack(alignment: .leading, spacing: 2) {
                Text(isMTPConnected ? deviceName : "No Device Detected")
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                
                Text(isMTPConnected ? "Connected via USB" : "Connect your Android device via USB cable")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
        }
    }
    
    
    private var fileOperationButtons: some View {
        HStack(spacing: 6) {
            ToolbarButton(
                icon: "checkmark.circle",
                label: "Select All",
                shortcut: "⌘A",
                action: onSelectAll
            )
            
            ToolbarDivider()
            
            ToolbarButton(
                icon: "scissors",
                label: "Cut",
                shortcut: "⌘X",
                isEnabled: selectedCount > 0,
                action: onCut
            )
            
            ToolbarButton(
                icon: "doc.on.doc",
                label: "Copy",
                shortcut: "⌘C",
                isEnabled: selectedCount > 0,
                action: onCopy
            )
            
            ToolbarButton(
                icon: "doc.on.clipboard",
                label: "Paste",
                shortcut: "⌘V",
                action: onPaste
            )
            
            ToolbarDivider()
            
            ToolbarButton(
                icon: "trash",
                label: "Delete",
                shortcut: "⌘⌫",
                isEnabled: selectedCount > 0,
                isDestructive: true,
                action: onDelete
            )
            
            ToolbarButton(
                icon: "folder.badge.plus",
                label: "New Folder",
                shortcut: "⌘N",
                action: onNewFolder
            )
            
            ToolbarDivider()
            
            Button(action: {
                withAnimation(.easeInOut(duration: 0.3)) {
                    isRefreshing = true
                }
                onRefresh()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    isRefreshing = false
                }
            }) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 14, weight: .medium))
                    .rotationEffect(.degrees(isRefreshing ? 360 : 0))
                    .animation(.easeInOut(duration: 0.3), value: isRefreshing)
            }
            .buttonStyle(.plain)
            .help("Refresh directory listing (⌘R)")
            .frame(width: 30, height: 30)
            
            ToolbarDivider()
            
            Button(action: {
                if let appDelegate = NSApplication.shared.delegate as? AppDelegate {
                    appDelegate.perform(NSSelectorFromString("showPreferences"))
                }
            }) {
                Image(systemName: "gearshape")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(.accentColor)
            }
            .buttonStyle(.plain)
            .help("Preferences")
            .frame(width: 30, height: 30)

            Button(action: {
                if let appDelegate = NSApplication.shared.delegate as? AppDelegate {
                    appDelegate.perform(NSSelectorFromString("showAbout"))
                }
            }) {
                Image(systemName: "info.circle")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(.accentColor)
            }
            .buttonStyle(.plain)
            .help("About macMTP")
            .frame(width: 30, height: 30)
        }
    }
    
    
    private var toolbarBackground: some View {
        VStack(spacing: 0) {
            Color(NSColor.windowBackgroundColor)
            Divider()
        }
    }
}


struct ToolbarButton: View {
    let icon: String
    let label: String
    var shortcut: String = ""
    var isEnabled: Bool = true
    var isDestructive: Bool = false
    let action: () -> Void
    
    @State private var isHovered: Bool = false
    
    var body: some View {
        Button(action: {
            if isEnabled { action() }
        }) {
            VStack(spacing: 2) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(buttonColor)
                
                Text(label)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundColor(buttonColor)
            }
            .frame(width: 52, height: 40)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isHovered && isEnabled ? Color.primary.opacity(0.08) : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .help("\(label)\(shortcut.isEmpty ? "" : " (\(shortcut))")")
        .onHover { hovering in
            isHovered = hovering
        }
    }
    
    private var buttonColor: Color {
        if !isEnabled {
            return .secondary.opacity(0.5)
        }
        if isDestructive {
            return .red
        }
        return .primary
    }
}


struct ToolbarDivider: View {
    var body: some View {
        Divider()
            .frame(height: 24)
            .padding(.horizontal, 4)
    }
}
