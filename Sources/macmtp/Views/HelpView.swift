import SwiftUI

struct HelpView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Group {
                    Text("Getting Started").font(.title2).fontWeight(.bold)

                    Text("""
                    Connect your Android device via USB and select File Transfer (MTP) on the device.
                    """)
                    .font(.body)

                    helpRow(icon: "sidebar.left", title: "Browse Files",
                            detail: "Use the sidebar to navigate local volumes and your MTP device (positionable on Left or Right in Preferences). Files are shown in a sortable table.")
                    helpRow(icon: "arrow.left.arrow.right", title: "Transfer Files",
                            detail: "Select files, then use Copy (⌘C) and Paste (⌘V) to transfer between your Mac and Android device.")
                    helpRow(icon: "rectangle.on.rectangle", title: "Drag & Drop",
                            detail: "Drag files from Finder into macMTP, or drag files between the local and MTP panes.")
                    helpRow(icon: "trash", title: "Delete",
                            detail: "Select files and press ⌘⌫ to delete. Local files are moved to Trash.")
                    helpRow(icon: "folder.badge.plus", title: "New Folder",
                            detail: "Press ⌘N to create a new folder in the current directory.")

                }

                Divider()

                Group {
                    Text("Keyboard Shortcuts").font(.title2).fontWeight(.bold)

                    shortcutRow("⌘C", "Copy")
                    shortcutRow("⌘X", "Cut")
                    shortcutRow("⌘V", "Paste")
                    shortcutRow("⌘A", "Select All")
                    shortcutRow("⌘N", "New Folder")
                    shortcutRow("⌘R", "Refresh")
                    shortcutRow("⌘⌫", "Delete")
                    shortcutRow("⌘,", "Preferences")
                }

                Divider()

                Group {
                    Text("Troubleshooting").font(.title2).fontWeight(.bold)

                    Text("""
                    • If your device is not detected, try reconnecting the USB cable.
                    • Make sure your device is unlocked and USB file transfer mode is selected.
                    • If transfers fail, try restarting both the app and your device.
                    • If macOS reports that another app has claimed the device, close Image Capture, Preview, or other photo-import apps and reconnect it.
                    """)
                    .font(.body)
                }
            }
            .padding()
        }
    }

    private func helpRow(icon: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundColor(.accentColor)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).fontWeight(.semibold)
                Text(detail).font(.caption).foregroundColor(.secondary)
            }
        }
    }

    private func shortcutRow(_ shortcut: String, _ description: String) -> some View {
        HStack {
            Text(shortcut)
                .font(.system(.body, design: .monospaced))
                .fontWeight(.medium)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color(NSColor.controlBackgroundColor))
                .cornerRadius(4)
            Text(description)
                .font(.body)
            Spacer()
        }
    }
}
