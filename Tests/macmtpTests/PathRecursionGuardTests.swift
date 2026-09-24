import Testing
import Foundation
@testable import macmtp

@Suite("Path Recursion & Cycle Guard Tests")
struct PathRecursionGuardTests {

    @Test
    func testSelfOrDescendantDetection() {
        // Exact same path
        #expect(PathValidation.isSelfOrDescendant(sourcePath: "/Users/alice/Documents/folderA", destinationPath: "/Users/alice/Documents/folderA"))

        // Immediate child
        #expect(PathValidation.isSelfOrDescendant(sourcePath: "/Users/alice/Documents/folderA", destinationPath: "/Users/alice/Documents/folderA/subfolder"))

        // Deep child
        #expect(PathValidation.isSelfOrDescendant(sourcePath: "/Users/alice/Documents/folderA", destinationPath: "/Users/alice/Documents/folderA/subfolder/level2/level3"))

        // Sibling folder (allowed)
        #expect(!PathValidation.isSelfOrDescendant(sourcePath: "/Users/alice/Documents/folderA", destinationPath: "/Users/alice/Documents/folderB"))

        // Parent folder (allowed)
        #expect(!PathValidation.isSelfOrDescendant(sourcePath: "/Users/alice/Documents/folderA", destinationPath: "/Users/alice/Documents"))

        // Completely different hierarchy
        #expect(!PathValidation.isSelfOrDescendant(sourcePath: "/Users/alice/Documents/folderA", destinationPath: "/Users/alice/Downloads"))
    }

    @Test
    func testAlreadyInDirectoryDetection() {
        #expect(PathValidation.isAlreadyInDirectory(sourcePath: "/Users/alice/Documents/folderA/file.jpg", destinationDir: "/Users/alice/Documents/folderA"))
        #expect(!PathValidation.isAlreadyInDirectory(sourcePath: "/Users/alice/Documents/folderA/file.jpg", destinationDir: "/Users/alice/Documents"))
    }

    @Test
    func testIsSafeToTransfer() {
        // Dropping into itself -> unsafe
        let selfDrop = PathValidation.isSafeToTransfer(sourcePath: "/Users/alice/folder", destinationDir: "/Users/alice/folder")
        #expect(!selfDrop.isSafe)

        // Dropping into subfolder -> unsafe
        let subDrop = PathValidation.isSafeToTransfer(sourcePath: "/Users/alice/folder", destinationDir: "/Users/alice/folder/sub")
        #expect(!subDrop.isSafe)

        // Dropping into its current parent -> not safe (already in folder)
        let parentDrop = PathValidation.isSafeToTransfer(sourcePath: "/Users/alice/folder", destinationDir: "/Users/alice")
        #expect(!parentDrop.isSafe)

        // Dropping into different folder -> safe
        let otherDrop = PathValidation.isSafeToTransfer(sourcePath: "/Users/alice/folder", destinationDir: "/Users/alice/Downloads")
        #expect(otherDrop.isSafe)
    }

    @Test
    func testPathCycleAndExcessiveDepthDetection() {
        // Normal paths
        #expect(!PathValidation.hasPathCycleOrExcessiveDepth(relativePath: "folder/subfolder/image.png"))
        #expect(!PathValidation.hasPathCycleOrExcessiveDepth(relativePath: "photos/2026/vacation/pic.jpg"))

        // Cycle: same folder name repeated > 2 times
        let cyclicPath = "untitled folder/untitled folder/untitled folder/pic.jpg"
        #expect(PathValidation.hasPathCycleOrExcessiveDepth(relativePath: cyclicPath))

        // Excessive depth (> 30 levels)
        let deepComponents = (1...35).map { "level\($0)" }
        let deepPath = deepComponents.joined(separator: "/")
        #expect(PathValidation.hasPathCycleOrExcessiveDepth(relativePath: deepPath))
    }

    @Test
    func testFinderFavoritesResolver() {
        let favorites = FinderFavoritesResolver.resolveFavorites()
        #expect(!favorites.isEmpty)
        // Home item should be present
        #expect(favorites.contains(where: { $0.id == "home" }))
        // All items should have valid non-empty paths
        for fav in favorites {
            #expect(!fav.path.isEmpty)
            #expect(!fav.name.isEmpty)
            #expect(!fav.iconName.isEmpty)
        }
    }

    @Test
    func applicationsFavoriteUsesGridIcon() {
        #expect(FinderFavoritesResolver.iconForPath(url: URL(fileURLWithPath: "/Applications")) == "square.grid.2x2.fill")
    }
}
