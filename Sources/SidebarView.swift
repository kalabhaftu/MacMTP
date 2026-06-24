import SwiftUI

struct SidebarItem: Identifiable, Hashable {
    var id: String
    var name: String
    var iconName: String
    var path: String
    var isVolume: Bool
}

struct SidebarView: View {
    @Binding var selectedItem: String?
    @Binding var currentLocalPath: String
    
    @State private var volumes: [SidebarItem] = []
    
    let quickLinks = [
        SidebarItem(id: "home", name: "Home", iconName: "house", path: FileManager.default.homeDirectoryForCurrentUser.path, isVolume: false),
        SidebarItem(id: "desktop", name: "Desktop", iconName: "desktopcomputer", path: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop").path, isVolume: false),
        SidebarItem(id: "downloads", name: "Downloads", iconName: "arrow.down.circle", path: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads").path, isVolume: false),
        SidebarItem(id: "documents", name: "Documents", iconName: "doc.text", path: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents").path, isVolume: false)
    ]
    
    var body: some View {
        List(selection: $selectedItem) {
            Section(header: Text("Favorites")) {
                ForEach(quickLinks) { item in
                    NavigationLink(value: item.id) {
                        Label(item.name, systemImage: item.iconName)
                    }
                }
            }
            
            Section(header: Text("Locations")) {
                ForEach(volumes) { volume in
                    NavigationLink(value: volume.id) {
                        Label(volume.name, systemImage: volume.iconName)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .onAppear {
            refreshVolumes()
        }
        .onChange(of: selectedItem) { newItem in
            if let newItem = newItem {
                if let matched = quickLinks.first(where: { $0.id == newItem }) {
                    currentLocalPath = matched.path
                } else if let matched = volumes.first(where: { $0.id == newItem }) {
                    currentLocalPath = matched.path
                }
            }
        }
    }
    
    private func refreshVolumes() {
        var detectedVolumes: [SidebarItem] = []
        
        // Always add System Volume
        detectedVolumes.append(
            SidebarItem(
                id: "macintosh_hd",
                name: "Macintosh HD",
                iconName: "harddrive",
                path: "/",
                isVolume: true
            )
        )
        
        let keys: [URLResourceKey] = [.volumeNameKey, .volumeIsRemovableKey, .volumeIsInternalKey]
        
        if let volumeURLs = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) {
            for url in volumeURLs {
                // Skip the root system volume since we already added it explicitly
                if url.path == "/" { continue }
                
                var volumeName: AnyObject?
                var isRemovable: AnyObject?
                
                do {
                    try (url as NSURL).getResourceValue(&volumeName, forKey: .volumeNameKey)
                    try (url as NSURL).getResourceValue(&isRemovable, forKey: .volumeIsRemovableKey)
                    
                    let name = (volumeName as? String) ?? url.lastPathComponent
                    let removable = (isRemovable as? Bool) ?? true
                    let icon = removable ? "externaldrive" : "harddrive"
                    
                    detectedVolumes.append(
                        SidebarItem(
                            id: url.path,
                            name: name,
                            iconName: icon,
                            path: url.path,
                            isVolume: true
                        )
                    )
                } catch {
                    print("Error getting resource values for volume \(url): \(error)")
                }
            }
        }
        
        self.volumes = detectedVolumes
    }
}
