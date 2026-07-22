import Foundation
import AppKit

enum UpdateDownloadState: Equatable {
    case idle
    case downloading(received: Int64, expected: Int64?)
    case readyToInstall(URL)
    case failed(String)

    var progress: Double? {
        guard case let .downloading(received, expected?) = self, expected > 0 else { return nil }
        return min(1, max(0, Double(received) / Double(expected)))
    }
}

@MainActor
public final class UpdaterService: ObservableObject, @unchecked Sendable {
    public static let shared = UpdaterService()
    
    private let repoURL = "https://api.github.com/repos/kalabhaftu/MacMTP/releases/latest"
    private var activeDownload: UpdateDownloadCoordinator?
    @Published private(set) var downloadState: UpdateDownloadState = .idle
    
    private init() {}
    
    public func checkForUpdates(silent: Bool = false) {
        Task {
            do {
                guard let url = URL(string: repoURL) else { return }
                var request = URLRequest(url: url)
                request.setValue("application/vnd.github.v3+json", forHTTPHeaderField: "Accept")
                request.timeoutInterval = 10
                
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let httpResp = response as? HTTPURLResponse, httpResp.statusCode == 200 else {
                    let status = (response as? HTTPURLResponse)?.statusCode ?? -1
                    ErrorLogger.logMessage("Failed to fetch update info. HTTP Status: \(status)")
                    if !silent { showNoUpdateAlert(message: "Failed to fetch update information from GitHub.") }
                    return
                }
                
                if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let tagName = json["tag_name"] as? String,
                   let htmlUrlString = json["html_url"] as? String,
                   let htmlUrl = URL(string: htmlUrlString) {
                    
                    let releaseBody = (json["body"] as? String) ?? "No release notes available."
                    
                    let remoteVersion = normalizedVersion(tagName)
                    let localVersion = normalizedVersion(AppVersion.current)
                    
                    let assets = json["assets"] as? [[String: Any]] ?? []
                    let dmgAsset = assets.first { ($0["name"] as? String ?? "").hasSuffix("-universal.dmg") } ??
                                   assets.first { ($0["name"] as? String ?? "").hasSuffix(".dmg") }
                    let dmgDownloadUrlString = dmgAsset?["browser_download_url"] as? String
                    
                    if remoteVersion.compare(localVersion, options: .numeric) == .orderedDescending {
                        let autoDownload = UserDefaults.standard.object(forKey: "autoDownloadUpdates") as? Bool ?? false
                        if autoDownload,
                           let dmgUrlStr = dmgDownloadUrlString,
                           let dmgUrl = URL(string: dmgUrlStr),
                           dmgUrl.scheme == "https" {
                            downloadAndOpenDMG(url: dmgUrl, version: tagName)
                        } else {
                            showUpdateAlert(version: tagName, releaseNotes: releaseBody, url: htmlUrl)
                        }
                    } else {
                        if !silent { showNoUpdateAlert(message: "You are running the latest version of macMTP (\(AppVersion.current)).") }
                    }
                } else {
                    ErrorLogger.logMessage("Failed to parse update info from GitHub response payload.")
                    if !silent { showNoUpdateAlert(message: "Failed to parse update information.") }
                }
            } catch {
                ErrorLogger.log(error, message: "Error checking for updates")
                if !silent { showNoUpdateAlert(message: "Error checking for updates: \(error.localizedDescription)") }
            }
        }
    }
    
    private func downloadAndOpenDMG(url: URL, version: String) {
        guard activeDownload == nil else { return }
        guard let parentWindow = NSApp.keyWindow ?? NSApp.mainWindow else {
            showNoUpdateAlert(message: "Unable to show the update download window.")
            return
        }

        let alert = NSAlert()
        alert.messageText = "Downloading Update..."
        alert.informativeText = "Preparing version \(version)…"
        alert.alertStyle = .informational
        
        let progress = NSProgressIndicator(frame: NSRect(x: 0, y: 0, width: 200, height: 20))
        progress.isIndeterminate = true
        progress.minValue = 0
        progress.maxValue = 1
        progress.doubleValue = 0
        progress.startAnimation(nil)
        alert.accessoryView = progress
        
        _ = alert.addButton(withTitle: "Cancel")

        let safeVersion = version.replacingOccurrences(of: "/", with: "-")
        let coordinator = UpdateDownloadCoordinator(
            progress: { fraction, received, expected in
                self.downloadState = .downloading(received: received, expected: expected > 0 ? expected : nil)
                if expected > 0 {
                    if progress.isIndeterminate {
                        progress.stopAnimation(nil)
                        progress.isIndeterminate = false
                    }
                    progress.doubleValue = fraction
                    alert.informativeText = "Downloading version \(version): \(FormatUtils.formatBytes(received)) of \(FormatUtils.formatBytes(expected))"
                } else {
                    if !progress.isIndeterminate {
                        progress.isIndeterminate = true
                        progress.startAnimation(nil)
                    }
                    alert.informativeText = "Downloading version \(version): \(FormatUtils.formatBytes(received))"
                }
            },
            completion: { [weak self, weak parentWindow] result in
                guard let self else { return }
                self.activeDownload = nil
                if let parentWindow, parentWindow.attachedSheet === alert.window {
                    parentWindow.endSheet(alert.window)
                }
                switch result {
                case .success(let destination):
                    self.downloadState = .readyToInstall(destination)
                    progress.stopAnimation(nil)
                    progress.isIndeterminate = false
                    progress.doubleValue = 1
                    let finishAlert = NSAlert()
                    finishAlert.messageText = "Download Complete"
                    finishAlert.informativeText = "The update finished downloading. Open it now, then drag macMTP to Applications to update."
                    finishAlert.addButton(withTitle: "Open Installer")
                    finishAlert.addButton(withTitle: "Later")
                    if let parentWindow {
                        finishAlert.beginSheetModal(for: parentWindow) { response in
                            if response == .alertFirstButtonReturn {
                                NSWorkspace.shared.open(destination)
                            }
                        }
                    }
                case .failure(let error as URLError) where error.code == .cancelled:
                    self.downloadState = .idle
                    break
                case .failure(let error):
                    self.downloadState = .failed(error.localizedDescription)
                    ErrorLogger.log(error, message: "Download update error")
                    let errorAlert = NSAlert()
                    errorAlert.messageText = "Update Download Failed"
                    errorAlert.informativeText = error.localizedDescription
                    errorAlert.alertStyle = .warning
                    errorAlert.addButton(withTitle: "OK")
                    if let parentWindow {
                        errorAlert.beginSheetModal(for: parentWindow)
                    }
                }
            }
        )
        activeDownload = coordinator
        downloadState = .downloading(received: 0, expected: nil)

        alert.beginSheetModal(for: parentWindow) { [weak self, weak coordinator] response in
            if response == .alertFirstButtonReturn, self?.activeDownload === coordinator {
                coordinator?.cancel()
            }
        }
        coordinator.start(url: url, destinationFileName: "macMTP-\(safeVersion).dmg")
    }
    
