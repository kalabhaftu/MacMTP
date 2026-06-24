import SwiftUI

struct ContentView: View {
    // State for local navigation
    @State private var currentLocalPath: String = FileManager.default.homeDirectoryForCurrentUser.path
    @State private var selectedLocalItems: Set<String> = []
    
    // State for MTP navigation
    @State private var currentMTPPath: String = "/"
    @State private var selectedMTPItems: Set<String> = []
    @State private var isMTPDeviceConnected: Bool = false
    @State private var connectedDeviceName: String = "No Device Connected"
    
    // Sidebar selection
    @State private var selectedSidebarItem: String? = "home"
    
    var body: some View {
        VStack(spacing: 0) {
            // Toolbar Area
            ToolbarView(
                isMTPConnected: isMTPDeviceConnected,
                deviceName: connectedDeviceName,
                onRefresh: {
                    // Refresh current directories
                }
            )
            
            // Main Split Pane
            HSplitView {
                // Left Sidebar
                SidebarView(
                    selectedItem: $selectedSidebarItem,
                    currentLocalPath: $currentLocalPath
                )
                .frame(minWidth: 150, idealWidth: 200, maxWidth: 300)
                .layoutPriority(0)
                
                // Double Pane File Explorer
                HSplitView {
                    // Local Pane (Left Pane)
                    FileExplorerPane(
                        title: "Local Files",
                        currentPath: $currentLocalPath,
                        selectedItems: $selectedLocalItems,
                        isLocal: true
                    )
                    .frame(minWidth: 300, idealWidth: 400)
                    .layoutPriority(1)
                    
                    // MTP Pane (Right Pane)
                    FileExplorerPane(
                        title: isMTPDeviceConnected ? connectedDeviceName : "MTP Device",
                        currentPath: $currentMTPPath,
                        selectedItems: $selectedMTPItems,
                        isLocal: false,
                        isDisabled: !isMTPDeviceConnected
                    )
                    .frame(minWidth: 300, idealWidth: 400)
                    .layoutPriority(1)
                }
            }
            
            // Bottom Status Bar
            StatusView(
                localPath: currentLocalPath,
                mtpPath: currentMTPPath,
                isMTPConnected: isMTPDeviceConnected
            )
        }
        .frame(minWidth: 800, minHeight: 500)
    }
}
