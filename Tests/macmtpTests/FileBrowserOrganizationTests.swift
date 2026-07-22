import Foundation
import Testing
@testable import macmtp

private let referenceDate = Date(timeIntervalSince1970: 1_700_000_000)

private func file(
    _ name: String,
    size: Int64 = 0,
    isDirectory: Bool = false
) -> FileNode {
    FileNode(
        name: name,
        path: "/\(name)",
        isDirectory: isDirectory,
        size: size,
        modificationDate: referenceDate
    )
}

@Test
func searchMatchesFileNamesAndKeepsFoldersNavigable() {
    let files = [
        file("Photos", isDirectory: true),
        file("holiday-photo.jpg"),
        file("notes.txt"),
    ]
    let options = FileBrowserOrganization(searchText: "photo")

    #expect(options.organize(files, showHidden: true).flatMap(\.files).map(\.name) == ["Photos", "holiday-photo.jpg"])
}

@Test
func extensionFilterIsIndependentFromNameSearch() {
    let files = [file("alpha.jpg"), file("alpha.png"), file("beta.jpg")]
    let options = FileBrowserOrganization(searchText: "alpha", extensionFilter: "jpg")

    #expect(options.organize(files, showHidden: true).flatMap(\.files).map(\.name) == ["alpha.jpg"])
}

@Test
func sizeSortingKeepsFoldersFirstAndSortsDirectFiles() {
    let files = [
        file("Folder", isDirectory: true),
        file("large.bin", size: 100),
        file("small.bin", size: 10),
    ]
    let options = FileBrowserOrganization(sortColumn: .size)

    #expect(options.organize(files, showHidden: true).flatMap(\.files).map(\.name) == ["Folder", "small.bin", "large.bin"])
}

@Test
func foldersStayFirstForEverySortColumnAndDirection() {
    let files = [
        file("aaa.txt", size: 1),
        file("zzz", size: 999, isDirectory: true),
    ]

    for column in FileSortColumn.allCases {
        for direction in FileSortDirection.allCases {
            let options = FileBrowserOrganization(sortColumn: column, sortDirection: direction)
            #expect(options.organize(files, showHidden: true).flatMap(\.files).first?.isDirectory == true)
        }
    }
}

@Test
func kindGroupingProducesStableFinderStyleCategories() {
    let files = [file("clip.mp4"), file("photo.heic"), file("archive.zip")]
    let options = FileBrowserOrganization(grouping: .kind)

    #expect(options.organize(files, showHidden: true).map(\.title) == ["Images", "Videos", "Archives"])
}

@Test
func selectionRangeUsesDisplayedOrderInEitherDirection() {
    let paths = ["a", "b", "c", "d"]
    #expect(FileSelectionRules.range(in: paths, from: "b", through: "d") == Set(["b", "c", "d"]))
    #expect(FileSelectionRules.range(in: paths, from: "d", through: "b") == Set(["b", "c", "d"]))
    #expect(FileSelectionRules.range(in: paths, from: "missing", through: "b") == nil)
}

@Test
func directSizeSummaryNeverTraversesOrCountsFolderPlaceholders() {
    let files = [
        file("Folder", size: 999, isDirectory: true),
        file("one.bin", size: 10),
        file("two.bin", size: 20),
    ]

    let summary = FileSizeSummary.directItems(in: files)

    #expect(summary == FileSizeSummary(bytes: 30, fileCount: 2, folderCount: 1))
}

@Test
func selectedSizeSummaryReportsFolderOnlySelectionsWithoutFakeZeroByteFolders() {
    let files = [file("Folder", isDirectory: true), file("one.bin", size: 10)]

    let summary = FileSizeSummary.directItems(in: files, selectedPaths: ["/Folder"])

    #expect(summary == FileSizeSummary(bytes: 0, fileCount: 0, folderCount: 1))
}

@Test
func updateProgressIsDeterminateOnlyWithExpectedBytes() {
    #expect(UpdateDownloadState.downloading(received: 50, expected: nil).progress == nil)
    #expect(UpdateDownloadState.downloading(received: 50, expected: 100).progress == 0.5)
    #expect(UpdateDownloadState.downloading(received: 150, expected: 100).progress == 1)
}

@Test
func updateIsReadyOnlyAfterAStagedArtifactExistsInState() {
    let artifact = URL(fileURLWithPath: "/tmp/macMTP-test.dmg")
    #expect(UpdateDownloadState.idle != .readyToInstall(artifact))
    #expect(UpdateDownloadState.readyToInstall(artifact) == .readyToInstall(artifact))
}