    private func showUpdateAlert(version: String, releaseNotes: String, url: URL) {
        let alert = NSAlert()
        alert.messageText = "A new version of macMTP is available!"
        alert.informativeText = "Version \(version) is now available. You are running version \(AppVersion.current).\n\nRelease Notes:\n\(releaseNotes)"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Download")
        alert.addButton(withTitle: "Cancel")
        
        let accessory = NSTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 150))
        accessory.string = releaseNotes
        accessory.isEditable = false
        accessory.drawsBackground = false
        accessory.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        
        let scroll = NSScrollView(frame: accessory.frame)
        scroll.documentView = accessory
        scroll.hasVerticalScroller = true
        alert.accessoryView = scroll
        
        alert.informativeText = "Version \(version) is now available. You are running version \(AppVersion.current)."
        
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            NSWorkspace.shared.open(url)
        }
    }
    
    private func showNoUpdateAlert(message: String) {
        let alert = NSAlert()
        alert.messageText = "Check for Updates"
        alert.informativeText = message
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func normalizedVersion(_ version: String) -> String {
        version.hasPrefix("v") ? String(version.dropFirst()) : version
    }
}

private final class UpdateDownloadCoordinator: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let progressHandler: @MainActor (Double, Int64, Int64) -> Void
    private let completionHandler: @MainActor (Result<URL, Error>) -> Void
    private var session: URLSession?
    private var destinationFileName = "macMTP-update.dmg"
    private var downloadedURL: URL?
    private var terminalError: Error?

    init(
        progress: @escaping @MainActor (Double, Int64, Int64) -> Void,
        completion: @escaping @MainActor (Result<URL, Error>) -> Void
    ) {
        self.progressHandler = progress
        self.completionHandler = completion
    }

    func start(url: URL, destinationFileName: String) {
        self.destinationFileName = destinationFileName
        var request = URLRequest(url: url)
        request.setValue("macMTP/\(AppVersion.current)", forHTTPHeaderField: "User-Agent")
        let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        self.session = session
        session.downloadTask(with: request).resume()
    }

    func cancel() {
        session?.invalidateAndCancel()
        session = nil
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        let fraction = totalBytesExpectedToWrite > 0
            ? min(1, Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
            : 0
        Task { @MainActor in
            progressHandler(fraction, totalBytesWritten, totalBytesExpectedToWrite)
        }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        do {
            guard let response = downloadTask.response as? HTTPURLResponse,
                  (200..<300).contains(response.statusCode) else {
                throw URLError(.badServerResponse)
            }
            let stagingDirectory = FileManager.default.temporaryDirectory
                .appendingPathComponent("macMTP", isDirectory: true)
                .appendingPathComponent("Updates", isDirectory: true)
            try FileManager.default.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)
            let destination = stagingDirectory.appendingPathComponent(destinationFileName)
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.moveItem(at: location, to: destination)
            let attributes = try FileManager.default.attributesOfItem(atPath: destination.path)
            let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
            guard destination.pathExtension.lowercased() == "dmg", size > 0 else {
                try? FileManager.default.removeItem(at: destination)
                throw CocoaError(.fileReadCorruptFile, userInfo: [NSLocalizedDescriptionKey: "The downloaded installer is empty or invalid."])
            }
            downloadedURL = destination
        } catch {
            terminalError = error
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let result: Result<URL, Error>
        if let error = terminalError ?? error {
            result = .failure(error)
        } else if let downloadedURL {
            result = .success(downloadedURL)
        } else {
            result = .failure(URLError(.unknown))
        }
        session.finishTasksAndInvalidate()
        self.session = nil
        Task { @MainActor in
            completionHandler(result)
        }
    }
}
