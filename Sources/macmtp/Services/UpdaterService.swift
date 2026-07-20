import Foundation
import AppKit

@MainActor
public final class UpdaterService: ObservableObject, @unchecked Sendable {
    public static let shared = UpdaterService()
    
    private let repoURL = "https://api.github.com/repos/kalabhaftu/MacMTP/releases/latest"
    
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
        let alert = NSAlert()
        alert.messageText = "Downloading Update..."
        alert.informativeText = "Downloading version \(version). Please wait."
        alert.alertStyle = .informational
        
        let progress = NSProgressIndicator(frame: NSRect(x: 0, y: 0, width: 200, height: 20))
        progress.isIndeterminate = true
        progress.startAnimation(nil)
        alert.accessoryView = progress
        
        _ = alert.addButton(withTitle: "Cancel")
        
        let downloadTask = Task.detached(priority: .userInitiated) {
            do {
                var request = URLRequest(url: url)
                request.setValue("macMTP/\(AppVersion.current)", forHTTPHeaderField: "User-Agent")
                let (tempURL, response) = try await URLSession.shared.download(for: request)
                if let httpResp = response as? HTTPURLResponse, httpResp.statusCode == 200 {
                    let fileManager = FileManager.default
                    guard let downloadsDir = fileManager.urls(for: .downloadsDirectory, in: .userDomainMask).first else {
                        throw CocoaError(.fileNoSuchFile, userInfo: [NSLocalizedDescriptionKey: "The Downloads folder is unavailable."])
                    }
                    let safeVersion = version.replacingOccurrences(of: "/", with: "-")
                    let destURL = downloadsDir.appendingPathComponent("macMTP-\(safeVersion).dmg")
                    
                    if fileManager.fileExists(atPath: destURL.path) {
                        try fileManager.removeItem(at: destURL)
                    }
                    try fileManager.moveItem(at: tempURL, to: destURL)
                    
                    await MainActor.run {
                        NSApplication.shared.stopModal(withCode: .OK)
                        alert.window.close()
                        
                        let finishAlert = NSAlert()
                        finishAlert.messageText = "Download Complete"
                        finishAlert.informativeText = "The installer has been downloaded to your Downloads folder and will now open. Please drag macMTP to your Applications folder to update."
                        finishAlert.addButton(withTitle: "OK")
                        finishAlert.runModal()
                        NSWorkspace.shared.open(destURL)
                    }
                } else {
                    await MainActor.run {
                        NSApplication.shared.stopModal(withCode: .cancel)
                        alert.window.close()
                        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
                        self.showNoUpdateAlert(message: "Failed to download update. HTTP Status: \(status)")
                    }
                }
            } catch is CancellationError {
                return
            } catch {
                ErrorLogger.log(error, message: "Download update error")
                await MainActor.run {
                    NSApplication.shared.stopModal(withCode: .cancel)
                    alert.window.close()
                    self.showNoUpdateAlert(message: "Download error: \(error.localizedDescription)")
                }
            }
        }
        
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            downloadTask.cancel()
            NSApplication.shared.stopModal(withCode: .cancel)
            alert.window.close()
        }
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
