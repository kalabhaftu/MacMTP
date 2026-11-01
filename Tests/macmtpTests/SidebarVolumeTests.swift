import Foundation
import Testing
@testable import macmtp

@Test @MainActor
func sidebarVolumeDiscoveryRunsOffMainThread() async {
    let result = await discoverSidebarVolumesOffMain {
        [SidebarItem(
            id: Thread.isMainThread ? "main" : "background",
            name: "Test volume",
            iconName: "externaldrive.fill",
            path: "/",
            isVolume: true
        )]
    }

    #expect(result.first?.id == "background")
}
