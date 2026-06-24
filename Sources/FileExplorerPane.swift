import SwiftUI

struct FileNode: Identifiable, Hashable {
    var id: String { path }
    var name: String
    var path: String
    var isDirectory: Bool
    var size: Int64
    var extensionName: String
    var modificationDate: Date
}

struct FileExplorerPane: View {
    var title: String
    @Binding var currentPath: String
    @Binding var selectedItems: Set<String>
    var isLocal: Bool
    var isDisabled: Bool = false
    
    @State private var files: [FileNode] = []
    @State private var sortOrder = [KeyPathComparator(\FileNode.name)]
    @State private var pathHistory: [String] = []
    @State private var pathHistoryIndex: Int = -1
    
    // Keyboard search state
    @State private var keySearchBuffer: String = ""
    @State private var lastKeyTime: Date = Date.distantPast
    
    var body: some View {
        VStack(spacing: 0) {
            // Path and Navigation Header
            HStack(spacing: 8) {
                // Back button
                Button(action: navigateBack) {
                    Image(systemName: "chevron.left")
                }
                .disabled(pathHistoryIndex <= 0)
                
                // Forward button
                Button(action: navigateForward) {
                    Image(systemName: "chevron.right")
                }
                .disabled(pathHistoryIndex >= pathHistory.count - 1)
                
                // Parent Folder button
                Button(action: navigateUp) {
                    Image(systemName: "arrow.up")
                }
                .disabled(currentPath == "/" || currentPath == "")
                
                // Path string input
                TextField("Path", text: $currentPath, onCommit: {
                    loadDirectory()
                })
                .textFieldStyle(.roundedBorder)
            }
            .padding(8)
            .background(Color(NSColor.controlBackgroundColor))
            
            if isDisabled {
                VStack {
                    Spacer()
                    Text(isLocal ? "Local drive not accessible" : "Connect an Android device to view files")
                        .foregroundColor(.secondary)
                        .font(.body)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(NSColor.underPageBackgroundColor))
            } else {
                // File Explorer Native Table
                Table(files, selection: $selectedItems, sortOrder: $sortOrder) {
                    TableColumn("Name", value: \.name) { file in
                        HStack(spacing: 8) {
                            Image(systemName: file.isDirectory ? "folder.fill" : "doc.fill")
                                .foregroundColor(file.isDirectory ? .accentColor : .secondary)
                            Text(file.name)
                        }
                        .gesture(TapGesture(count: 2).onEnded {
                            if file.isDirectory {
                                navigateTo(path: file.path)
                            }
                        })
                    }
                    
                    TableColumn("Size", value: \.size) { file in
                        Text(file.isDirectory ? "--" : formatBytes(file.size))
                    }
                    .width(min: 60, max: 100)
                    
                    TableColumn("Type", value: \.extensionName)
                        .width(min: 60, max: 100)
                    
                    TableColumn("Date Modified", value: \.modificationDate) { file in
                        Text(formatDate(file.modificationDate))
                    }
                    .width(min: 120, max: 180)
                }
                .onChange(of: sortOrder) { newOrder in
                    files.sort(using: newOrder)
                }
                .background(
                    // Keyboard shortcut overlay for letter-selection
                    KeyboardShortcutHandler(onKeyPress: handleKeyPress)
                )
            }
        }
        .onAppear {
            if !isDisabled {
                navigateTo(path: currentPath)
            }
        }
        .onChange(of: currentPath) { newPath in
            if !isDisabled {
                loadDirectory()
            }
        }
        .onChange(of: isDisabled) { isDisconnected in
            if !isDisconnected {
                loadDirectory()
            }
        }
    }
    
    // Directory Loading & Navigation
    private func loadDirectory() {
        if isLocal {
            files = listLocalDirectory(path: currentPath)
            files.sort(using: sortOrder)
        } else {
            // Placeholder mock files for MTP pane until Go Kalam integration is complete
            files = [
                FileNode(name: "DCIM", path: currentPath + (currentPath == "/" ? "" : "/") + "DCIM", isDirectory: true, size: 0, extensionName: "Folder", modificationDate: Date()),
                FileNode(name: "Download", path: currentPath + (currentPath == "/" ? "" : "/") + "Download", isDirectory: true, size: 0, extensionName: "Folder", modificationDate: Date()),
                FileNode(name: "Movies", path: currentPath + (currentPath == "/" ? "" : "/") + "Movies", isDirectory: true, size: 0, extensionName: "Folder", modificationDate: Date()),
                FileNode(name: "Music", path: currentPath + (currentPath == "/" ? "" : "/") + "Music", isDirectory: true, size: 0, extensionName: "Folder", modificationDate: Date()),
                FileNode(name: "Pictures", path: currentPath + (currentPath == "/" ? "" : "/") + "Pictures", isDirectory: true, size: 0, extensionName: "Folder", modificationDate: Date()),
                FileNode(name: "system_report.log", path: currentPath + (currentPath == "/" ? "" : "/") + "system_report.log", isDirectory: false, size: 204850, extensionName: "LOG", modificationDate: Date())
            ]
            files.sort(using: sortOrder)
        }
    }
    
