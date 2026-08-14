import Testing
@testable import macmtp

@Test @MainActor
func clipboardPreservesSelectedFilesAndFoldersForPaste() {
    let clipboard = ClipboardManager.shared
    let items = [
        FileNode(name: "photo.jpg", path: "/photo.jpg"),
        FileNode(name: "Albums", path: "/Albums", isDirectory: true)
    ]
    defer { clipboard.clear() }

    clipboard.copyItems(items: items, from: "/", isLocal: true)

    #expect(clipboard.hasContent)
    #expect(clipboard.items.map(\.path) == ["/photo.jpg", "/Albums"])
    #expect(clipboard.sourceIsLocal)
    #expect(clipboard.sourcePath == "/")
}
