import Foundation
import AppKit
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
func searchMatchesFileAndFolderNames() {
    let files = [
        file("Photos", isDirectory: true),
        file("holiday-photo.jpg"),
        file("notes.txt"),
    ]
    let options = FileBrowserOrganization(searchText: "photo")

    #expect(options.organize(files, showHidden: true).flatMap(\.files).map(\.name) == ["Photos", "holiday-photo.jpg"])
}

@Test
func searchHidesNonMatchingFoldersAndFiles() {
    let files = [
        file("Pictures", isDirectory: true),
        file("Music", isDirectory: true),
        file("notes.txt")
    ]

    let options = FileBrowserOrganization(searchText: "does-not-exist")

    #expect(options.organize(files, showHidden: true).flatMap(\.files).isEmpty)
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
func extensionGroupingProducesLabeledSections() {
    let files = [file("photo.jpg"), file("notes.txt"), file("README")]
    let options = FileBrowserOrganization(grouping: .extensionName)

    #expect(options.organize(files, showHidden: true).map(\.title) == ["No Extension", ".jpg", ".txt"])
    #expect(options.organize(files, showHidden: true).allSatisfy { !$0.title.isEmpty })
}

@Test
func selectionRangeUsesDisplayedOrderInEitherDirection() {
    let paths = ["a", "b", "c", "d"]
    #expect(FileSelectionRules.range(in: paths, from: "b", through: "d") == Set(["b", "c", "d"]))
    #expect(FileSelectionRules.range(in: paths, from: "d", through: "b") == Set(["b", "c", "d"]))
    #expect(FileSelectionRules.range(in: paths, from: "missing", through: "b") == nil)
}

@Test
func repeatedLetterTypeaheadCyclesMatchingItems() {
    let files = [file("nano"), file("nimo"), file("node")]
    let start = Date(timeIntervalSince1970: 1_700_000_000)

    let first = FileTypeaheadRules.advance(
        key: "n",
        files: files,
        selectedPath: nil,
        state: FileTypeaheadState(),
        now: start
    )
    let second = FileTypeaheadRules.advance(
        key: "n",
        files: files,
        selectedPath: first.selectedPath,
        state: first.state,
        now: start.addingTimeInterval(0.1)
    )

    #expect(first.selectedPath == "/nano")
    #expect(second.selectedPath == "/nimo")
}

@Test
func typeaheadBuildsQueriesAndFallsBackAfterNoMatch() {
    let files = [file("nano"), file("nimo"), file("alpha")]
    let start = Date(timeIntervalSince1970: 1_700_000_000)
    let n = FileTypeaheadRules.advance(
        key: "n",
        files: files,
        selectedPath: nil,
        state: FileTypeaheadState(),
        now: start
    )
    let ni = FileTypeaheadRules.advance(
        key: "i",
        files: files,
        selectedPath: n.selectedPath,
        state: n.state,
        now: start.addingTimeInterval(0.1)
    )
    let noMatch = FileTypeaheadRules.advance(
        key: "x",
        files: files,
        selectedPath: ni.selectedPath,
        state: ni.state,
        now: start.addingTimeInterval(0.2)
    )
    let afterTimeout = FileTypeaheadRules.advance(
        key: "a",
        files: files,
        selectedPath: nil,
        state: noMatch.state,
        now: start.addingTimeInterval(2.0)
    )

    #expect(ni.state.query == "ni")
    #expect(ni.selectedPath == "/nimo")
    #expect(noMatch.selectedPath == nil)
    #expect(noMatch.state.query == "x")
    #expect(afterTimeout.selectedPath == "/alpha")
}

@Test
func iconGridReservesStableCellsForWrappedNames() {
    #expect(FileGridLayout.cellHeight(large: false) > FileGridLayout.labelHeight(large: false))
    #expect(FileGridLayout.cellHeight(large: true) > FileGridLayout.labelHeight(large: true))
    #expect(FileGridLayout.columnCount(containerWidth: 640, large: false) == 7)
    #expect(FileGridLayout.columnCount(containerWidth: 640, large: true) == 6)
}

@Test @MainActor
func appKitBrowserUsesContentRevisionToSkipUnrelatedScans() {
    #expect(FileBrowserHostView.contentRevisionChanged(previous: nil, current: 1))
    #expect(!FileBrowserHostView.contentRevisionChanged(previous: 1, current: 1))
    #expect(FileBrowserHostView.contentRevisionChanged(previous: 1, current: 2))
}

@Test @MainActor
func appKitBrowserHostUsesTheNativeDefaultCoordinateSystem() {
    #expect(FileBrowserHostView().isFlipped == NSView().isFlipped)
}

@Test @MainActor
func tableCellInstallsItsStackBeforeActivatingConstraints() {
    let cell = AppKitFileTableCellView(frame: .zero)

    #expect(cell.subviews.count == 1)
}

@Test @MainActor
func iconCellInstallsItsStackBeforeActivatingConstraints() {
    let cell = AppKitFileCellView(frame: .zero)

    #expect(cell.subviews.count == 1)
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
func fileListStatusSummaryCountsVisibleAndSelectedItems() {
    let files = (0..<10_000).map { index in
        FileNode(
            name: index.isMultiple(of: 10) ? ".hidden-\(index)" : "file-\(index)",
            path: "/root/\(index)",
            isDirectory: index.isMultiple(of: 5),
            size: Int64(index + 1)
        )
    }
    let selectedPaths: Set<String> = ["/root/1", "/root/5", "/root/10"]

    let visibleOnly = FileListStatusSummary.make(
        from: files,
        showHidden: false,
        selectedPaths: selectedPaths
    )
    #expect(visibleOnly.visibleItemCount == 9_000)
    #expect(visibleOnly.directory.bytes == 40_008_000)
    #expect(visibleOnly.directory.folderCount == 1_000)
    #expect(visibleOnly.directory.fileCount == 8_000)
    #expect(visibleOnly.selected.folderCount == 1)
    #expect(visibleOnly.selected.fileCount == 1)
    #expect(visibleOnly.selected.bytes == 2)

    let includingHidden = FileListStatusSummary.make(
        from: files,
        showHidden: true,
        selectedPaths: selectedPaths
    )
    #expect(includingHidden.visibleItemCount == 10_000)
    #expect(includingHidden.directory.bytes == 40_008_000)
    #expect(includingHidden.directory.folderCount == 2_000)
    #expect(includingHidden.directory.fileCount == 8_000)
    #expect(includingHidden.selected.folderCount == 2)
    #expect(includingHidden.selected.fileCount == 1)
    #expect(includingHidden.selected.bytes == 2)
}

@Test
func fileListStatusSummaryClampsNegativeSizesAndSaturatesOnOverflow() {
    let files = [
        FileNode(name: "negative", path: "/root/negative", isDirectory: false, size: -5),
        FileNode(name: "large", path: "/root/large", isDirectory: false, size: Int64.max),
        FileNode(name: "overflow", path: "/root/overflow", isDirectory: false, size: 1),
    ]

    let summary = FileListStatusSummary.make(
        from: files,
        showHidden: true,
        selectedPaths: Set(files.map(\.path))
    )

    #expect(summary.visibleItemCount == 3)
    #expect(summary.directory.fileCount == 3)
    #expect(summary.directory.bytes == Int64.max)
    #expect(summary.selected.fileCount == 3)
    #expect(summary.selected.bytes == Int64.max)
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
