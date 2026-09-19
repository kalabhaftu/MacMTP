import Foundation

public struct FinderFavoritesResolver {
    public static let sflPath = ("~/Library/Application Support/com.apple.sharedfilelist/com.apple.LSSharedFileList.FavoriteItems.sfl3" as NSString).expandingTildeInPath

    public static func resolveFavorites(customSflPath: String? = nil) -> [SidebarItem] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let homeItem = SidebarItem(
            id: "home",
            name: "Home",
            iconName: "house.fill",
            path: home.path,
            isVolume: false
        )

        let resolvedItems = parseSFL(path: customSflPath ?? sflPath)
        if !resolvedItems.isEmpty {
            if resolvedItems.contains(where: { $0.path == home.path }) {
                return resolvedItems
            } else {
                return [homeItem] + resolvedItems
            }
        }

        return defaultFallbackFavorites()
    }

    public static func parseSFL(path: String) -> [SidebarItem] {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let unarchiver = try? NSKeyedUnarchiver(forReadingFrom: data) else {
            return []
        }
        unarchiver.requiresSecureCoding = false
        guard let dict = unarchiver.decodeObject(forKey: "root") as? NSDictionary,
              let rawItems = dict["items"] as? [NSDictionary] else {
            return []
        }

        var results: [SidebarItem] = []
        var seenPaths: Set<String> = []

        for item in rawItems {
            guard let bookmark = item["Bookmark"] as? Data else { continue }
            var isStale = false
            guard let url = try? URL(resolvingBookmarkData: bookmark, options: .withoutUI, relativeTo: nil, bookmarkDataIsStale: &isStale),
                  !url.path.isEmpty,
                  FileManager.default.fileExists(atPath: url.path) else {
                continue
            }

            let path = url.path
            guard !seenPaths.contains(path) else { continue }
            seenPaths.insert(path)

            let name = FileManager.default.displayName(atPath: path)
            let icon = iconForPath(url: url)
            results.append(SidebarItem(
                id: "fav_\(path)",
                name: name,
                iconName: icon,
                path: path,
                isVolume: false
            ))
        }

        return results
    }

    public static func iconForPath(url: URL) -> String {
        let name = url.lastPathComponent.lowercased()
        switch name {
        case "desktop":
            return "menubar.dock.rectangle"
        case "downloads":
            return "arrow.down.circle.fill"
        case "documents":
            return "doc.text.fill"
        case "movies":
            return "film.fill"
        case "music":
            return "music.note.list"
        case "pictures":
            return "photo.fill.on.rectangle.fill"
        case "applications":
            return "app.fill"
        default:
            return "folder.fill"
        }
    }

    public static func defaultFallbackFavorites() -> [SidebarItem] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [
            SidebarItem(id: "home", name: "Home", iconName: "house.fill", path: home.path, isVolume: false),
            SidebarItem(id: "desktop", name: "Desktop", iconName: "menubar.dock.rectangle", path: home.appendingPathComponent("Desktop").path, isVolume: false),
            SidebarItem(id: "downloads", name: "Downloads", iconName: "arrow.down.circle.fill", path: home.appendingPathComponent("Downloads").path, isVolume: false),
            SidebarItem(id: "documents", name: "Documents", iconName: "doc.text.fill", path: home.appendingPathComponent("Documents").path, isVolume: false),
            SidebarItem(id: "movies", name: "Movies", iconName: "film.fill", path: home.appendingPathComponent("Movies").path, isVolume: false),
            SidebarItem(id: "music", name: "Music", iconName: "music.note.list", path: home.appendingPathComponent("Music").path, isVolume: false),
            SidebarItem(id: "pictures", name: "Pictures", iconName: "photo.fill.on.rectangle.fill", path: home.appendingPathComponent("Pictures").path, isVolume: false),
        ]
    }
}