    private func navigateTo(path: String) {
        let cleanPath = (path == "") ? "/" : path
        
        // Update history
        if pathHistoryIndex < pathHistory.count - 1 {
            pathHistory.removeSubrange((pathHistoryIndex + 1)...)
        }
        pathHistory.append(cleanPath)
        pathHistoryIndex = pathHistory.count - 1
        
        currentPath = cleanPath
        loadDirectory()
    }
    
    private func navigateBack() {
        if pathHistoryIndex > 0 {
            pathHistoryIndex -= 1
            currentPath = pathHistory[pathHistoryIndex]
            loadDirectory()
        }
    }
    
    private func navigateForward() {
        if pathHistoryIndex < pathHistory.count - 1 {
            pathHistoryIndex += 1
            currentPath = pathHistory[pathHistoryIndex]
            loadDirectory()
        }
    }
    
    private func navigateUp() {
        let url = URL(fileURLWithPath: currentPath)
        let parentPath = url.deletingLastPathComponent().path
        if parentPath != currentPath {
            navigateTo(path: parentPath)
        }
    }
    
    // Local Filesystem scanner
    private func listLocalDirectory(path: String) -> [FileNode] {
        let url = URL(fileURLWithPath: path)
        var items: [FileNode] = []
        
        do {
            let contents = try FileManager.default.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles]
            )
            
            for itemUrl in contents {
                let resourceValues = try itemUrl.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey])
                let isDir = resourceValues.isDirectory ?? false
                let size = Int64(resourceValues.fileSize ?? 0)
                let date = resourceValues.contentModificationDate ?? Date()
                
                items.append(
                    FileNode(
                        name: itemUrl.lastPathComponent,
                        path: itemUrl.path,
                        isDirectory: isDir,
                        size: isDir ? 0 : size,
                        extensionName: isDir ? "Folder" : itemUrl.pathExtension.uppercased(),
                        modificationDate: date
                    )
                )
            }
        } catch {
            print("Error scanning directory \(path): \(error)")
        }
        
        return items
    }
    
    // Keyboard key selection search
    private func handleKeyPress(_ key: String) {
        guard !key.isEmpty, !files.isEmpty else { return }
        
        let now = Date()
        let timeDiff = now.timeIntervalSince(lastKeyTime)
        lastKeyTime = now
        
        let char = key.lowercased()
        
        // If pressed within 1 second, it cycles or appends
        if timeDiff < 1.0 && char == keySearchBuffer {
            // Cycle to the next file starting with this letter
            cycleSelection(startingWith: char)
        } else {
            // New search
            keySearchBuffer = char
            selectFirstMatch(startingWith: char)
        }
    }
    
    private func selectFirstMatch(startingWith prefix: String) {
        if let match = files.first(where: { $0.name.lowercased().hasPrefix(prefix) }) {
            selectedItems = [match.path]
        }
    }
    
    private func cycleSelection(startingWith char: String) {
        let matches = files.filter { $0.name.lowercased().hasPrefix(char) }
        guard !matches.isEmpty else { return }
        
        // Find currently selected matching index
        let selectedMatch = matches.first { selectedItems.contains($0.path) }
        
        if let current = selectedMatch, let currentIndex = matches.firstIndex(of: current) {
            let nextIndex = (currentIndex + 1) % matches.count
            selectedItems = [matches[nextIndex].path]
        } else {
            selectedItems = [matches[0].path]
        }
    }
    
    // Formatting utils
    private func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useAll]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
    
    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}

// Keyboard shortcuts tracking helper
struct KeyboardShortcutHandler: NSViewRepresentable {
    var onKeyPress: (String) -> Void
    
    class Coordinator: NSObject {
        var onKeyPress: (String) -> Void
        
        init(onKeyPress: @escaping (String) -> Void) {
            self.onKeyPress = onKeyPress
        }
        
        @objc func handleKeyDown(_ event: NSEvent) {
            if let chars = event.charactersIgnoringModifiers, !chars.isEmpty {
                onKeyPress(chars)
            }
        }
    }
    
    func makeCoordinator() -> Coordinator {
        return Coordinator(onKeyPress: onKeyPress)
    }
    
    func makeNSView(context: Context) -> NSView {
        let view = KeyInterceptingView()
        view.onKeyDown = context.coordinator.handleKeyDown
        return view
    }
    
    func updateNSView(_ nsView: NSView, context: Context) {}
}

class KeyInterceptingView: NSView {
    var onKeyDown: ((NSEvent) -> Void)?
    
    override var acceptsFirstResponder: Bool { true }
    
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
    }
    
    override func keyDown(with event: NSEvent) {
        if let onKeyDown = onKeyDown {
            onKeyDown(event)
        } else {
            super.keyDown(with: event)
        }
    }
}
