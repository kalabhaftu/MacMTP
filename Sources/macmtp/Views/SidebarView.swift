import SwiftUI


public struct SidebarItem: Identifiable, Hashable {
    public var id: String
    public var name: String
    public var iconName: String
    public var path: String
    public var isVolume: Bool
    public var isRemovable: Bool = false
    public var isEjectable: Bool = false
    public var totalCapacity: Int64 = 0
    public var freeSpace: Int64 = 0

    public init(
        id: String,
        name: String,
        iconName: String,
        path: String,
        isVolume: Bool,
        isRemovable: Bool = false,
        isEjectable: Bool = false,
        totalCapacity: Int64 = 0,
        freeSpace: Int64 = 0
    ) {
        self.id = id
        self.name = name
        self.iconName = iconName
        self.path = path
        self.isVolume = isVolume
        self.isRemovable = isRemovable
        self.isEjectable = isEjectable
        self.totalCapacity = totalCapacity
        self.freeSpace = freeSpace
    }
}


enum SidebarSection: String, CaseIterable {
    case favorites = "Favorites"
    case locations = "Locations"
    case mtpDevice = "Android Device"
}


struct SidebarView: View {
    @AppStorage("appFontScale") private var appFontScale: Double = 1.0
    @Binding var selectedItem: String?
    @Binding var currentLocalPath: String
    
    var isMTPConnected: Bool = false
    var mtpDeviceName: String = ""
    var mtpStorages: [MTPStorageInfo] = []
    var onMTPStorageSelected: ((UInt32) -> Void)? = nil
    
    @State private var quickLinks: [SidebarItem] = FinderFavoritesResolver.resolveFavorites()
    @State private var volumes: [SidebarItem] = []
    @State private var refreshTimer: Timer? = nil
    
    
    var body: some View {
        List(selection: $selectedItem) {
            Section(header: sectionHeader("Favorites", icon: "star.fill")) {
                ForEach(quickLinks) { item in
                    sidebarRow(item: item)
                }
            }
            
            Section(header: sectionHeader("Locations", icon: "externaldrive.fill")) {
                ForEach(volumes) { volume in
                    sidebarRow(item: volume)
                }
            }
            
            if isMTPConnected {
                let deviceSectionTitle = mtpDeviceName.isEmpty ? "Android Device" : mtpDeviceName
                Section(header: sectionHeader(deviceSectionTitle, icon: "ipad.and.iphone")) {
                    ForEach(mtpStorages) { storage in
                        Button(action: {
                            onMTPStorageSelected?(storage.storageId)
                        }) {
                            HStack(spacing: 8) {
                                Image(systemName: storageIcon(for: storage))
                                    .foregroundColor(.accentColor)
                                    .font(.system(size: 13 * appFontScale))
                                
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(storage.description)
                                        .font(.system(size: 12 * appFontScale))
                                        .lineLimit(1)
                                    
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
                                        .font(.system(size: 10 * appFontScale))
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
            refreshFavorites()
            refreshVolumes()
            syncSelection(with: currentLocalPath)
            startVolumeRefreshTimer()
        }
        .onDisappear {
            stopVolumeRefreshTimer()
        }
        .onChange(of: selectedItem) { _, newItem in
            handleSelection(newItem)
        }
        .onChange(of: currentLocalPath) { _, newPath in
            syncSelection(with: newPath)
        }
    }
    
    
    private func sidebarRow(item: SidebarItem) -> some View {
        HStack(spacing: 8) {
            Image(systemName: item.iconName)
                .foregroundColor(item.isVolume ? .orange : .accentColor)
                .font(.system(size: 13 * appFontScale))
            
            VStack(alignment: .leading, spacing: 1) {
                Text(item.name)
                    .font(.system(size: 12 * appFontScale))
                    .lineLimit(1)
                
                if item.isVolume && item.totalCapacity > 0 {
                    Text("\(formatBytes(item.freeSpace)) free")
                        .font(.system(size: 10 * appFontScale))
                        .foregroundColor(.secondary)
                }
            }
            
            Spacer()
            
            if item.isEjectable {
                Button(action: {
                    ejectVolume(path: item.path)
                }) {
                    Image(systemName: "eject.fill")
                        .font(.system(size: 10 * appFontScale))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .help("Eject \(item.name)")
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onTapGesture {
            selectedItem = item.id
            currentLocalPath = item.path
        }
        .tag(item.id)
    }
    
    
    private func sectionHeader(_ title: String, icon: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 9 * appFontScale))
            Text(title)
                .font(.system(size: 11 * appFontScale, weight: .semibold))
        }
        .foregroundColor(.secondary)
    }
    
    
    private func refreshVolumes() {
        var detectedVolumes: [SidebarItem] = []
        
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
                if url.path == "/" { continue }
                if url.path.hasPrefix("/System") { continue }
                
                do {
                    let resourceValues = try url.resourceValues(forKeys: Set(keys))
                    let name = resourceValues.volumeName ?? url.lastPathComponent
                    let isRemovable = resourceValues.volumeIsRemovable ?? false
                    let isInternal = resourceValues.volumeIsInternal ?? true
                    let isEjectable = resourceValues.volumeIsEjectable ?? false
                    let totalCapacity = Int64(resourceValues.volumeTotalCapacity ?? 0)
                    let freeSpace = Int64(resourceValues.volumeAvailableCapacity ?? 0)
                    
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
                }
            }
        }
        
        self.volumes = detectedVolumes
    }
    
    
    private func handleSelection(_ itemId: String?) {
        guard let itemId = itemId else { return }
        
        if let matched = quickLinks.first(where: { $0.id == itemId }) {
            currentLocalPath = matched.path
            return
        }
        
        if let matched = volumes.first(where: { $0.id == itemId }) {
            currentLocalPath = matched.path
            return
        }
    }

    private func syncSelection(with path: String) {
        if let matched = quickLinks.first(where: { $0.path == path }) {
            if selectedItem != matched.id {
                selectedItem = matched.id
            }
        } else if let matched = volumes.first(where: { $0.path == path }) {
            if selectedItem != matched.id {
                selectedItem = matched.id
            }
        } else {
            selectedItem = nil
        }
    }
    
    
    private func refreshFavorites() {
        let updated = FinderFavoritesResolver.resolveFavorites()
        if updated != quickLinks {
            quickLinks = updated
        }
    }

    private func startVolumeRefreshTimer() {
        guard refreshTimer == nil else { return }
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { _ in
            Task { @MainActor in
                refreshFavorites()
                refreshVolumes()
            }
        }
    }
    
    private func stopVolumeRefreshTimer() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }
    
    
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
