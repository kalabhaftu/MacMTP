import Foundation

struct MTPDirectoryRefreshKey: Hashable, Sendable {
    let storageId: UInt32
    let path: String
    let showHidden: Bool
}

struct MTPDirectorySnapshot: Equatable, Sendable {
    let key: MTPDirectoryRefreshKey
    let files: [FileNode]
}

enum MTPRefreshRules {
    static func sharesRequest(active: MTPDirectoryRefreshKey?, requested: MTPDirectoryRefreshKey) -> Bool {
        active == requested
    }
}

enum MTPDirectoryMutation: Equatable, Sendable {
    case create(FileNode)
    case rename(oldPath: String, newPath: String)
    case delete(paths: Set<String>)
}

extension MTPDirectoryMutation {
    var operationName: String {
        switch self {
        case .create: return "make_directory"
        case .rename: return "rename_file"
        case .delete: return "delete_files"
        }
    }
}

enum MTPDirectoryReconciliation {
    static func isSatisfied(_ mutation: MTPDirectoryMutation, by files: [FileNode]) -> Bool {
        let paths = Set(files.map(\.path))
        switch mutation {
        case .create(let file):
            return paths.contains(file.path)
        case .rename(let oldPath, let newPath):
            return paths.contains(newPath) && !paths.contains(oldPath)
        case .delete(let deletedPaths):
            return deletedPaths.isDisjoint(with: paths)
        }
    }

    static func applying(_ mutation: MTPDirectoryMutation, to files: [FileNode]) -> [FileNode] {
        switch mutation {
        case .create(let file):
            guard !files.contains(where: { $0.path == file.path }) else { return files }
            return files + [file]
        case .rename(let oldPath, let newPath):
            return files.map { file in
                guard file.path == oldPath else { return file }
                let name = (newPath as NSString).lastPathComponent
                let parentPath = (newPath as NSString).deletingLastPathComponent
                return FileNode(
                    name: name,
                    path: newPath,
                    parentPath: parentPath,
                    isDirectory: file.isDirectory,
                    size: file.size,
                    modificationDate: file.modificationDate,
                    objectId: file.objectId,
                    parentId: file.parentId,
                    isSelected: file.isSelected
                )
            }
        case .delete(let deletedPaths):
            return files.filter { !deletedPaths.contains($0.path) }
        }
    }
}

enum MTPDirectoryPreflight {
    static func destinationExists(
        in snapshot: MTPDirectorySnapshot,
        path: String,
        excluding excludedPath: String? = nil
    ) -> Bool {
        snapshot.files.contains { $0.path == path && $0.path != excludedPath }
    }
}

@MainActor
final class MTPDirectoryCoordinator {
    private(set) var activeRefreshRequest: MTPDirectoryRefreshKey?
    private(set) var activeRefreshWaiterCount = 0
    private var refreshWaiters: [CheckedContinuation<Void, Never>] = []
    private var mutationInFlight = false
    private var mutationWaiters: [CheckedContinuation<Void, Never>] = []
    private var snapshots: [MTPDirectoryRefreshKey: MTPDirectorySnapshot] = [:]
    private(set) var snapshot: MTPDirectorySnapshot?
    private var activeRefreshResult: Bool?
    private var lastRefreshResult: (key: MTPDirectoryRefreshKey, succeeded: Bool)?

    func waitForMutation() async {
        guard mutationInFlight else { return }
        await withCheckedContinuation { continuation in
            mutationWaiters.append(continuation)
        }
    }

    func beginMutation() async {
        await waitForMutation()
        mutationInFlight = true
    }

    func endMutation() {
        mutationInFlight = false
        let waiters = mutationWaiters
        mutationWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    func beginRefresh(for request: MTPDirectoryRefreshKey) -> Bool {
        guard activeRefreshRequest == nil else { return false }
        activeRefreshRequest = request
        activeRefreshWaiterCount = 0
        activeRefreshResult = nil
        return true
    }

    func waitForActiveRefresh() async {
        activeRefreshWaiterCount += 1
        await withCheckedContinuation { continuation in
            refreshWaiters.append(continuation)
        }
    }

    func finishRefresh(for request: MTPDirectoryRefreshKey) {
        guard activeRefreshRequest == request else { return }
        activeRefreshRequest = nil
        lastRefreshResult = (request, activeRefreshResult == true)
        activeRefreshResult = nil
        let waiters = refreshWaiters
        refreshWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    func recordSuccessfulListing(_ files: [FileNode], for key: MTPDirectoryRefreshKey) {
        let snapshot = MTPDirectorySnapshot(key: key, files: files)
        snapshots[key] = snapshot
        self.snapshot = snapshot
        activeRefreshResult = true
    }

    func recordFailedRefresh(for key: MTPDirectoryRefreshKey) {
        guard activeRefreshRequest == key else { return }
        activeRefreshResult = false
    }

    func refreshSucceeded(for key: MTPDirectoryRefreshKey) -> Bool {
        lastRefreshResult?.key == key && lastRefreshResult?.succeeded == true
    }

    func snapshot(for key: MTPDirectoryRefreshKey) -> MTPDirectorySnapshot? {
        snapshots[key]
    }

    func invalidateSnapshot(for key: MTPDirectoryRefreshKey? = nil) {
        if let key {
            snapshots.removeValue(forKey: key)
            if snapshot?.key == key { snapshot = nil }
        } else {
            snapshots.removeAll()
            snapshot = nil
        }
        if key == nil || lastRefreshResult?.key == key {
            lastRefreshResult = nil
        }
    }
}
