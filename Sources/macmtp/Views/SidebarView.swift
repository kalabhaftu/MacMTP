import SwiftUI

// MARK: - Sidebar Data Model

struct SidebarItem: Identifiable, Hashable {
    var id: String
    var name: String
    var iconName: String
    var path: String
    var isVolume: Bool
    var isRemovable: Bool = false
    var isEjectable: Bool = false
    var totalCapacity: Int64 = 0
    var freeSpace: Int64 = 0
}

// MARK: - Sidebar Section Type

enum SidebarSection: String, CaseIterable {
    case favorites = "Favorites"
    case locations = "Locations"
    case mtpDevice = "Android Device"
}

// MARK: - Sidebar View

/// mounted volumes (Macintosh HD, external drives, USB disks, DMGs), and
struct SidebarView: View {
    @Binding var selectedItem: String?
    @Binding var currentLocalPath: String
    
    // MTP device integration
    var isMTPConnected: Bool = false
    var mtpDeviceName: String = ""
    var mtpStorages: [MTPStorageInfo] = []
    var onMTPStorageSelected: ((UInt32) -> Void)? = nil
    
    @State private var volumes: [SidebarItem] = []
    @State private var refreshTimer: Timer? = nil
    
    // MARK: - Quick Links (Favorites)
    
    private var quickLinks: [SidebarItem] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [
            SidebarItem(
                id: "home",
                name: "Home",
                iconName: "house.fill",
                path: home.path,
                isVolume: false
            ),
            SidebarItem(
                id: "desktop",
                name: "Desktop",
                iconName: "menubar.dock.rectangle",
                path: home.appendingPathComponent("Desktop").path,
                isVolume: false
            ),
            SidebarItem(
                id: "downloads",
                name: "Downloads",
                iconName: "arrow.down.circle.fill",
                path: home.appendingPathComponent("Downloads").path,
                isVolume: false
            ),
            SidebarItem(
                id: "documents",
                name: "Documents",
                iconName: "doc.text.fill",
                path: home.appendingPathComponent("Documents").path,
                isVolume: false
            ),
            SidebarItem(
                id: "movies",
                name: "Movies",
                iconName: "film.fill",
                path: home.appendingPathComponent("Movies").path,
                isVolume: false
            ),
            SidebarItem(
                id: "music",
                name: "Music",
                iconName: "music.note.list",
                path: home.appendingPathComponent("Music").path,
                isVolume: false
            ),
            SidebarItem(
                id: "pictures",
                name: "Pictures",
                iconName: "photo.fill.on.rectangle.fill",
                path: home.appendingPathComponent("Pictures").path,
                isVolume: false
            ),
        ]
    }
    
    // MARK: - Body
    
    var body: some View {
        List(selection: $selectedItem) {
            // ── Favorites Section ──
            Section(header: sectionHeader("Favorites", icon: "star.fill")) {
                ForEach(quickLinks) { item in
                    sidebarRow(item: item)
                }
            }
            
            // ── Locations Section (Volumes) ──
            Section(header: sectionHeader("Locations", icon: "externaldrive.fill")) {
                ForEach(volumes) { volume in
                    sidebarRow(item: volume)
                }
            }
            
            // ── MTP Device Section ──
            if isMTPConnected {
                Section(header: sectionHeader("Android Device", icon: "ipad.and.iphone")) {
                    // Device header row
                    HStack(spacing: 8) {
                        Image(systemName: "ipad.and.iphone")
                            .foregroundColor(.green)
                            .font(.system(size: 14))
                        Text(mtpDeviceName)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(.primary)
                    }
                    .padding(.vertical, 2)
                    
                    // Storage entries
                    ForEach(mtpStorages) { storage in
                        Button(action: {
                            onMTPStorageSelected?(storage.storageId)
                        }) {
                            HStack(spacing: 8) {
                                Image(systemName: storageIcon(for: storage))
                                    .foregroundColor(.accentColor)
                                    .font(.system(size: 13))
                                
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(storage.description)
                                        .font(.system(size: 12))
                                        .lineLimit(1)
                                    
                                    // Storage usage bar
                                    GeometryReader { geo in
                                        ZStack(alignment: .leading) {
                                            RoundedRectangle(cornerRadius: 2)
                                                .fill(Color.secondary.opacity(0.2))
                                                .frame(height: 4)
                                            
                                            RoundedRectangle(cornerRadius: 2)
                                                .fill(storageBarColor(percent: storage.usagePercent * 100.0))
                                                .frame(width: geo.size.width * CGFloat(storage.usagePercent), height: 4)
                                        }
                                    }
                                    .frame(height: 4)
                                    
                                    Text("\(storage.formattedFree) free of \(storage.formattedTotal)")
                                        .font(.system(size: 10))
                                        .foregroundColor(.secondary)
                                }
                            }
                            .padding(.vertical, 4)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .onAppear {
            refreshVolumes()
            startVolumeRefreshTimer()
        }
        .onDisappear {
            stopVolumeRefreshTimer()
        }
        .onChange(of: selectedItem) { _, newItem in
            handleSelection(newItem)
        }
    }
    
    // MARK: - Sidebar Row
    
    private func sidebarRow(item: SidebarItem) -> some View {
        HStack(spacing: 8) {
            Image(systemName: item.iconName)
                .foregroundColor(item.isVolume ? .orange : .accentColor)
                .font(.system(size: 13))
            
            VStack(alignment: .leading, spacing: 1) {
                Text(item.name)
                    .font(.system(size: 12))
                    .lineLimit(1)
                
                // Show capacity for volumes
                if item.isVolume && item.totalCapacity > 0 {
                    Text("\(formatBytes(item.freeSpace)) free")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
            }
            
            Spacer()
            
            // Eject button for removable volumes
            if item.isEjectable {
                Button(action: {
                    ejectVolume(path: item.path)
                }) {
                    Image(systemName: "eject.fill")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .help("Eject \(item.name)")
            }
        }
        .padding(.vertical, 2)
        .tag(item.id)
    }
    
    // MARK: - Section Header
    
    private func sectionHeader(_ title: String, icon: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 9))
            Text(title)
                .font(.system(size: 11, weight: .semibold))
        }
        .foregroundColor(.secondary)
    }
    
    // MARK: - Volume Discovery
    
    private func refreshVolumes() {
        var detectedVolumes: [SidebarItem] = []
        
        // Always add System Volume (Macintosh HD)
        let systemCapacity = getVolumeCapacity(path: "/")
        detectedVolumes.append(
            SidebarItem(
                id: "macintosh_hd",
                name: getSystemVolumeName(),
                iconName: "internaldrive.fill",
                path: "/",
                isVolume: true,
                totalCapacity: systemCapacity.total,
                freeSpace: systemCapacity.free
            )
        )
        
        // Discover all mounted volumes
        let keys: [URLResourceKey] = [
            .volumeNameKey,
            .volumeIsRemovableKey,
            .volumeIsInternalKey,
            .volumeIsEjectableKey,
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityKey,
            .volumeIsReadOnlyKey,
        ]
        
        if let volumeURLs = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: keys,
            options: [.skipHiddenVolumes]
        ) {
            for url in volumeURLs {
                // Skip the root system volume (already added)
                if url.path == "/" { continue }
                // Skip system volumes like /System, /Library, etc.
                if url.path.hasPrefix("/System") { continue }
                
                do {
                    let resourceValues = try url.resourceValues(forKeys: Set(keys))
                    let name = resourceValues.volumeName ?? url.lastPathComponent
                    let isRemovable = resourceValues.volumeIsRemovable ?? false
                    let isInternal = resourceValues.volumeIsInternal ?? true
                    let isEjectable = resourceValues.volumeIsEjectable ?? false
                    let totalCapacity = Int64(resourceValues.volumeTotalCapacity ?? 0)
                    let freeSpace = Int64(resourceValues.volumeAvailableCapacity ?? 0)
                    
                    // Determine icon
                    let icon: String
                    if isRemovable {
                        icon = "externaldrive.fill"
                    } else if !isInternal {
                        icon = "externaldrive.connected.to.line.below.fill"
                    } else {
                        icon = "internaldrive.fill"
                    }
                    
                    detectedVolumes.append(
                        SidebarItem(
                            id: url.path,
                            name: name,
                            iconName: icon,
                            path: url.path,
                            isVolume: true,
                            isRemovable: isRemovable,
                            isEjectable: isEjectable,
                            totalCapacity: totalCapacity,
                            freeSpace: freeSpace
                        )
                    )
                } catch {
                    print("[SidebarView] Error reading volume properties for \(url): \(error)")
                }
            }
        }
        
        self.volumes = detectedVolumes
    }
    
    // MARK: - Handle Selection
    
    private func handleSelection(_ itemId: String?) {
        guard let itemId = itemId else { return }
        
        // Check quick links
        if let matched = quickLinks.first(where: { $0.id == itemId }) {
            currentLocalPath = matched.path
            return
        }
        
        // Check volumes
        if let matched = volumes.first(where: { $0.id == itemId }) {
            currentLocalPath = matched.path
            return
        }
    }
    
    // MARK: - Volume Refresh Timer
    
    private func startVolumeRefreshTimer() {
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { _ in
            Task { @MainActor in
                refreshVolumes()
            }
        }
    }
    
    private func stopVolumeRefreshTimer() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }
    
    // MARK: - Helpers
    
    private func getSystemVolumeName() -> String {
        let url = URL(fileURLWithPath: "/")
        if let name = try? url.resourceValues(forKeys: [.volumeNameKey]).volumeName {
            return name
        }
        return "Macintosh HD"
    }
    
    private func getVolumeCapacity(path: String) -> (total: Int64, free: Int64) {
        let url = URL(fileURLWithPath: path)
        do {
            let values = try url.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityKey])
            let total = Int64(values.volumeTotalCapacity ?? 0)
            let free = Int64(values.volumeAvailableCapacity ?? 0)
            return (total, free)
        } catch {
            return (0, 0)
        }
    }
    
    private func storageIcon(for storage: MTPStorageInfo) -> String {
        switch storage.storageType {
        case .sdCard:
            return "sdcard.fill"
        case .internal:
            return "internaldrive.fill"
        case .unknown:
            return "externaldrive.fill"
        }
    }
    
    private func storageBarColor(percent: Double) -> Color {
        if percent > 90 { return .red }
        if percent > 75 { return .orange }
        return .accentColor
    }
    
    private func ejectVolume(path: String) {
        let url = URL(fileURLWithPath: path)
        try? NSWorkspace.shared.unmountAndEjectDevice(at: url)
        refreshVolumes()
    }
    
    private func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useGB, .useTB, .useMB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}
